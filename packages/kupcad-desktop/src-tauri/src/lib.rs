//! The desktop app's native side: the bundled kupcad's language server, which it runs for the
//! page (server.rs); the plugins the page uses (dialogs, the files of the folder the user opens,
//! its settings file, the app's updates and its restart, the window's size and place);
//! `launch_folder`, the folder named on the command line, and `open_folder`, one opened before
//! (its recents), each let into the file system's scope for this run alone: the scope used to
//! be kept across launches, so it held every folder ever opened; `move_to_trash`, a file or
//! folder of the one opened, to the system's trash; and `export_model`, which builds a script
//! with the bundled kupcad (`kupcad build`, export.rs). The page runs the binary through these
//! alone, its arguments checked here, and reads and writes only what the user chose.

mod export;
mod server;

use std::path::{Path, PathBuf};

use tauri::{AppHandle, Manager, RunEvent, Runtime};
use tauri_plugin_fs::FsExt;

/// The bundled kupcad, as `bundle.externalBin` names it (`binaries/kupcad-<target triple>`).
pub(crate) const SIDECAR: &str = "kupcad";
/// The largest memory limit the setting may be, in GB: a petabyte (@kupcad/protocol's).
const MAX_MEMORY_LIMIT_GB: u32 = 1024 * 1024;

/// The folder the app was started with (`kupcad-desktop ~/parts`; `pnpm dev:desktop` gives it the
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
    Ok(Some(allow_folder(&app, Path::new(&arg))?))
}

/// A folder the user opened before (the page's recents), opened again: by its real path, in the
/// file system's scope with what is under it, as a folder picked in the dialog is. The scope
/// holds the folders of this run alone: it was kept across launches, with every folder ever
/// opened in it.
#[tauri::command]
fn open_folder(app: AppHandle, path: String) -> Result<String, String> {
    allow_folder(&app, Path::new(&path))
}

/// `folder` by its real path, which must be a folder, let into the file system's scope.
fn allow_folder(app: &AppHandle, folder: &Path) -> Result<String, String> {
    let path = real_folder(folder)?;
    app.fs_scope()
        .allow_directory(&path, true)
        .map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}

/// The real path of `folder`, which must be there and be a folder.
fn real_folder(folder: &Path) -> Result<PathBuf, String> {
    let path = std::fs::canonicalize(folder)
        .map_err(|e| format!("{} can't be opened: {e}", folder.display()))?;
    if !path.is_dir() {
        return Err(format!("{} is no folder", path.display()));
    }
    Ok(path)
}

/// Moves the file or folder at `path`, in the folder the user opened, to the system's trash,
/// from where they may take it back. A symlink goes itself, not where it leads.
#[tauri::command]
fn move_to_trash<R: Runtime>(app: AppHandle<R>, path: String) -> Result<(), String> {
    // The entry's own real path: its folder's, then its name
    let path = to_write(&path)?;
    if std::fs::symlink_metadata(&path).is_err() {
        return Err(format!("{} isn't there", path.display()));
    }
    allowed(&app, &path, "isn't in the folder opened")?;
    #[allow(unused_mut)]
    let mut trash = trash::TrashContext::default();
    // Not by asking the Finder, the crate's default on macOS: that asks the person to let the
    // app control it, and needs an entitlement the app has no other use for
    #[cfg(target_os = "macos")]
    {
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        trash.set_delete_method(DeleteMethod::NsFileManager);
    }
    trash
        .delete(&path)
        .map_err(|e| format!("{} wasn't moved to the trash: {e}", path.display()))
}

/// That `path` is in the file system's scope (the folder opened, a file saved), or that it
/// `isnt`.
fn allowed<R: Runtime>(app: &AppHandle<R>, path: &Path, isnt: &str) -> Result<(), String> {
    if app.fs_scope().is_allowed(path) {
        Ok(())
    } else {
        Err(format!("{} {isnt}", path.display()))
    }
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

/// `--memory-limit <n>GB` for a limit of `gigabytes`, from 1 to a petabyte, or why it isn't one:
/// kupcad holds the script to it, in place of a project's `vm_memory_limit`.
pub(crate) fn memory_limit_arg(gigabytes: u32) -> Result<[String; 2], String> {
    if !(1..=MAX_MEMORY_LIMIT_GB).contains(&gigabytes) {
        return Err(format!("{gigabytes} GB is no memory limit"));
    }
    Ok(["--memory-limit".to_string(), format!("{gigabytes}GB")])
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        // Newer versions from the releases' latest.json (tauri.conf.json), signed by the release,
        // installed in this one's place and restarted on (the process plugin's relaunch)
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(server::Server::default())
        .manage(export::Export::default())
        .invoke_handler(tauri::generate_handler![
            export::export_model,
            export::cancel_export,
            launch_folder,
            open_folder,
            move_to_trash,
            server::start_server,
            server::write_server,
            server::stop_server,
        ])
        .build(tauri::generate_context!())
        .expect("the app failed to start")
        .run(|app, event| {
            // The language server and an export go with the app
            if let RunEvent::Exit = event {
                app.state::<server::Server>().stop();
                app.state::<export::Export>().stop();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::{existing, memory_limit_arg, move_to_trash, real_folder, to_write};
    use std::path::PathBuf;
    use tauri::test::{MockRuntime, mock_builder, mock_context, noop_assets};
    use tauri_plugin_fs::FsExt;

    /// A folder of the test's own, made afresh, with `picked/sub` in it.
    pub(crate) fn folder(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("kupcad-desktop-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("picked/sub")).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    /// The app, on no window, with the plugins the commands use: its file system's scope empty.
    pub(crate) fn mock_app() -> tauri::App<MockRuntime> {
        mock_builder()
            .plugin(tauri_plugin_fs::init())
            .plugin(tauri_plugin_shell::init())
            .build(mock_context(noop_assets()))
            .unwrap()
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
    fn a_folder_opened_again_is_its_real_path_and_a_folder() {
        let dir = std::env::temp_dir().join(format!("kupcad-open-folder-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        std::fs::write(dir.join("part.kup"), "cube(1)\n").unwrap();
        let real = real_folder(&dir.join("sub").join("..")).unwrap();
        assert_eq!(real, std::fs::canonicalize(&dir).unwrap());
        assert!(
            real_folder(&dir.join("part.kup"))
                .unwrap_err()
                .ends_with("is no folder")
        );
        assert!(
            real_folder(&dir.join("gone"))
                .unwrap_err()
                .contains("can't be opened")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_memory_limit_is_a_whole_number_of_gb_from_one_to_a_petabyte() {
        assert_eq!(memory_limit_arg(1).unwrap(), ["--memory-limit", "1GB"]);
        assert_eq!(memory_limit_arg(1024 * 1024).unwrap()[1], "1048576GB");
        for gigabytes in [0, 1024 * 1024 + 1, u32::MAX] {
            assert!(memory_limit_arg(gigabytes).is_err(), "{gigabytes}");
        }
    }

    #[test]
    fn only_what_is_in_the_folder_opened_is_moved_to_the_trash() {
        let dir = folder("trash-scope");
        std::fs::write(dir.join("elsewhere.kup"), "cube(1)").unwrap();
        let app = mock_app();
        app.fs_scope()
            .allow_directory(dir.join("picked"), true)
            .unwrap();
        let trash = |path: PathBuf| {
            move_to_trash(app.handle().clone(), path.to_string_lossy().into_owned()).unwrap_err()
        };
        assert!(trash(dir.join("elsewhere.kup")).ends_with("isn't in the folder opened"));
        assert!(
            trash(dir.join("picked/sub/../../elsewhere.kup"))
                .ends_with("isn't in the folder opened")
        );
        assert!(trash(dir.join("picked/gone.kup")).ends_with("isn't there"));
        assert!(dir.join("elsewhere.kup").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
