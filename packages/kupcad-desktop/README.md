# @kupcad/desktop

KupCAD's desktop app ([Tauri 2](https://v2.tauri.app)): a folder of scripts, the script open in
an editor with the language's every feature, and its model and parameters beside it. It runs the
`kupcad` it bundles, the same language server the VS Code extension runs (`kupcad lsp`), so the
scripts, their imports, packages and exports are the real file system's and the real CLI's.

## Running it

From the repository's root, with Rust installed (`.tool-versions`):

```sh
pnpm install
pnpm dev:desktop
```

It builds the core (`pnpm build:core:native`), copies `kupcad` to where the app bundles it
(`pnpm --filter @kupcad/desktop sidecar`: `src-tauri/binaries/kupcad-<target triple>`), and starts
the app on `examples/` (`tauri dev`, the page served by Vite as it changes, the Rust side rebuilt
when it does). A change to the core needs `pnpm dev:desktop` again.

`kupcad-desktop <folder>` opens that folder; with none, the app asks for one.

In this package:

```sh
pnpm dev                 # the page alone, under Vite (tauri dev runs it)
pnpm tauri dev           # the app (after `pnpm sidecar`)
pnpm tauri build         # the app bundled for this system, in src-tauri/target/release/bundle/
pnpm check               # svelte-check: the page's and the tests' types
pnpm test                # Vitest under jsdom
pnpm test:integration    # the page's server on the real kupcad (core/zig-out/bin/kupcad)
cd src-tauri && cargo test && cargo clippy --all-targets -- -D warnings
```

## Releases

A version tag builds the app on each system and architecture the CLI ships for, around that
platform's release `kupcad` (`.github/workflows/release.yml`, the `desktop` job), and the
release carries the installers beside the CLI's archives, in its `checksums.txt` too:
`kupcad-desktop_<version>_<os>_<arch>` as a `.dmg` (macOS), a `.deb` and an `.rpm` (Linux, and
an `.AppImage` for x86_64) or a `_setup.exe` (Windows). They aren't signed yet, so macOS and
Windows warn before they open one; signing needs the certificates as the repository's secrets.

## How it is put together

* **The window** (`src/App.svelte`): the folder's tree (`FileTree.svelte`, `folder.js`: its
  scripts and the files they read, in its folders however deep, hidden folders such as `.git`
  and `.kupcad` left out), the script open in `@kupcad/editor` with the language server's
  features, and `@kupcad/panels`'s
  `PreviewPanel` (the model, the run's problems, the parameters). A script's edits are kept until
  it is saved (⌘S, Ctrl+S), marked in the tree and the bar until then; the window asks before it
  closes, or opens another folder, on unsaved changes. A folder in the tree opens and closes
  when clicked, or with the arrow keys (up and down, right into a folder, left out of it), and a
  script opened opens the folders it is in; which are closed isn't kept, so a folder opens with
  all of them open. The tree follows the folder: watched (the file
  system plugin's `watch`, its changes gathered for 300 ms), it is listed again when something
  in it is made, removed or renamed; a file only read or saved in place, or anything in a folder
  the tree leaves out, doesn't list it again. The bars between the tree, the editor,
  the model, the parameters and the console resize them, and the Parameters button hides the
  parameters; the sizes, and which panes are hidden, are kept in the app's settings
  file (`settings.json` in its config folder, macOS's `~/Library/Application Support/
  dev.kupcad.desktop/`, through Tauri's store plugin), read before the window is laid out. It
  takes its services as a prop
  (`platform.js`, Tauri's), so its tests give it stand-ins.
* **The language server** (`src/server.js`, `src-tauri/src/server.rs`): the native side starts
  `kupcad lsp --stdio --viewport-origin <the page's origin>` for the page and holds it, at most
  one: a page that loads again replaces the one it left, and the app stops it when it exits. Its
  stdio comes to the page over a Tauri channel and is framed for the editor's client
  (`@kupcad/editor`'s `streamTransport`); a server that ends, or doesn't start again, is started
  again a little later each time, the editors' scripts opened on it again. Its viewport socket
  admits the page by its origin, `tauri://localhost` (`http://tauri.localhost` on Windows), and
  no other page; Vite's (under `tauri dev`) in a debug build alone, as a released app would
  admit any other project's dev server on that port.
* **The preview's host** (`src/host.js`): what the panel asks, done in the page. The panel's
  values go to the server (`kupcad.setParams`) and are kept for the script; an export, in the format
  the panel's menu chose, asks where to save it (a dialog of that format alone: macOS's save
  panel offers no choice among file types, so one of them all named the file `.stl` whatever
  the model) and runs `kupcad build` with them; a screenshot
  is saved where the person says; a problem's place is shown in the editor. The server's log
  goes to the panel's console, under the model, with each run (what it printed, its warnings
  and its error). Presets aren't offered yet.
* **The native side** (`src-tauri/src/lib.rs`): the plugins (dialogs, the file system) and the
  app's commands: `start_server`, `write_server`, `stop_server`, `launch_folder` (the folder
  named on the command line, put in the file system's scope as a picked one is) and
  `export_model`, which builds with the bundled `kupcad` only a script in the folder opened into
  a file the person saved, in a format `kupcad` writes, its parameters' names checked.

## What the page may do

The page runs no program itself: it has no shell permission, and the bundled `kupcad` runs
through the app's commands above, with the arguments they make. It reads and writes only what
the person chose (`capabilities/default.json`: the dialogs, and the file system within the
folder opened, which it watches too, and the files saved), and its Content Security Policy (`tauri.conf.json`) lets it
connect to the app's IPC and the server's viewport socket on 127.0.0.1 alone.

## Tests

The folder's tree (folders in folders, what a closed folder hides, the folders a script is in,
which of the watcher's changes list it again) and its files' URIs, the tree's rows (a folder
opened and closed by a click or the arrow keys), the preview's host (what the panel is told, an export
with its values and its formats, a screenshot, a refused message), the language server's
lifecycle on a stand-in server (its handshake through the framing, the viewport's URL, the
commands, restarts, a server that ends before it is up or doesn't start again), and the window on stand-ins (a folder
opened, a script opened, an edit saved with ⌘S, the question on closing, the tree's folders
closed and opened, none of it kept, the folder listed again as it changes and no longer once
another is opened). `test:integration`
runs the page's server on the real `kupcad lsp`: the handshake, a script's diagnostics, and its
model from the viewport socket. The Rust side tests its commands' arguments, that an export's paths are checked and passed by
their real paths (no `..`, no symlink, which the file system's scope matched as written), and
that a release build doesn't admit Vite's origin.
