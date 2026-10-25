# @kupcad/app

KupCAD's desktop app ([Tauri 2](https://v2.tauri.app)): a folder of scripts, the script open in
an editor with the language's every feature, and its model and parameters beside it. It runs the
`kupcad` it bundles, the same language server the VS Code extension runs (`kupcad lsp`), so the
scripts, their imports, packages and exports are the real file system's and the real CLI's.

## Running it

From the repository's root, with Rust installed (`.tool-versions`):

```sh
pnpm install
pnpm dev:app
```

It builds the core (`pnpm build:core:native`), copies `kupcad` to where the app bundles it
(`pnpm --filter @kupcad/app sidecar`: `src-tauri/binaries/kupcad-<target triple>`), and starts
the app on `examples/` (`tauri dev`, the page served by Vite as it changes, the Rust side rebuilt
when it does). A change to the core needs `pnpm dev:app` again.

`kupcad-app <folder>` opens that folder; with none, the app asks for one.

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

## How it is put together

* **The window** (`src/App.svelte`): the folder's tree (`FileTree.svelte`, `folder.js`: its
  scripts and the files they read, hidden folders such as `.git` and `.kupcad` left out), the
  script open in `@kupcad/editor` with the language server's features, and `@kupcad/ui`'s
  `PreviewPanel` (the model, the run's problems, the parameters). A script's edits are kept until
  it is saved (⌘S, Ctrl+S), marked in the tree and the bar until then; the window asks before it
  closes, or opens another folder, on unsaved changes. It takes its services as a prop
  (`platform.js`, Tauri's), so its tests give it stand-ins.
* **The language server** (`src/server.js`, `src-tauri/src/server.rs`): the native side starts
  `kupcad lsp --stdio --viewport-origin <the page's origin>` for the page and holds it, at most
  one: a page that loads again replaces the one it left, and the app stops it when it exits. Its
  stdio comes to the page over a Tauri channel and is framed for the editor's client
  (`@kupcad/editor`'s `streamTransport`); a server that ends is started again, a little later
  each time, the editors' scripts opened on it again. Its viewport socket admits the page by its
  origin, `tauri://localhost` (`http://tauri.localhost` on Windows, Vite's under `tauri dev`),
  and no other page.
* **The preview's host** (`src/host.js`): what the panel asks, done in the page. The panel's
  values go to the server (`kupcad.setParams`) and are kept for the script; an export asks where
  to save (the format is the file's extension) and runs `kupcad build` with them; a screenshot
  is saved where the person says; a problem's place is shown in the editor. Presets aren't
  offered yet.
* **The native side** (`src-tauri/src/lib.rs`): the plugins (dialogs, the file system) and the
  app's commands: `start_server`, `write_server`, `stop_server`, `launch_folder` (the folder
  named on the command line, put in the file system's scope as a picked one is) and
  `export_model`, which builds with the bundled `kupcad` only a script in the folder opened into
  a file the person saved, in a format `kupcad` writes, its parameters' names checked.

## What the page may do

The page runs no program itself: it has no shell permission, and the bundled `kupcad` runs
through the app's commands above, with the arguments they make. It reads and writes only what
the person chose (`capabilities/default.json`: the dialogs, and the file system within the
folder opened and the files saved), and its Content Security Policy (`tauri.conf.json`) lets it
connect to the app's IPC and the server's viewport socket on 127.0.0.1 alone.

## Tests

The folder's tree and its files' URIs, the preview's host (what the panel is told, an export
with its values and its formats, a screenshot, a refused message), the language server's
lifecycle on a stand-in server (its handshake through the framing, the viewport's URL, the
commands, restarts, a server that ends before it is up), and the window on stand-ins (a folder
opened, a script opened, an edit saved with ⌘S, the question on closing). `test:integration`
runs the page's server on the real `kupcad lsp`: the handshake, a script's diagnostics, and its
model from the viewport socket. The Rust side tests its commands' arguments.
