# Kupcad (Kup Computer-Aided Design) [![Tests](https://github.com/kupcad/kupcad/actions/workflows/tests.yml/badge.svg)](https://github.com/kupcad/kupcad/actions/workflows/tests.yml)

```
kupcad/
├── pnpm-workspace.yaml          # pnpm workspace configuration
├── package.json                 # Root scripts for running web, desktop, lsp
│
├── apps/                        # --- APPLICATION TARGETS ---
│   ├── web/                     # Svelte 5 Web Application (PWA)
│   │   ├── src/                 # Svelte 5 App (Canvas, Editor, UI)
│   │   ├── static/wasm/         # Linked kupcad.wasm build artifact
│   │   └── package.json
│   │
│   ├── desktop/                 # Electron Desktop Application
│   │   ├── src/
│   │   │   ├── main/            # Electron Main Process (Loads native kupcad dynamic lib)
│   │   │   ├── preload/         # Electron Preload script
│   │   │   └── renderer/        # Shared/Imported Svelte UI components
│   │   ├── native/              # Symlinked/built native .so / .dll / .dylib
│   │   └── package.json
│   │
│   └── vscode-extension/        # VS Code Extension (LSP Client)
│       ├── src/                 # Extension host code
│       ├── bin/                 # Bundled kupcad-lsp executable
│       └── package.json
│
├── core/                        # --- ZIG CORE CAD ENGINE ---
│   ├── build.zig                # Master Zig Build Script (Outputs CLI, WASM, LSP, Dynamic Lib)
│   ├── build.zig.zon              # Zig dependencies (manifoldc, opencascade-c)
│   │
│   ├── src/                     # All Zig Source Files
│   │   ├── main.zig             # Native CLI entry
│   │   ├── wasm_api.zig         # WebAssembly C-API (for apps/web)
│   │   ├── ffi_api.zig          # C-FFI / N-API (for apps/desktop)
│   │   ├── core/                # Value types, symbol pool, memory
│   │   ├── parsers/             # Dual Parsers (.kupcad & .scad)
│   │   ├── evaluator/           # VM Interpreter & Scope
│   │   ├── kernel/              # GeometryKernel VTable (Manifold3D / OCCT)
│   │   ├── exporters/           # STL, STEP, SVG, DXF, 3MF
│   │   └── lsp/                 # Language Server Protocol logic
│   │
│   └── std/                    # Embedded Standard Library (.kupcad files)
│       ├── hardware.kupcad
│       ├── mechanics.kupcad
│       └── colors.kupcad
│
├── packages/                    # --- SHARED PACKAGES & TS LIBRARIES ---
│   ├── ui/                      # Shared Svelte 5 CAD Editor UI components
│   │   ├── Viewport.svelte      # Three.js / WebGL 3D Canvas
│   │   ├── CodeEditor.svelte    # Monaco Editor configured for .kupcad
│   │   └── package.json
│   │
│   ├── wasm-bridge/             # TypeScript wrapper around kupcad.wasm
│   │   ├── src/index.ts         # Type-safe TS calls into WebAssembly
│   │   └── package.json
│   │
│   └── native-bridge/           # Node.js N-API / C-FFI bindings
│       ├── src/index.ts         # Type-safe TS calls into kupcad_native.dll/so
│       └── package.json
│
└── shared/                      # --- SHARED ASSETS & CAD DATA ---
    ├── std-lib/                 # Source of truth for .kupcad std modules
    ├── test-models/             # Shared CAD models (.kupcad / .scad) for E2E tests
    └── schemas/                 # Shared JSON schemas (LSP configs, Settings)
```

```
kupcad/
├── build.zig                   # Multi-target build script (Native CLI, WASM, LSP)
├── build.zig.zon               # Zig dependencies (manifoldc, opencascade-c, etc.)
│
├── src/
│   ├── main.zig                # Native CLI binary entry point
│   ├── wasm_api.zig            # WebAssembly C-API for Svelte 5 Web UI
│   │
│   ├── core/                   # --- CORE VM & MEMORY ---
│   │   ├── value.zig           # Dynamic Tagged Union (Numbers, Symbols, Geometry)
│   │   ├── symbol_pool.zig     # String Interner Pool (u32 Symbol IDs)
│   │   ├── arena.zig           # AST & Memory Allocation strategy
│   │   └── errors.zig          # Centralized Error Reporting & Source Spans
│   │
│   ├── parsers/                # --- DUAL PARSER FRONTENDS ---
│   │   ├── common/             # Universal AST & Tokens
│   │   │   ├── ast.zig         # Standard Geometry AST representation
│   │   │   └── token.zig       # Source Code Spans (Line, Col, File)
│   │   │
│   │   ├── kupcad/              # Native .kupcad Parser (Ruby-style syntax)
│   │   │   ├── lexer.zig       # Tokenizer for .kupcad
│   │   │   └── parser.zig      # Pratt Parser (emits Universal AST)
│   │   │
│   │   └── openscad/           # Legacy .scad Parser (OpenSCAD compatibility)
│   │       ├── lexer.zig       # OpenSCAD Tokenizer
│   │       └── parser.zig      # OpenSCAD Module/Function Parser
│   │
│   ├── evaluator/              # --- AST EVALUATOR & SCOPE ---
│   │   ├── vm.zig              # AST Tree Evaluator / Interpreter
│   │   ├── scope.zig           # Variable & Module Scope Environment
│   │   └── importer.zig        # Import Resolver ("std/", "./", packages)
│   │
│   ├── kernel/                 # --- KERNEL ABSTRACTION (MULTI-ENGINE) ---
│   │   ├── kernel.zig          # GeometryKernel Interface (VTable / Trait)
│   │   ├── geometry_handle.zig # Agnostic geometry node pointer wrapper
│   │   │
│   │   ├── engines/            # Concrete Engine Drivers
│   │   │   ├── manifold/       # Engine 1: Fast Mesh CSG (3D Printing / WASM)
│   │   │   │   ├── manifold_ffi.zig  # C-bindings to Manifold3D
│   │   │   │   └── driver.zig        # Manifold VTable implementation
│   │   │   │
│   │   │   └── occt/           # Engine 2: B-Rep NURBS (CNC / STEP export)
│   │   │       ├── occt_ffi.zig      # C-bindings to OpenCASCADE
│   │   │       └── driver.zig        # OpenCASCADE VTable implementation
│   │   │
│   │   └── shape2d/            # Exact 2D Vector Geometry engine (Polylines/Arcs)
│   │       └── planar_path.zig # Native 2D Planar Engine for Laser/Waterjet
│   │
│   ├── exporters/              # --- MULTI-FORMAT EXPORTERS ---
│   │   ├── exporter.zig        # Universal Exporter Interface
│   │   │
│   │   ├── 3d/                 # 3D Solid / Surface Exporters
│   │   │   ├── stl_binary.zig  # Binary STL Writer (Mesh CSG)
│   │   │   ├── stl_ascii.zig   # ASCII STL Writer (Mesh CSG)
│   │   │   ├── 3mf.zig         # 3MF Package Exporter (Mesh CSG)
│   │   │   ├── obj.zig         # Wavefront OBJ Exporter (Mesh CSG)
│   │   │   └── step.zig        # STEP / IGES Exporter (B-Rep / OCCT)
│   │   │
│   │   └── 2d/                 # 2D CNC & Vector Exporters
│   │       ├── dxf.zig         # AutoCAD DXF Writer (True Arcs/Lines for CNC)
│   │       └── svg.zig         # Scalable Vector Graphics Writer
│   │
│   ├── lsp/                    # --- LSP SERVER ---
│   │   ├── main.zig            # kupcad-lsp binary entry
│   │   ├── server.zig          # JSON-RPC Protocol handler
│   │   └── diagnostics.zig     # Real-time AST error reporter
│   │
│   └── std/                    # --- EMBEDDED STANDARD LIBRARY ---
│       ├── hardware.kupcad      # Embedded std/hardware module
│       ├── mechanics.kupcad     # Embedded std/mechanics module
│       ├── colors.kupcad        # Embedded std/colors module
│       └── math.kupcad          # Embedded std/math module
│
├── tests/                      # Integration Test Suite
│   ├── kupcad_tests/            # .kupcad language unit tests
│   ├── openscad_tests/         # .scad compatibility unit tests
│   ├── kernel_tests/           # Manifold vs. OCCT consistency tests
│   └── exporter_tests/         # STL, STEP, and DXF validity checks
│
└── examples/                   # Sample CAD models
    ├── parametric_box.kupcad
    └── cnc_milled_bracket.kupcad
```

```
├── .vscode/
│   ├── launch.json         # Debug configurations
│   └── tasks.json          # Pre-launch compile tasks
├── src/                    # Backend Extension Code
│   ├── extension.ts        # Entry point
│   └── utils.ts
├── webview/                # Frontend Webview Code (React/Vue/Svelte)
│   ├── src/
│   ├── index.html
│   └── vite.config.ts      # Frontend bundler setup
├── tests/                  # Unit and Integration Tests
│   └── extension.test.ts
├── package.json            # Extension manifest
├── vite.config.node.ts     # Backend extension bundler setup
└── vitest.config.ts        # Vitest testing environment configuration

```

## Deps

```
zig build test -Dtest-filter="Point Segregation Bug"
```

```
brew install binaryen wabt wasmtime
wasm-opt --all-features -Oz kupcad.wasm -o kupcad_min.wasm
/opt/homebrew/opt/binaryen/bin/wasm-opt --all-features -Oz core/zig-out/bin/kupcad.wasm -o core/zig-out/bin/kupcad_min.wasm
```


## License

KupCAD is dual-licensed:

* **Open-Source:** Released under the [GNU Affero General Public License v3.0 (AGPLv3)](./LICENSE.txt).
* **Commercial:** For proprietary integrations, closed-source SaaS backends, or enterprise support, see our [Commercial Licensing Options](#).

> **Note on Model Output:** 3D files (STL, 3MF, STEP) exported by KupCAD belong 100% to you and are **not** subject to AGPL copyleft terms.

For common questions regarding commercial usage, derivative works, and contribution guidelines, read our [License FAQ](./LICENSE-FAQ.md) and [Contributor License Agreement (CLA)](./.github/CLA.md).
