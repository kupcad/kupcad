# KupCAD for VS Code

Language support for [KupCAD](https://github.com/kupcad/kupcad) (`.kup`) files, backed by the
`kupcad lsp` language server.

## Features

* Syntax highlighting and language configuration for `.kup`.
* Diagnostics and hover information from the language server.
* `KupCAD: Open Viewer` opens a viewport panel that connects to the language server's local
  WebSocket and receives the current model as GLB whenever the document changes.

## Requirements

A `kupcad` executable (built from the repository: `cd core && zig build`). The extension looks for it
in this order:

1. the `kupcad.serverPath` setting,
2. `kupcad` on `PATH`,
3. the monorepo development build at `core/zig-out/bin/kupcad` (only when running from the repo).

## Extension Settings

* `kupcad.serverPath` (machine scope): absolute path to the `kupcad` executable. Empty means "look it
  up as above". Machine scope means a workspace's `.vscode/settings.json` cannot point the extension at
  an arbitrary binary.
* `kupcad.viewport.port`: preferred port for the local viewport WebSocket (default `9001`, `0` = always
  pick a free port). If the port is taken, the server falls back to a free one and the extension follows
  it automatically.

## Security notes

* The language server evaluates documents on a read-only virtual filesystem: a `.kup` file cannot write
  to disk (`export_*`) just by being opened.
* The viewport socket only listens on `127.0.0.1` and only accepts connections whose `Origin` is a
  VS Code webview (or the local dev server during development); the webview itself runs under a strict,
  nonce-based Content Security Policy.

## Known Issues

* The viewport webview front-end is a stub: the panel opens, receives the socket URL, and the server
  streams models, but there is no renderer yet.
* B-Rep (`CAD.config(engine: :brep)`) is in progress; use the default Manifold engine for previews.

## Development

```sh
pnpm install
pnpm --filter @kupcad/vscode build     # bundles dist/extension.cjs and dist-webview/
pnpm --filter @kupcad/vscode watch     # rebuild on change
pnpm --filter @kupcad/vscode test      # vitest unit tests (webview helpers)
```

`test/extension.test.js` is a VS Code-hosted test (`@vscode/test-cli`, see `.vscode-test.mjs`) and is
excluded from vitest.
