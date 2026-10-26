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
  module it imports, changes. Its controls are Orca Slicer's: the left button turns, the middle
  and right ones pan, the wheel zooms (with Shift it pans, with Option it moves the section, with
  Cmd it turns the view), and the keys `0`–`6`, `F`, `I` and `O`. Solid, x-ray and wireframe,
  edges, the axes through the origin, a grid or the build plate, the standard views and a view
  cube, a section through the model, and the parts with their colours and copies (a click
  selects a part) in a panel beside it, which the Panel button hides; a screenshot. The script's
  parameters are a panel beside it: a value set there runs the script again with it, checked
  against the parameter's range first; one the run refuses is marked. Under the model, how the
  run went, why it failed and what it warned of: one with a line, clicked, is shown in the
  script's editor.
* **Presets:** named sets of a script's values, kept beside it in `<name>.presets.json`
  (`bracket.kup`'s in `bracket.presets.json`, `{ "presets": { "Small": { "width": 20 } } }`, to
  read, edit and commit with the script). The viewer lists them above the parameters: one chosen
  runs the script with its values; `Save as preset…` keeps the values set in the panel under a
  name (asking before replacing one). An edit of the file shows at once, wherever the script is.
* **Export** (`KupCAD: Export…`, a `.kup` editor's title bar, or the viewer's toolbar): the
  script is built by `kupcad build` with the values its parameters have in the viewer, so what is
  written is what the CLI builds, in the format you pick (STL, 3MF, STEP, GLB, glTF, OBJ, SVG,
  DXF; the viewer's menu offers a 2D model its drawings, SVG and DXF, alone) and where you say: a 3MF, its parts and colours with it, is what a slicer opens. A script
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
why and offers the releases page and the setting, and `KupCAD: Update CLI` tries again.
Windows installing the same release at once each unpack it apart, and the first to finish
installs it; an install already there is kept.

Once a day the extension's own install looks for a newer release in range, and installs it and
restarts the server with it, or asks first when `kupcad.binary.autoUpdate` is off.
`KupCAD: Update CLI` (in the command palette, and in a `.kup` editor's title bar menu beside
Export…) looks at once, and installs what it finds without asking; the installs it replaced are removed, but for the one before
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
  instead of asking. `KupCAD: Update CLI` looks at once.
* `kupcad.binary.channel`: `stable` (the default), or `prerelease` to take release candidates.

## Security notes

* The language server evaluates documents on a read-only virtual filesystem: a `.kup` file cannot
  write to disk (`export_*`) just by being opened.
* A downloaded `kupcad` is checked against its release's `checksums.txt`, which catches a download
  broken on the way, and against its attestation, which catches a release replaced: GitHub keeps,
  by the archive's SHA-256, a SLSA provenance the release workflow signed with Sigstore
  (`actions/attest-build-provenance`), and the archive installs only when that is signed by
  `.github/workflows/release.yml` at the release's tag, through GitHub Actions, checked against
  Sigstore's trusted root (fetched by TUF from `tuf-repo-cdn.sigstore.dev`, kept in the
  extension's storage), as `gh attestation verify` checks it. Its files are taken from the
  repository's release downloads alone, and a download whose redirects end anywhere but GitHub
  and its storage (`objects.githubusercontent.com`, `release-assets.githubusercontent.com`) is
  refused.
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
  as VS Code counts: `@kupcad/protocol`'s `characterAt`), `presets-file.js` reads (the file's format is `@kupcad/protocol`'s),
  writes and watches it (the panel lists, applies and saves them), `commands.js` exports (over
  `export.js`: `kupcad build`'s arguments, why a build failed; the formats are
  `@kupcad/protocol`'s `EXPORT_FORMATS`), `@kupcad/protocol`'s `ScriptValues` keeps the values
  each script was given, which the server runs it with and an export builds it with, and
  `webview-html.js` writes its page's Content Security Policy. Built into `dist/extension.cjs`,
  the language client in it.
* **The page** (`src/webview/`, in the panel): `@kupcad/ui`'s `PreviewPanel`, which reads the
  server's frames from its socket itself (each run in its console too: what the script printed,
  its warnings and its error), themed by VS Code's colours (`vscode.css`);
  `bridge.js` is its host, over the webview's messages. Built into `dist-webview/`.

The model never passes through the host: a frame can be megabytes, and the page reads it from
the socket itself. The host and the page say the rest to each other in `@kupcad/protocol`'s
`HostMessage` and `ViewerMessage`, each side checking what arrives.

## Development

To try the extension from a checkout, from the repository's root:

```sh
pnpm install
pnpm dev:vscode
```

It builds `kupcad` (`core/zig-out/bin/kupcad`) and the extension, then opens a VS Code window on
`examples/` with this extension in it, in place of an installed one. It needs the `code`
command: in VS Code, `Shell Command: Install 'code' command in PATH`.

Or open the repository in VS Code and press F5 (`Run and Debug`, `KupCAD extension`, from
`.vscode/launch.json`): the same build, then an Extension Development Host on `examples/`, with
the debugger on the host's code. Either way the extension runs in development, so it takes the
checkout's `kupcad`, not a release (a `kupcad.serverPath` you set still comes first). Open a
`.kup` file, then `KupCAD: Open Viewer`.

While you work on it:

```sh
pnpm --filter @kupcad/vscode watch     # the host and the page, rebuilt as they change
pnpm --filter @kupcad/vscode test      # the host's tests in Node, the page's under jsdom
pnpm --filter @kupcad/vscode check     # svelte-check over both
pnpm --filter @kupcad/vscode build     # dist/extension.cjs and dist-webview/, once
```

With `watch` running, a change to the host needs the window reloaded (`Developer: Reload
Window`), one to the page (`src/webview/`, or `@kupcad/ui` and `@kupcad/viewer`, which it
bundles) `Developer: Reload Webviews`. A change to the core needs `pnpm build:core:native`, then
the window reloaded, which starts the language server again. The webview's own developer tools
are `Developer: Open Webview Developer Tools`; the host logs to the `KupCAD` output.

The host's tests run against a stand-in for VS Code's API (`src/extension/testing/vscode.js`,
which Vitest gives the code as `vscode`); the page's mount it on models the real core makes
(`@kupcad/wasm`).
