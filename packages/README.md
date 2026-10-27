# KupCAD front ends

Everything in `packages/` is JavaScript (typed by JSDoc) and Svelte, built with Vite and tested
with Vitest, in one pnpm workspace. The geometry, the language and the language server live in `core/` (Zig); the
packages here are the ways a person reaches them: the VS Code extension, the playground on the
docs site, and later a desktop app and a PWA. They are built from shared pieces so that a viewer
or a parameter panel is written once.

See [architecture.md](architecture.md) for how the pieces fit and why.

## The packages

| Package | npm name | What it is | Depends on |
|---|---|---|---|
| `kupcad-protocol` | `@kupcad/protocol` | The types every package agrees on: a built model, a parameter schema, a finding, the messages between a host and a viewer. No dependencies, no runtime code to speak of. | — |
| `kupcad-wasm` | `@kupcad/wasm` | The core compiled to WebAssembly (`kupcad.wasm`, built by `core/build.zig`) with a typed JavaScript API around its exports, and a Web Worker wrapper so a build never blocks the page. | protocol |
| `kupcad-viewer` | `@kupcad/viewer` | The 3D viewer: a framework-free class over three.js that shows a model (GLB) or a drawing (SVG), with the camera, grid, render modes, section plane and part picking; and a thin Svelte component around it. | protocol, three |
| `kupcad-panels` | `@kupcad/panels` | The Svelte components a KupCAD host shows beside its editor: the viewer pane with its toolbar, the parameter panel, presets, the log, and the theme tokens they share. | protocol, viewer |
| `kupcad-editor` | `@kupcad/editor` | A CodeMirror 6 editor for `.kup` files: highlighting by the core's vocabulary, indentation, completion, the findings of `check` marked with their fixes, or a client of `kupcad lsp` (`@codemirror/lsp-client`). For the playground, the PWA and the desktop app; VS Code has its own. | protocol |
| `kupcad-playground` | `@kupcad/playground` | The editor beside the viewer pane and the parameters, all running on `@kupcad/wasm` in a worker in the browser. One Svelte component the site embeds, and the heart of the PWA. | wasm, editor, panels |
| `kupcad-vscode` | `@kupcad/vscode` (private) | The VS Code extension: the language client, the viewer panel (a webview of `@kupcad/panels`), and the manager that downloads the `kupcad` binary from GitHub releases and keeps it current. | protocol, viewer, panels |
| `kupcad-desktop` | `@kupcad/desktop` (private) | The desktop app (Tauri 2): a folder of scripts, `@kupcad/editor` on the bundled `kupcad`'s language server, and `@kupcad/panels`'s preview. | editor, panels, protocol |
| `kupcad-pwa` (later) | private | The web app: the playground with files, projects and exports, installable. | playground |

The site (Astro: the playground's page, the documentation) is in a repository of its own, and
embeds `@kupcad/playground` as its page here (`kupcad-playground/dev/`) does.

Libraries are published to npm under `@kupcad`; apps are `"private": true`. A package is published
only when another repository would use it: the docs site uses the playground, a third-party tool
may use the wasm or the viewer.

## Working on them

```sh
pnpm install                       # once; builds nothing from core
pnpm build:core:wasm               # kupcad.wasm, which @kupcad/wasm copies into its package
pnpm -r build                      # what builds: the module copied into @kupcad/wasm, the extension
pnpm test:packages                 # every package's Vitest suite
pnpm test:browser                  # the viewer's and the playground's smoke tests, headless Chromium
pnpm check                         # oxlint, oxfmt --check, and tsc over every package (CI's gate)
pnpm fmt                           # format what oxfmt would change
pnpm changeset                     # describe a change to a published package
pnpm --filter @kupcad/vscode watch # the extension and its webview, rebuilt as they change
pnpm dev:vscode                    # kupcad and the extension built, a VS Code window to try it in
pnpm dev:playground                # the core built to WebAssembly, the playground at 127.0.0.1:4321
pnpm dev:desktop                  # kupcad built and bundled, the desktop app on examples/ (Rust needed)
```

Trying the extension from a checkout (F5, or `pnpm dev:vscode`) is in its README,
[Development](kupcad-vscode/README.md#development).

Each package has the same shape:

```
kupcad-<name>/
  package.json        name, exports, scripts: test, check, and build where something is built
  README.md           what it is and how to use it (the npm page for a published one)
  src/                the code; src/index.js is the public API
  src/types.d.ts      the shapes JSDoc can't say well (unions, generics), when a package has them
  src/**/*.test.js    tests beside what they test
  vite.config.js      its Vitest config (a Svelte package's spreads the root vitest.svelte.js)
  jsconfig.json       extends the root jsconfig.base.json; sets maxNodeModuleJsDepth to 0
```

The base gives every package Node's types (its configs and tests run in Node). A file named
`jsconfig.json` gets TypeScript's defaults for a JavaScript project over what it extends,
`maxNodeModuleJsDepth: 2` among them, which type-checks the dependencies' own JavaScript
(a `punycode` that pnpm hoists, read in place of `@types/node`'s declaration). So each package's
sets it to 0 itself.

Conventions, held by the root config and CI:

* **JavaScript, typed by JSDoc, and checked.** No TypeScript sources and no compile step for
  types, but each package's `check` runs `tsc` over it (`checkJs`, `strict`, from
  `jsconfig.base.json`) in `pnpm check`, so a wrong `@param` fails CI as a wrong type would.
  The compiler is TypeScript 6, the last written in JavaScript: the Svelte tools (`svelte-check`,
  `@sveltejs/package`) use its API, which TypeScript 7, the native one, doesn't have yet. It
  emits `.d.ts` from JavaScript, so a package, once published, can ship types generated from
  its JSDoc.
* **Svelte 5** (runes) for components, their `<script>` plain JavaScript with JSDoc. A component
  package ships its `.svelte` sources, which the host's Vite compiles: one Svelte runtime per
  app, not one per package. Nothing is built for the packages inside the monorepo, which import
  each other's sources; a package published will be built with `@sveltejs/package`, for its
  `.d.ts`.
* **Vitest** for every package; `@testing-library/svelte` for components; a Web Worker and WebGL
  are stubbed in unit tests, and the viewer has a Playwright smoke test in a real browser.
* **oxlint and oxfmt** from the root (`.oxlintrc.json`, `.oxfmtrc.json`, versions pinned), run by
  `pnpm check`; CI refuses what they would change. oxlint denies its `correctness` and
  `suspicious` rules, warnings included. oxfmt formats the packages' JavaScript and JSON (100
  columns, single quotes) and leaves Markdown and the generated grammar alone. It doesn't
  format `.svelte` files: Prettier with `prettier-plugin-svelte` does, in the same style, and
  `svelte-check` type-checks a Svelte package (its `check`) where `tsc` would miss them.
* **Styling:** the published components (`panels`, `viewer`, `editor`, `playground`) use scoped
  Svelte CSS over the shared `--kc-*` tokens and nothing else, so they drop into any host, the
  VS Code webview included, without a CSS build. An app (the playground page, the PWA, the
  desktop shell) may add Tailwind for its own layout.
* **Changesets** for versions and changelogs: a change to a published package comes with a
  changeset file; `release` bumps and publishes. `@kupcad/wasm` is the exception, which
  Changesets ignores (`.changeset/config.json`): its version is the core's, published by the
  core's release workflow from the same tag.
* **Workspace dependencies** are `workspace:*`, so a package always builds against the sibling
  it sits beside, and `pnpm publish` writes the real version. The tools several packages use
  (Vite, Vitest, Svelte and its checker, jsdom, Node's types) take their version from pnpm's
  `catalog:` in `pnpm-workspace.yaml`, one version for all; a peer range stays the package's.

## Where things come from

* The wasm module is built by `core/build.zig`; `@kupcad/wasm` only wraps it.
* The `kupcad` binary the extension and the desktop app run is a GitHub release asset
  (`kupcad_<version>_<os>_<arch>.tar.gz` or `.zip`, with `checksums.txt`), built by
  `.github/workflows/release.yml`.
* The syntax highlighting of the extension is `syntaxes/kupcad.tmLanguage.json`, generated from
  the grammar by `pnpm build:core:grammar`.
