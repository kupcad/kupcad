//! The bundled kupcad's language server (`kupcad lsp`), which the page talks to over its stdio.
//! At most one runs, held here: a page that starts one (again after a reload, which leaves no
//! JavaScript to stop the last) replaces the one before it, and the app stops the last when it
//! exits. The page names its origin, which the server's viewport socket then admits; it must
//! be one of the page's own.

use std::sync::{Mutex, MutexGuard};

use serde::Serialize;
use tauri::{AppHandle, State, ipc::Channel};
use tauri_plugin_shell::ShellExt;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};

use crate::SIDECAR;

/// The page's origins: its own in a build (macOS and Linux; Windows), and Vite's under
/// `tauri dev` (tauri.conf.json's devUrl).
const PAGE_ORIGINS: [&str; 3] = [
    "tauri://localhost",
    "http://tauri.localhost",
    "http://127.0.0.1:1420",
];

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

/// `kupcad lsp`'s arguments for the page at `origin`, or why there are none: an origin that
/// isn't the page's.
fn server_args(origin: &str) -> Result<[&str; 4], String> {
    if !PAGE_ORIGINS.contains(&origin) {
        return Err(format!("{origin} is no origin of the app's page"));
    }
    Ok(["lsp", "--stdio", "--viewport-origin", origin])
}

/// Starts the server for the page at `origin`, stopping the one before; what it says goes to
/// `on_event`.
#[tauri::command]
pub fn start_server(
    app: AppHandle,
    server: State<'_, Server>,
    origin: String,
    on_event: Channel<ServerEvent>,
) -> Result<(), String> {
    let args = server_args(&origin)?;
    let (mut events, child) = app
        .shell()
        .sidecar(SIDECAR)
        .map_err(|e| format!("the bundled kupcad wasn't found: {e}"))?
        .args(args)
        .set_raw_out(true)
        .spawn()
        .map_err(|e| format!("kupcad lsp didn't start: {e}"))?;
    let before = server.held().replace(child);
    if let Some(before) = before {
        let _ = before.kill();
    }
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
    use super::server_args;

    #[test]
    fn the_server_admits_the_pages_own_origin_and_no_other() {
        for origin in [
            "tauri://localhost",
            "http://tauri.localhost",
            "http://127.0.0.1:1420",
        ] {
            assert_eq!(
                server_args(origin).unwrap(),
                ["lsp", "--stdio", "--viewport-origin", origin]
            );
        }
        for origin in ["null", "http://localhost:1420", "https://evil.example", ""] {
            assert!(server_args(origin).is_err(), "{origin}");
        }
    }
}
