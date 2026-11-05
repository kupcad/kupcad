//! The export: `kupcad build` run for the page with the bundled kupcad, a script in the folder
//! the user opened built into a file they saved. It is held while it runs, one at a time: the
//! page cancels it (`cancel_export`), and the app stops it as it exits. Its log is kept up to
//! MAX_LOG_BYTES, the end of it, where a failure's JSON line is: all of it went to the page,
//! however much a script printed.

use std::collections::VecDeque;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};

use tauri::async_runtime::Receiver;
use tauri::{AppHandle, Runtime, State};
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::{Command, CommandChild, CommandEvent};

use crate::{SIDECAR, allowed, existing, memory_limit_arg, to_write};

/// The formats `kupcad build -f` writes (core/src/exporters/format.zig): @kupcad/protocol's
/// EXPORT_FORMATS, which src/native.test.js holds it to.
const FORMATS: [&str; 8] = ["stl", "3mf", "step", "glb", "gltf", "obj", "svg", "dxf"];
/// The most of a build's log kept, in bytes: as much as the VS Code extension's export reads.
const MAX_LOG_BYTES: usize = 16 * 1024 * 1024;

/// The export running, if one is, by its number.
#[derive(Default)]
pub struct Export {
    running: Mutex<Option<(u64, CommandChild)>>,
    started: AtomicU64,
}

impl Export {
    /// The export, held while it is used; a page that panicked holding it leaves it usable.
    fn held(&self) -> MutexGuard<'_, Option<(u64, CommandChild)>> {
        self.running
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Starts `command` as the export, unless one runs: what it says, and its number.
    fn start(&self, command: Command) -> Result<(Receiver<CommandEvent>, u64), String> {
        let mut held = self.held();
        if held.is_some() {
            return Err("another export is under way".to_string());
        }
        let (events, child) = command
            .spawn()
            .map_err(|e| format!("kupcad didn't start: {e}"))?;
        let number = self.started.fetch_add(1, Ordering::Relaxed);
        *held = Some((number, child));
        Ok((events, number))
    }

    /// Lets export `number` go, once it ended: one stopped is gone already, and another may run
    /// since.
    fn release(&self, number: u64) {
        let mut held = self.held();
        if held.as_ref().is_some_and(|(running, _)| *running == number) {
            held.take();
        }
    }

    /// Stops the export, if one runs.
    pub fn stop(&self) {
        if let Some((_, child)) = self.held().take() {
            // One that has ended already has nothing left to stop
            let _ = child.kill();
        }
    }
}

/// The end of what a process says, `limit` bytes of it at most.
struct Tail {
    bytes: VecDeque<u8>,
    limit: usize,
}

impl Tail {
    fn new(limit: usize) -> Self {
        Tail {
            bytes: VecDeque::new(),
            limit,
        }
    }

    fn push(&mut self, chunk: &[u8]) {
        self.bytes.extend(chunk);
        let over = self.bytes.len().saturating_sub(self.limit);
        self.bytes.drain(..over);
    }

    /// What it kept, as text: a character cut at its start is replaced.
    fn text(mut self) -> String {
        String::from_utf8_lossy(self.bytes.make_contiguous()).into_owned()
    }
}

/// Builds the script at `script` into `output`, in `format`, each parameter given its value
/// (`-p name=value`), the script holding no more than `memory_limit` GB (the app's setting), in
/// the script's folder, where its imports are. Both paths must be ones the user chose: the
/// script in the folder they opened, the output where they saved it. A failed build's error is
/// what kupcad said; one stopped (`cancel_export`) fails too.
#[tauri::command]
pub async fn export_model<R: Runtime>(
    app: AppHandle<R>,
    export: State<'_, Export>,
    script: String,
    output: String,
    format: String,
    params: Vec<(String, String)>,
    memory_limit: u32,
) -> Result<(), String> {
    // By their real paths: the scope matches a path as written, and `picked/../elsewhere`
    // matched the folder picked
    let script = existing(&script)?;
    let output = to_write(&output)?;
    for path in [&script, &output] {
        allowed(
            &app,
            path,
            "isn't in the folder opened, nor where a model was saved",
        )?;
    }
    let (script, output) = (script.to_string_lossy(), output.to_string_lossy());
    let args = build_args(&script, &output, &format, &params, memory_limit)?;
    let folder = Path::new(script.as_ref())
        .parent()
        .ok_or("the script has no folder")?;
    let command = app
        .shell()
        .sidecar(SIDECAR)
        .map_err(|e| format!("the bundled kupcad wasn't found: {e}"))?
        .args(args)
        .current_dir(folder)
        // As it comes: a line is read whole, however long a script made it
        .set_raw_out(true);
    let (mut events, number) = export.start(command)?;
    let mut said = Tail::new(MAX_LOG_BYTES);
    let mut code = None;
    while let Some(event) = events.recv().await {
        match event {
            CommandEvent::Stderr(bytes) => said.push(&bytes),
            CommandEvent::Error(error) => said.push(error.as_bytes()),
            CommandEvent::Terminated(ended) => code = ended.code,
            // Its stdout, read so it never waits on it: the model goes to the file
            _ => {}
        }
    }
    export.release(number);
    let said = said.text();
    match code {
        Some(0) => Ok(()),
        _ if !said.trim().is_empty() => Err(said),
        Some(code) => Err(format!("kupcad ended (code {code}) and said nothing")),
        None => Err("kupcad was stopped".to_string()),
    }
}

/// Stops the export running, if one is: the page's Cancel.
#[tauri::command]
pub fn cancel_export(export: State<'_, Export>) {
    export.stop();
}

/// `kupcad build`'s arguments for an export, or why they can't be: a format it doesn't write,
/// a parameter whose name would be read as something else, or a memory limit out of range.
fn build_args(
    script: &str,
    output: &str,
    format: &str,
    params: &[(String, String)],
    memory_limit: u32,
) -> Result<Vec<String>, String> {
    if !FORMATS.contains(&format) {
        return Err(format!("kupcad writes no format '{format}'"));
    }
    let mut args: Vec<String> = ["build", script, "-o", output, "-f", format]
        .iter()
        .map(|arg| arg.to_string())
        .collect();
    for (name, value) in params {
        if name.is_empty() || name.starts_with('-') || name.contains('=') {
            return Err(format!("'{name}' is no parameter's name"));
        }
        args.push("-p".to_string());
        args.push(format!("{name}={value}"));
    }
    args.extend(memory_limit_arg(memory_limit)?);
    // A failure told as one JSON line last (the page reads it: @kupcad/protocol's buildFailure)
    args.extend(["--errors".to_string(), "json".to_string()]);
    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::{Export, Tail, build_args, export_model};
    use crate::tests::{folder, mock_app};
    use tauri::Manager;
    use tauri::async_runtime::block_on;
    use tauri_plugin_fs::FsExt;

    /// An export's arguments, as @kupcad/protocol keeps them for the hosts: the VS Code
    /// extension's tests hold them too.
    const BUILD: &str = include_str!("../../../kupcad-protocol/src/fixtures/build-arguments.json");

    #[test]
    fn an_export_is_kupcad_build_as_the_vs_code_extensions_is() {
        let build: serde_json::Value = serde_json::from_str(BUILD).unwrap();
        let text = |key: &str| build[key].as_str().unwrap();
        let params: Vec<(String, String)> =
            serde_json::from_value(build["params"].clone()).unwrap();
        let argv: Vec<String> = serde_json::from_value(build["argv"].clone()).unwrap();
        let limit = u32::try_from(build["memoryLimit"].as_u64().unwrap()).unwrap();
        let args = build_args(
            text("script"),
            text("output"),
            text("format"),
            &params,
            limit,
        );
        assert_eq!(args.unwrap(), argv);
        // A name read as something else, as the extension refuses it
        for name in build["refusedNames"].as_array().unwrap() {
            let params = vec![(name.as_str().unwrap().to_string(), "1".to_string())];
            let args = build_args(
                text("script"),
                text("output"),
                text("format"),
                &params,
                limit,
            );
            assert!(args.is_err(), "{name}");
        }
    }

    #[test]
    fn a_format_kupcad_doesnt_write_or_a_memory_limit_out_of_range_is_refused() {
        assert!(build_args("/w/a.kup", "/o/a.exe", "exe", &[], 8).is_err());
        for gigabytes in [0, 1024 * 1024 + 1] {
            assert!(build_args("/w/a.kup", "/o/a.stl", "stl", &[], gigabytes).is_err());
        }
    }

    #[test]
    fn a_builds_log_is_kept_to_its_end() {
        let mut said = Tail::new(8);
        said.push(b"info: a long log\n");
        said.push(b"{\"e\"}\n");
        assert_eq!(said.text(), "g\n{\"e\"}\n");
        let mut short = Tail::new(8);
        short.push(b"why");
        assert_eq!(short.text(), "why");
    }

    #[test]
    fn an_export_builds_only_a_script_in_the_folder_opened_into_a_file_saved() {
        let dir = folder("export-scope");
        std::fs::create_dir_all(dir.join("out")).unwrap();
        std::fs::write(dir.join("picked/part.kup"), "cube(1)\n").unwrap();
        std::fs::write(dir.join("picked/thin.kup"), "raise \"too thin\"\n").unwrap();
        std::fs::write(dir.join("elsewhere.kup"), "cube(1)\n").unwrap();
        let app = mock_app();
        app.manage(Export::default());
        app.fs_scope()
            .allow_directory(dir.join("picked"), true)
            .unwrap();
        let export = |script: &str, output: &str| {
            block_on(export_model(
                app.handle().clone(),
                app.state::<Export>(),
                dir.join(script).to_string_lossy().into_owned(),
                dir.join(output).to_string_lossy().into_owned(),
                "stl".to_string(),
                vec![],
                8,
            ))
        };
        let refused = |script: &str, output: &str| {
            export(script, output)
                .unwrap_err()
                .ends_with("isn't in the folder opened, nor where a model was saved")
        };
        // Out of the folder opened, through `..` too, and into a file not saved
        assert!(refused("elsewhere.kup", "picked/part.stl"));
        assert!(refused("picked/sub/../../elsewhere.kup", "picked/part.stl"));
        assert!(refused("picked/part.kup", "out/part.stl"));
        // A file saved is let in by the dialog: the bundled kupcad (tauri-build's copy beside the
        // tests) builds into it, or says why it didn't, its failure's JSON line last
        app.fs_scope().allow_file(dir.join("out/part.stl")).unwrap();
        export("picked/part.kup", "out/part.stl").unwrap();
        assert!(dir.join("out/part.stl").metadata().unwrap().len() > 0);
        let failed = export("picked/thin.kup", "out/part.stl").unwrap_err();
        let last = failed.trim_end().lines().last().unwrap_or_default();
        assert!(
            last.starts_with("{\"error\"") && last.contains("too thin"),
            "{failed}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn one_export_runs_at_a_time_stopped_when_asked() {
        use tauri_plugin_shell::ShellExt;
        use tauri_plugin_shell::process::CommandEvent;

        let app = mock_app();
        let sleeping = || app.shell().command("sleep").args(["30"]);
        let export = Export::default();
        let (mut events, first) = export.start(sleeping()).unwrap();
        assert!(export.start(sleeping()).is_err());
        export.stop();
        assert!(matches!(
            block_on(events.recv()),
            Some(CommandEvent::Terminated(_))
        ));
        // The first's end, told once another started, leaves the other held
        let (mut next_events, _) = export.start(sleeping()).unwrap();
        export.release(first);
        assert!(export.start(sleeping()).is_err());
        export.stop();
        assert!(matches!(
            block_on(next_events.recv()),
            Some(CommandEvent::Terminated(_))
        ));
    }
}
