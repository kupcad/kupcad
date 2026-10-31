# Third-party notices

The `kupcad` binary is KupCAD's own code (`LICENSE`) built together with the software and
fonts below. Each is used under its own license, whose text is in the `licenses` folder of a
release archive at the path given (in the repository: under `core/vendor/` and `core/licenses/`).

| Component | Used for | License | Copyright | License text |
|---|---|---|---|---|
| [Manifold](https://github.com/elalish/manifold) | the mesh geometry kernel | Apache-2.0 | The Manifold Authors | `licenses/manifold/LICENSE` |
| [oneTBB](https://github.com/oneapi-src/oneTBB) | parallel geometry (not in the WebAssembly build) | Apache-2.0; its third-party parts as listed | Intel Corporation | `licenses/onetbb/LICENSE.txt`, `licenses/onetbb/third-party-programs.txt` |
| [Draco](https://github.com/google/draco) | glTF mesh compression | Apache-2.0 | The Draco Authors | `licenses/draco/LICENSE` |
| [Eigen](https://gitlab.com/libeigen/eigen) | linear algebra in the B-Rep engine | MPL-2.0 (a few files under the licenses listed) | Eigen's authors | `licenses/eigen/LICENSE`, `licenses/eigen/LICENSES/` |
| [SQLite](https://sqlite.org) | the package cache | public domain | none | none needed |
| [tatfi](https://git.sr.ht/~asibahi/tatfi) | reading the fonts | MPL-2.0 | tatfi's authors | `licenses/tatfi/LICENSE` |
| [HarfBuzz](https://github.com/harfbuzz/harfbuzz) | shaping text: kerning, ligatures, joining forms and marks | MIT ("Old MIT"); its Universal Shaping Engine tables from Microsoft's data, MIT | HarfBuzz's authors; Microsoft Corporation | `licenses/harfbuzz/COPYING`, `licenses/harfbuzz/ms-use/COPYING` |
| [SheenBidi](https://github.com/Tehreer/SheenBidi) | the direction of text: right-to-left and mixed lines | Apache-2.0 | Muhammad Tayyab Akram | `licenses/sheenbidi/LICENSE` |
| [lsp-kit](https://github.com/zigtools/lsp-kit) | the language server's protocol types | MIT | zig-lsp-codegen contributors | `licenses/lsp-kit-MIT.txt` |
| [Zig standard library](https://ziglang.org) | compiled into the binary | MIT | Zig contributors | `licenses/zig-MIT.txt` |
| Roboto (Regular and Bold), Roboto Mono | the `sans`, `sans-bold` and `mono` text fonts | Apache-2.0 | Google Inc. | `licenses/draco/LICENSE` (the same Apache License 2.0) |
| Roboto Serif | the `serif` text font | OFL-1.1 | The Roboto Serif Project Authors | `licenses/RobotoSerif-OFL.txt` |
| Allerta Stencil | the `stencil` text font | OFL-1.1, Reserved Font Name Allerta | Matt McInerney | `licenses/AllertaStencil-OFL.txt` |
| KupCAD Symbols, a subset of Noto Sans Math, Noto Sans Symbols and Noto Sans Symbols 2 | the symbols `text()` draws when a text's font lacks them | OFL-1.1 | The Noto Project Authors | `licenses/NotoSymbols-OFL.txt` |

KupCAD's copy of tatfi differs from upstream in the files `core/vendor/tatfi/VENDORED.md`
lists; as MPL-2.0 asks, their source is in the KupCAD repository, under `core/vendor/tatfi`.
The C++ runtime (libc++, libc++abi, libunwind) and compiler-rt come with Zig under the
Apache License 2.0 with LLVM Exceptions, which asks for no notice in a binary.
