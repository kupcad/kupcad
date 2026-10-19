# KupCAD is a high-level, expression-based parametric CAD language [![Tests](https://github.com/kupcad/kupcad/actions/workflows/tests.yml/badge.svg)](https://github.com/kupcad/kupcad/actions/workflows/tests.yml)

KupCAD (`.kup`) is a Ruby-inspired, method-chaining language for parametric CAD. Scripts run on a
custom Zig bytecode VM and build geometry through two engines: [Manifold](https://github.com/elalish/manifold)
for fast mesh CSG and previews, and the native B-Rep kernel (Locus, in progress) for exact STEP output.

* Language reference and standard library: [core/docs/README.md](core/docs/README.md)
* Runtime, memory model, limits and sandboxing: [core/docs/architecture.md](core/docs/architecture.md)
* Examples: [examples/](examples/)
* VS Code extension: [packages/kupcad-vscode](packages/kupcad-vscode/README.md)

## Work in progress

The language, VM and Manifold path are usable; the B-Rep kernel (`core/src/locus`) and the viewport
webview are not finished. See the extension README for current limitations.

## Build

Requires the Zig version in [`.tool-versions`](.tool-versions) (managed with `asdf`), Node 24 and
`pnpm`; vendored C++ libraries are git submodules.

```sh
git clone --recurse-submodules https://github.com/kupcad/kupcad
pnpm install
cd core && zig build                     # -> core/zig-out/bin/kupcad
zig build -Doptimize=ReleaseFast         # release build
```

```sh
pnpm test:core                           # Zig test suite (debug build)
pnpm test:wasm                           # WASM tests via wasmtime
cd core && zig build test -Dtest-filter="Compiler Guardrail"   # a subset
```

A passing run prints nothing but the summary. A test that provokes a warning on purpose calls `test_support.expectWarnings()` first, so any warning that does appear is a real one.

## Usage

```sh
kupcad build part.kup -o part.stl                  # export (stl | glb | gltf | step), --draco for GLB
kupcad build part.kup --param width=50 -f step     # inject parameters, pick a format (-p/-o/-f/-d short flags)
kupcad build part.kup -P bracket.json              # parameter values from a JSON object
kupcad build part.kup --bom bom.json               # also write the parts list (count, volume, mass)
kupcad build part.kup -o part.3mf                  # 3MF: each part once, placed per copy, with colours
kupcad build part.kup --split parts/               # one STL per part, as made, for printing
kupcad check part.kup                              # lint
kupcad fmt part.kup                                # format
kupcad watch part.kup -P bracket.json              # rebuild on change, with parameter values
kupcad doc part.kup                                # parameters + docstrings as JSON
kupcad pkg add hardware=github.com/user/repo       # add a dependency to kupcad.json
kupcad pkg install                                 # resolve, verify kupcad.lock, link .kupcad/pkg/
kupcad pkg doctor                                  # check the local package store
kupcad lsp                                         # language server over stdio (used by the extension)
kupcad dev ast-dump|disasm|lex-dump|bench part.kup # compiler/VM tooling
```

Every command exits 0 on success and 1 on any failure (bad arguments, unreadable files, syntax or
runtime errors, lint errors), so all of them are safe as CI steps. `kupcad --help` lists the commands
and `kupcad --version` prints the version. Environment variables:

| Variable | Purpose |
|---|---|
| `KUPCAD_HOME` | Package cache directory (default `~/.kupcad`) |
| `KUPCAD_VIEWPORT_PORT` | Preferred port for the LSP viewport WebSocket (default `9001`, falls back to a free port) |

## Developer notes

```sh
# regenerate the sqlite translation
cd core && zig translate-c vendor/sqlite/sqlite3.h > vendor/sqlite/sqlite_bindings.zig

# shrink the wasm build
brew install binaryen wabt wasmtime
wasm-opt --all-features -Oz core/zig-out/bin/kupcad.wasm -o core/zig-out/bin/kupcad_min.wasm
```

## License

KupCAD is dual-licensed:

* **Open-Source:** Released under the [GNU Affero General Public License v3.0 (AGPLv3)](./LICENSE).
* **Commercial:** For proprietary integrations, closed-source SaaS backends, or enterprise support, see our [Commercial Licensing Options](#).

> **Note on Model Output:** 3D files (STL, 3MF, STEP) exported by KupCAD belong 100% to you and are **not** subject to AGPL copyleft terms.

For common questions regarding commercial usage, derivative works, and contribution guidelines, read our [License FAQ](./LICENSE-FAQ.md) and [Contributor License Agreement (CLA)](./.github/CLA.md).
