//! The bundled kupcad's language server (`kupcad lsp`), which the page talks to over its stdio.
//! At most one runs, held here: a page that starts one (again after a reload, which leaves no
//! JavaScript to stop the last) replaces the one before it, and the app stops the last when it
//! exits. The page names its origin, which the server's viewport socket then admits; it must
//! be one of the page's own.

use std::sync::{Mutex, MutexGuard};

use serde::Serialize;
use tauri::{AppHandle, Runtime, State, ipc::Channel};
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};

use crate::{SIDECAR, memory_limit_arg};

/// The page's origins in a build: macOS and Linux's, Windows'.
const PAGE_ORIGINS: [&str; 2] = ["tauri://localhost", "http://tauri.localhost"];
/// Vite's, where the page is under `tauri dev` (tauri.conf.json's devUrl): a debug build's
/// alone, as a released app's socket would admit any other project's dev server on that port.
const DEV_ORIGIN: &str = "http://127.0.0.1:1420";

/// The server running, if one is.
#[derive(Default)]
pub struct Server(Mutex<Option<CommandChild>>);

impl Server {
    /// The server, held while it is used; a page that panicked holding it leaves it usable.
    fn held(&self) -> MutexGuard<'_, Option<CommandChild>> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Holds `child` as the server, the one before it, if one runs, stopped.
    fn hold(&self, child: CommandChild) {
        let before = self.held().replace(child);
        if let Some(before) = before {
            let _ = before.kill();
        }
    }

    /// Stops the server, if one runs.
    pub fn stop(&self) {
        if let Some(child) = self.held().take() {
            // One that has ended already has nothing left to stop
            let _ = child.kill();
        }
    }
}

/// What the server tells the page, as it runs.
#[derive(Clone, Serialize)]
#[serde(tag = "event", content = "data", rename_all = "camelCase")]
pub enum ServerEvent {
    /// Bytes of its stdout, as they come.
    Stdout(Vec<u8>),
    /// Its log.
    Stderr(String),
    /// It ended, with its exit code (none when a signal ended it).
    Exit(Option<i32>),
}

/// `kupcad lsp`'s arguments for the page at `origin`, its previews holding up to
/// `memory_limit` GB, or why there are none: an origin that isn't the page's, a limit out of
/// range.
fn server_args(origin: &str, memory_limit: u32) -> Result<Vec<String>, String> {
    let dev = cfg!(debug_assertions) && origin == DEV_ORIGIN;
    if !(PAGE_ORIGINS.contains(&origin) || dev) {
        return Err(format!("{origin} is no origin of the app's page"));
    }
    let mut args: Vec<String> = ["lsp", "--stdio", "--viewport-origin", origin]
        .iter()
        .map(|arg| arg.to_string())
        .collect();
    args.extend(memory_limit_arg(memory_limit)?);
    Ok(args)
}

/// Starts the server for the page at `origin`, its previews holding up to `memory_limit` GB (the
/// app's setting), stopping the one before; what it says goes to `on_event`.
#[tauri::command]
pub fn start_server<R: Runtime>(
    app: AppHandle<R>,
    server: State<'_, Server>,
    origin: String,
    memory_limit: u32,
    on_event: Channel<ServerEvent>,
) -> Result<(), String> {
    let args = server_args(&origin, memory_limit)?;
    let (mut events, child) = app
        .shell()
        .sidecar(SIDECAR)
        .map_err(|e| format!("the bundled kupcad wasn't found: {e}"))?
        .args(args)
        .set_raw_out(true)
        .spawn()
        .map_err(|e| format!("kupcad lsp didn't start: {e}"))?;
    server.hold(child);
    tauri::async_runtime::spawn(async move {
        while let Some(event) = events.recv().await {
            let told = match event {
                CommandEvent::Stdout(bytes) => on_event.send(ServerEvent::Stdout(bytes)),
                CommandEvent::Stderr(bytes) => on_event.send(ServerEvent::Stderr(
                    String::from_utf8_lossy(&bytes).into_owned(),
                )),
                CommandEvent::Terminated(ended) => on_event.send(ServerEvent::Exit(ended.code)),
                _ => Ok(()),
            };
            // The page that started it can't be told any more
            if told.is_err() {
                break;
            }
        }
    });
    Ok(())
}

/// Writes `text` (LSP frames: their headers and JSON, UTF-8) to the server's stdin.
#[tauri::command]
pub fn write_server(server: State<'_, Server>, text: String) -> Result<(), String> {
    let mut held = server.held();
    let child = held.as_mut().ok_or("kupcad lsp isn't running")?;
    child
        .write(text.as_bytes())
        .map_err(|e| format!("kupcad lsp can't be written to: {e}"))
}

/// Stops the server, if one runs.
#[tauri::command]
pub fn stop_server(server: State<'_, Server>) {
    server.stop();
}

#[cfg(test)]
mod tests {
    use super::{DEV_ORIGIN, Server, server_args};

    #[test]
    fn the_server_admits_the_pages_own_origin_and_no_other() {
        for origin in ["tauri://localhost", "http://tauri.localhost"] {
            assert_eq!(
                server_args(origin, 8).unwrap(),
                [
                    "lsp",
                    "--stdio",
                    "--viewport-origin",
                    origin,
                    "--memory-limit",
                    "8GB"
                ]
            );
        }
        for origin in ["null", "http://localhost:1420", "https://evil.example", ""] {
            assert!(server_args(origin, 8).is_err(), "{origin}");
        }
        // Nor a memory limit kupcad would refuse
        assert!(server_args("tauri://localhost", 0).is_err());
    }

    #[test]
    fn vites_origin_is_a_debug_builds_alone() {
        assert_eq!(server_args(DEV_ORIGIN, 8).is_ok(), cfg!(debug_assertions));
    }

    #[cfg(unix)]
    #[test]
    fn a_server_started_replaces_the_one_before_which_is_stopped() {
        use crate::tests::mock_app;
        use tauri::async_runtime::block_on;
        use tauri_plugin_shell::ShellExt;
        use tauri_plugin_shell::process::CommandEvent;

        let app = mock_app();
        let sleeping = || app.shell().command("sleep").args(["30"]).spawn().unwrap();
        let server = Server::default();
        let (mut first_events, first) = sleeping();
        let (mut second_events, second) = sleeping();
        server.hold(first);
        server.hold(second);
        assert!(matches!(
            block_on(first_events.recv()),
            Some(CommandEvent::Terminated(_))
        ));
        assert!(second_events.try_recv().is_err());
        server.stop();
        assert!(matches!(
            block_on(second_events.recv()),
            Some(CommandEvent::Terminated(_))
        ));
    }
}
