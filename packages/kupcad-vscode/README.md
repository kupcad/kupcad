# KupCAD for VS Code

Language support for [KupCAD](https://github.com/kupcad/kupcad) (`.kup`) files, backed by the
`kupcad lsp` language server, and a viewer of the model a script builds.

## Features

* Syntax highlighting and language configuration for `.kup`.
* Diagnostics as you type (the lint findings, and what a run warned of, on the line of its call),
  hovers, go to definition, inlay hints, symbols, formatting and quick fixes, from the language
  server.
* **The viewer** (`KupCAD: Open Viewer`, or the button in a `.kup` editor's title bar): the model
  of the script the editor shows, beside it, following the editor from script to script. It
  comes straight from the language server's local socket, a new one each time the script, or a
  module it imports, changes. Solid, x-ray and wireframe, the standard views, a section through
  the model, the parts with their colours and copies (a click selects a part), and a screenshot.
  The script's parameters are a panel beside it: a value set there runs the script again with it,
  checked against the parameter's range first; one the run refuses is marked. Why a run failed,
  and what it warned of with no line to show it on, are shown over the model.
* **Presets:** named sets of a script's values, kept beside it in `<name>.presets.json`
  (`bracket.kup`'s in `bracket.presets.json`, `{ "presets": { "Small": { "width": 20 } } }`, to
  read, edit and commit with the script). The viewer lists them above the parameters: one chosen
  runs the script with its values; `Save as preset…` keeps the values set in the panel under a
  name (asking before replacing one). An edit of the file shows at once, wherever the script is.
* **Export** (`KupCAD: Export…`, a `.kup` editor's title bar, or the viewer's toolbar): the
  script is built by `kupcad build` with the values its parameters have in the viewer, so what is
  written is what the CLI builds, in the format you pick (STL, 3MF, STEP, GLB, glTF, OBJ, SVG,
  DXF) and where you say: a 3MF, its parts and colours with it, is what a slicer opens. A script
  with changes not saved is saved first, when you say so; the notification's cancel stops the
  build, and a build that fails says why.

## The `kupcad` it runs

The extension ships no binary: it runs the `kupcad` it finds, or installs one. In this order:

1. the `kupcad.serverPath` setting, whatever its version (a warning says when it is one the
   extension doesn't declare it runs with);
2. its own install, in VS Code's storage for the extension: the newest one there;
3. `kupcad` on `PATH` (`kupcad.exe` on Windows, by that name: a `.cmd` shim isn't run);
4. the monorepo's build at `core/zig-out/bin/kupcad`, only when the extension runs in
   development (F5 from a checkout).

Each of the last three is asked its version (`kupcad version --json`) and run only when it is in
the range the extension declares (`kupcad.core` in its package.json) and speaks its protocol, so
an old `kupcad` on `PATH` never runs under a newer extension. When none fits, the newest release
in range is downloaded from GitHub (a progress notification shows it), checked against the
release's `checksums.txt` before it is unpacked, and installed; if that fails, the message says
why and offers the releases page and the setting, and `KupCAD: Check for Updates` tries again.
Windows installing the same release at once each unpack it apart, and the first to finish
installs it; an install already there is kept.

Once a day (and on `KupCAD: Check for Updates`) the extension's own install looks for a newer
release in range, and installs it and restarts the server with it, or asks first when
`kupcad.binary.autoUpdate` is off; the installs it replaced are removed, but for the one before
(another window may still run it). A newer release out of range says the extension needs
updating first. A `kupcad` from the setting, `PATH` or a checkout is updated where it came from.

Changing `kupcad.serverPath` or `kupcad.viewport.port` starts the server again with it.

## Extension Settings

* `kupcad.serverPath` (machine scope): absolute path to the `kupcad` executable. Empty means "look
  it up as above". Machine scope means a workspace's `.vscode/settings.json` cannot point the
  extension at an arbitrary binary.
* `kupcad.viewport.port`: preferred port for the local viewport WebSocket (default `9001`, `0` =
  always pick a free port). If the port is taken, the server falls back to a free one and the
  viewer follows it.
* `kupcad.binary.autoUpdate` (default `true`): install a newer release of `kupcad` at once,
  instead of asking.
* `kupcad.binary.channel`: `stable` (the default), or `prerelease` to take release candidates.

## Security notes

* The language server evaluates documents on a read-only virtual filesystem: a `.kup` file cannot
  write to disk (`export_*`) just by being opened.
* A downloaded `kupcad` is checked against its release's `checksums.txt`: that catches a download
  broken on the way, not a release replaced on GitHub (both files come from it).
* The viewport socket only listens on `127.0.0.1` and only accepts connections whose `Origin` is a
  VS Code webview. The viewer's page runs under a strict Content Security Policy: no script but
  its own (nonced), no inline style, and no network but that socket.

## Known Issues

* B-Rep (`CAD.config(engine: :brep)`) is in progress: the viewer can't show a B-Rep model (it
  can't be meshed yet), and says so.

## How it is built

Two programs, built separately by Vite:

* **The host** (`src/extension/`, Node, in VS Code's extension host): `main.js` activates it,
  `binary/` finds or installs the `kupcad` it runs (`BinaryManager`, over pure modules: the
  version range, the releases list with its ETag, the archive's name per platform, its checksum,
  unpacking a `.tar.gz` or `.zip` with Node's zlib, the resolution order),
  `server.js` starts the language server (`LanguageServer`: the language client, its starts,
  restarts and stops one after another, the values every script was given sent again to a server
  that (re)started, the viewport's port from `kupcad/viewportReady`, and the server's
  `kupcad.preview` and `kupcad.setParams` commands), `viewer-panel.js` is the viewer's webview
  panel (`ViewerPanel`: it follows the editor to a script in a file, tells the page the document
  it shows and asks the server for its frame, gives the server the panel's values, saves a
  screenshot, and shows the script at a place a run named, its column of UTF-8 bytes counted
  as VS Code counts: `scripts.js`'s `characterAt`), `presets.js` says what a script's presets file holds and `presets-file.js` reads,
  writes and watches it (the panel lists, applies and saves them), `commands.js` exports (over
  `export.js`: the formats, `kupcad build`'s arguments, why a build failed), `values.js` keeps the values each script was
  given, which the server runs it with and an export builds it with, and
  `webview-html.js` writes its page's Content Security Policy. Built into `dist/extension.cjs`,
  the language client in it.
* **The page** (`src/webview/`, in the panel): `App.svelte` is `@kupcad/ui`'s viewer pane and
  parameter panel; `socket.js` reads the server's frames (`@kupcad/protocol`'s `readFrame`),
  opening the socket again when it closes; `bridge.js` talks to the host. Built into
  `dist-webview/`.

The model never passes through the host: a frame can be megabytes, and the page reads it from
the socket itself. The host and the page say the rest to each other in `@kupcad/protocol`'s
`HostMessage` and `ViewerMessage`, each side checking what arrives.

## Development

```sh
pnpm install
pnpm --filter @kupcad/vscode build     # dist/extension.cjs and dist-webview/
pnpm --filter @kupcad/vscode watch     # both, rebuilt as they change
pnpm --filter @kupcad/vscode test      # the host's tests in Node, the page's under jsdom
pnpm --filter @kupcad/vscode check     # svelte-check over both
```

Run it with F5 (an Extension Development Host) after a build; with `watch` running, a change to
the host needs the window reloaded, one to the page `Developer: Reload Webviews`. The host's tests
run against a stand-in for VS Code's API (`src/extension/testing/vscode.js`, which Vitest gives
the code as `vscode`); the page's mount it on models the real core makes (`@kupcad/wasm`).
