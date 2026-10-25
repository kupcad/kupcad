//! The desktop app's native side: the bundled kupcad's language server, which it runs for the
//! page (server.rs); the plugins the page uses (dialogs, the files of the folder the user opens,
//! its settings file);
//! `launch_folder`, the folder named on the command line; and `export_model`, which builds a
//! script with the bundled kupcad (`kupcad build`). The page runs the binary through these
//! alone, its arguments checked here, and reads and writes only what the user chose.

mod server;

use std::path::{Path, PathBuf};

use tauri::{AppHandle, Manager, RunEvent};
use tauri_plugin_fs::FsExt;
use tauri_plugin_shell::ShellExt;

/// The bundled kupcad, as `bundle.externalBin` names it (`binaries/kupcad-<target triple>`).
pub(crate) const SIDECAR: &str = "kupcad";
/// The formats `kupcad build -f` writes (core/src/exporters/format.zig).
const FORMATS: [&str; 8] = ["stl", "3mf", "step", "glb", "gltf", "obj", "svg", "dxf"];

/// Builds the script at `script` into `output`, in `format`, each parameter given its value
/// (`-p name=value`), in the script's folder, where its imports are. Both paths must be ones
/// the user chose: the script in the folder they opened, the output where they saved it. A
/// failed build's error is what kupcad said.
#[tauri::command]
async fn export_model(
    app: AppHandle,
    script: String,
    output: String,
    format: String,
    params: Vec<(String, String)>,
) -> Result<(), String> {
    // By their real paths: the scope matches a path as written, and `picked/../elsewhere`
    // matched the folder picked
    let script = existing(&script)?;
    let output = to_write(&output)?;
    let scope = app.fs_scope();
    for path in [&script, &output] {
        if !scope.is_allowed(path) {
            return Err(format!(
                "{} isn't in the folder opened, nor where a model was saved",
                path.display()
            ));
        }
    }
    let (script, output) = (script.to_string_lossy(), output.to_string_lossy());
    let args = build_args(&script, &output, &format, &params)?;
    let folder = Path::new(script.as_ref())
        .parent()
        .ok_or("the script has no folder")?;
    let built = app
        .shell()
        .sidecar(SIDECAR)
        .map_err(|e| format!("the bundled kupcad wasn't found: {e}"))?
        .args(args)
        .current_dir(folder)
        .output()
        .await
        .map_err(|e| format!("kupcad didn't start: {e}"))?;
    if built.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&built.stderr).into_owned())
    }
}

/// The folder the app was started with (`kupcad-app ~/parts`; `pnpm dev:app` gives it the
/// examples), by its real path, in the file system's scope with what is under it, as a folder
/// picked in the dialog is; none without one. Options (`-…`) aren't folders.
#[tauri::command]
fn launch_folder(app: AppHandle) -> Result<Option<String>, String> {
    let Some(arg) = std::env::args_os()
        .skip(1)
        .find(|arg| !arg.to_string_lossy().starts_with('-'))
    else {
        return Ok(None);
    };
    let path = std::fs::canonicalize(&arg)
        .map_err(|e| format!("{} can't be opened: {e}", arg.to_string_lossy()))?;
    if !path.is_dir() {
        return Err(format!("{} is no folder", path.display()));
    }
    app.fs_scope()
        .allow_directory(&path, true)
        .map_err(|e| e.to_string())?;
    Ok(Some(path.to_string_lossy().into_owned()))
}

/// The real path of the file at `path`, which is there: no `..`, no symlink.
fn existing(path: &str) -> Result<PathBuf, String> {
    std::fs::canonicalize(path).map_err(|e| format!("{path} can't be read: {e}"))
}

/// The real path a file written at `path` gets: its folder's (which is there), then its name.
fn to_write(path: &str) -> Result<PathBuf, String> {
    let given = Path::new(path);
    let name = given
        .file_name()
        .ok_or_else(|| format!("{path} names no file"))?;
    let folder = given
        .parent()
        .filter(|folder| !folder.as_os_str().is_empty())
        .ok_or_else(|| format!("{path} has no folder"))?;
    Ok(existing(&folder.to_string_lossy())?.join(name))
}

/// `kupcad build`'s arguments for an export, or why they can't be: a format it doesn't write,
/// or a parameter whose name would be read as something else.
fn build_args(
    script: &str,
    output: &str,
    format: &str,
    params: &[(String, String)],
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
    Ok(args)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .manage(server::Server::default())
        .invoke_handler(tauri::generate_handler![
            export_model,
            launch_folder,
            server::start_server,
            server::write_server,
            server::stop_server,
        ])
        .build(tauri::generate_context!())
        .expect("the app failed to start")
        .run(|app, event| {
            // The language server goes with the app
            if let RunEvent::Exit = event {
                app.state::<server::Server>().stop();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::{build_args, existing, to_write};
    use std::path::PathBuf;

    /// A folder of the test's own, made afresh.
    fn folder(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kupcad-app-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("picked/sub")).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    #[test]
    fn an_exports_paths_are_real_ones_no_dot_dot_left_to_match_a_folder() {
        let dir = folder("paths");
        std::fs::write(dir.join("picked/part.kup"), "cube(1)").unwrap();
        // Written as the page might: through `..`, out of the folder picked
        let dotted = dir.join("picked/sub/../../part.stl");
        assert_eq!(
            to_write(&dotted.to_string_lossy()).unwrap(),
            dir.join("part.stl")
        );
        let script = dir.join("picked/sub/../part.kup");
        assert_eq!(
            existing(&script.to_string_lossy()).unwrap(),
            dir.join("picked/part.kup")
        );
        // A file that isn't there yet is fine, a folder that isn't there isn't
        assert!(to_write(&dir.join("gone/part.stl").to_string_lossy()).is_err());
        assert!(existing(&dir.join("picked/gone.kup").to_string_lossy()).is_err());
        assert!(to_write("part.stl").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn an_exports_folder_reached_by_a_symlink_is_where_the_symlink_leads() {
        let dir = folder("symlink");
        std::os::unix::fs::symlink(&dir, dir.join("picked/out")).unwrap();
        let through = dir.join("picked/out/part.stl");
        assert_eq!(
            to_write(&through.to_string_lossy()).unwrap(),
            dir.join("part.stl")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_export_is_kupcad_build_with_its_format_and_values() {
        let params = vec![("width".to_string(), "40".to_string())];
        let args = build_args("/w/part.kup", "/out/part.3mf", "3mf", &params).unwrap();
        assert_eq!(
            args,
            [
                "build",
                "/w/part.kup",
                "-o",
                "/out/part.3mf",
                "-f",
                "3mf",
                "-p",
                "width=40"
            ]
        );
    }

    #[test]
    fn a_format_kupcad_doesnt_write_or_a_name_read_as_an_option_is_refused() {
        assert!(build_args("/w/a.kup", "/o/a.exe", "exe", &[]).is_err());
        for name in ["", "-o", "a=b"] {
            let params = vec![(name.to_string(), "1".to_string())];
            assert!(
                build_args("/w/a.kup", "/o/a.stl", "stl", &params).is_err(),
                "{name}"
            );
        }
    }
}
