# Zscad

```
zscad/
├── pnpm-workspace.yaml          # pnpm workspace configuration
├── package.json                 # Root scripts for running web, desktop, lsp
│
├── apps/                        # --- APPLICATION TARGETS ---
│   ├── web/                     # Svelte 5 Web Application (PWA)
│   │   ├── src/                 # Svelte 5 App (Canvas, Editor, UI)
│   │   ├── static/wasm/         # Linked zscad.wasm build artifact
│   │   └── package.json
│   │
│   ├── desktop/                 # Electron Desktop Application
│   │   ├── src/
│   │   │   ├── main/            # Electron Main Process (Loads native zscad dynamic lib)
│   │   │   ├── preload/         # Electron Preload script
│   │   │   └── renderer/        # Shared/Imported Svelte UI components
│   │   ├── native/              # Symlinked/built native .so / .dll / .dylib
│   │   └── package.json
│   │
│   └── vscode-extension/        # VS Code Extension (LSP Client)
│       ├── src/                 # Extension host code
│       ├── bin/                 # Bundled zscad-lsp executable
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
│   │   ├── parsers/             # Dual Parsers (.zscad & .scad)
│   │   ├── evaluator/           # VM Interpreter & Scope
│   │   ├── kernel/              # GeometryKernel VTable (Manifold3D / OCCT)
│   │   ├── exporters/           # STL, STEP, SVG, DXF, 3MF
│   │   └── lsp/                 # Language Server Protocol logic
│   │
│   └── std/                    # Embedded Standard Library (.zscad files)
│       ├── hardware.zscad
│       ├── mechanics.zscad
│       └── colors.zscad
│
├── packages/                    # --- SHARED PACKAGES & TS LIBRARIES ---
│   ├── ui/                      # Shared Svelte 5 CAD Editor UI components
│   │   ├── Viewport.svelte      # Three.js / WebGL 3D Canvas
│   │   ├── CodeEditor.svelte    # Monaco Editor configured for .zscad
│   │   └── package.json
│   │
│   ├── wasm-bridge/             # TypeScript wrapper around zscad.wasm
│   │   ├── src/index.ts         # Type-safe TS calls into WebAssembly
│   │   └── package.json
│   │
│   └── native-bridge/           # Node.js N-API / C-FFI bindings
│       ├── src/index.ts         # Type-safe TS calls into zscad_native.dll/so
│       └── package.json
│
└── shared/                      # --- SHARED ASSETS & CAD DATA ---
    ├── std-lib/                 # Source of truth for .zscad std modules
    ├── test-models/             # Shared CAD models (.zscad / .scad) for E2E tests
    └── schemas/                 # Shared JSON schemas (LSP configs, Settings)
```
