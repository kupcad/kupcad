# KupCAD System Architecture & Memory Model

The KupCAD pipeline is structured as a classical multi-pass language pipeline, heavily optimized for zero-waste memory access and explicit memory ownership.

```
[ Source Text ]
      │
      ▼
   [ Lexer ]  ──(SoA Token Lists)──► [ Parser ]
                                        │
                                        ▼
                                  [ AST Tree ] ──(Arena Backed)
                                        │
                                        ▼
                                  [ Compiler ]
                                        │
                        ┌───────────────┴───────────────┐
                        ▼                               ▼
                 [ GC Engine ]                   [ Bytecode Chunk ]
                 (Mark-Sweep Heap)                      │
                        │                               ▼
                        └─────────────► [ VM Runtime ] ◄──(ARC Geometry)
                                         │     │
                 ┌───────────────────────┘     └────────────────────────┐
                 ▼                                                      ▼
          [ Host Interface ]                                    [ JIT DAG Engine ]
    (I/O, UI, Dispatches)                                               │
                                                                        ▼
                                                             [ Geometry Kernel Bridge ]
                                                                        │
                                                       ┌────────────────┴────────────────┐
                                                       ▼                                 ▼
                                              [ Manifold C++ Driver ]           [ Native B-Rep Driver ]

```

---

## 1. Lexical Analysis (The Lexer)

The Lexer scans raw source text and converts character streams into tokens using a **Structure of Arrays (SoA)** memory layout.

### Key Mechanics

* **Zero Allocation Scanning:** The Lexer does not allocate individual token objects. It scans strings directly from memory and records byte offsets.
* **SoA Token Storage:** Tokens are stored across three contiguous, cache-line-friendly arrays:
* `tags: []Tag` (e.g., `.keyword_def`, `.number`, `.ident`)
* `starts: []u32` (Source code byte offsets)
* `lengths: []u32` (Token byte lengths)


* **Perfect Keyword Hashing:** Identifiers are evaluated via `std.StaticStringMap` at compile time, yielding $O(1)$ keyword resolution without allocations or string branching.

```zig
// Data layout inside TokenList
pub fn TokenList(comptime Tag: type) type {
    return struct {
        tags: []const Tag,
        starts: []const u32,
        lengths: []const u32,
    };
}

```

---

## 2. Abstract Syntax Tree (The AST)

The AST uses a **Data-Oriented Cache-Dense Layout**. Nodes do not use heap pointers or object graphs.

### AST Memory Layout

* **Compact Node Size:** Every AST `Node` is packed into **exactly 8 bytes** for L1 cache line density.
* **Index-Based References:** Nodes refer to child nodes, spans, or interned strings using 32-bit integer indices (`NodeIndex`, `StringId`) instead of pointers.
* **Side-Table Metadata:** Extended payloads (such as function parameters or multi-branch `case/when` lists) are appended to a contiguous `extra_data: ArrayListUnmanaged(u32)` buffer.

```
┌────────────────────────────────────────────────────────┐
│                        Node (8B)                       │
├───────────────────┬───────────────────┬────────────────┤
│    tag (Enum)     │  main_token (u24) │   data (u32)   │
└───────────────────┴───────────────────┴────────────────┘

```

### String Interning

All identifier and string literal characters are stored in a dedicated String Pool. If two functions use `"width"`, both AST nodes point to the exact same `StringId`, eliminating string duplicates and making name comparisons simple $O(1)$ integer equality checks.

---

## 3. Bytecode Compilation (The Compiler)

The Compiler traverses the AST and translates nodes into virtual machine instruction streams called **Chunks**.

```
      AST Node (.binary_op)
       ├── left:  Node (.number 10)
       └── right: Node (.number 5)
                │
                ▼
      [ Compiler Processing ]
                │
                ▼
Bytecode Output:
  0x00: op_constant 0  (Pushes 10.0 onto VM Stack)
  0x02: op_constant 1  (Pushes 5.0 onto VM Stack)
  0x04: op_add         (Pops both, pushes 15.0)

```

### Lexical Scoping & Closures

* **Locals vs. Globals:** Local variables live directly in stack slots. Name lookup is resolved at compile time to a single byte index (`op_get_local slot_idx`).
* **Upvalues:** When a closure captures a variable from an outer function, the Compiler generates an `Upvalue` map. The VM bridges this slot either directly on the stack or hoists it to the heap if the outer function returns.

### Stack Depth Simulation

During compilation, the Compiler maintains `current_stack_depth` and `max_stack_depth` counters. This allows the VM to pre-allocate its evaluation stack for any function frame in a single allocation, completely avoiding stack overflow panics during execution.

---

## 4. Virtual Machine Runtime & Memory Management

KupCAD uses a **Dual-Engine Memory Model** to balance performance for language objects versus geometry data.

```
                  VM Memory Space
        ┌────────────────────────────────┐
        │  Garbage Collector (Tracing)   │
        │  • Strings, Arrays, Maps       │
        │  • Closures, Classes, Functions│
        └────────────────────────────────┘
        ┌────────────────────────────────┐
        │  ARC Subsystem (Deterministic) │
        │  • ObjGeometry (C++ Pointers)  │
        │  • ObjWorkplane (Faces/Planes) │
        └────────────────────────────────┘

```

### Memory Engine A: Tracing Mark-and-Sweep GC

Used for language-level metadata (Strings, Arrays, Maps, Functions, Classes, and Upvalues).

* **Phase 1 (Mark):** Traces reachable objects starting from root pointers (the VM Stack, CallFrames, and Global maps).
* **Phase 2 (Sweep):** Iterates through the global object linked-list and instantly frees unreferenced objects.

### Memory Engine B: Automatic Reference Counting (ARC)

Used exclusively for heavy **CAD Geometry Mesh Data**.

* Heavy 3D meshes are wrapped in an `ObjGeometry` header.
* Every time a mesh is assigned or pushed, `ref_count += 1`.
* As soon as a variable leaves scope or a stack frame unwinds, `ref_count -= 1`.
* When `ref_count == 0`, the VM **instantly invokes the native C++ destructor**. This guarantees that multi-gigabyte geometry allocations are freed deterministically without waiting for a GC sweep.

---

## 5. Exception Handling & Stack Unwinding

When `raise("Error")` or an opcode throw occurs:

```
[ Active Call Stack ]          [ Rescue Frame Stack ]
  Frame 3 (deep_calc)
  Frame 2 (process_mesh)  ───►  Rescue Handler (handler_ip)
  Frame 1 (main)                 Stack Pointer Reset Target

```

1. **Rescue Registration:** Entering a `begin` block emits `op_setup_rescue`, pushing a `RescueFrame` containing the current stack height, frame count, and jump target (`handler_ip`).
2. **Throw Execution:** When `op_throw` runs, the VM pops the exception object and checks for active `RescueFrames`.
3. **Unwinding Loop:**
* It unwinds captured closures (`closeUpvalues`).
* It pops dead `CallFrame` records off the stack.
* It pops local variables off the VM stack, decrementing ARC reference counts on any active geometry objects.


4. **Rescue Execution:** The VM sets its instruction pointer directly to `handler_ip` and pushes the error payload onto the clean stack.

---

## 6. Host Platform Interface (The Host)

The **Host Platform Interface** (`vm/host.zig`) completely decouples the Virtual Machine runtime core from OS dependencies, stdout/stderr output streams, file I/O, and outer GUI embedding environments.

### Architecture & Callbacks

The VM does not write directly to terminal streams or execute foreign mesh logic on its own. Instead, it delegates these tasks to standard C-function pointer hooks inside the `Host` struct:

* `print_handler`: Intercepts calls from `puts()`, `print()`, and `p()`. In CLI mode, it routes to `stdout`; inside WebAssembly or GUI apps, it streams text directly to output widgets.
* `binary_handler`: Intercepts CSG binary operations (like `+` and `-`) between two `ObjGeometry` instances.
* `invoke_handler`: Handles native geometry method dispatches (such as `.translate()`, `.on_face()`, `.bbox()`).
* `mesh_destructor`: Called directly by the ARC manager when an `ObjGeometry`'s reference count reaches 0.
* `import_handler`: Intercepts file system imports (`import "lib.kup"`) to load and compile remote files.

```zig
pub const Host = struct {
    binary_handler: ?*const fn (vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value = null,
    invoke_handler: ?*const fn (vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value = null,
    mesh_destructor: ?*const fn (handle: GeometryHandle) void = null,
    import_handler: ?*const fn (vm: *VM, path: []const u8) anyerror!value.Value = null,
    print_handler: ?*const fn (vm: *VM, message: []const u8) void = null,
};

```

---

## 7. Geometry Kernel Bridge & Engine Drivers

The **Geometry Kernel Architecture** (`kernel/`) abstracts specific 3D solid modeling backends behind a unified, polymorphic Zig interface (`GeometryKernel`).

### 1. Tagged Geometry Handles

A `GeometryHandle` wraps foreign C++ opaque pointers inside a tagged struct:

```zig
pub const EngineType = enum { manifold, brep_native };

pub const GeometryHandle = struct {
    engine: EngineType,
    ptr: *anyopaque,
};

```

### 2. Polymorphic Kernel VTable

The VM interacts with 3D kernels exclusively through a dispatch struct (`GeometryKernel`) containing C-function pointers:

* `cubeFn`: Instantiates solid cube primitives.
* `booleanFn`: Executes Booleans (Union, Difference, Intersection).
* `transformFn`: Applies 4x4 matrix transforms.
* `boundingBoxFn`: Calculates exact bounding boxes.
* `queryFacesFn`: Queries face handles matching filters (e.g., `:top`, `:bottom`).
* `destructFn`: Destroys the underlying C++ mesh allocation.

### 3. Backend Engine Drivers

KupCAD supports pluggable backend engines:

* **Manifold Engine Driver (`kernel/engines/manifold/driver.zig`):** Translates Zig calls into C FFI bindings (`bindings/manifold/manifold.zig`), communicating with the fast, manifold-guaranteed C++ Manifold library.
* **Native B-Rep Driver (`kernel/engines/brep/driver.zig`):** Handles exact topological boundary representation structures (`Point3D`, `Vertex`, `Edge`, `Face`, `Solid`) for exact CAD operations.

---

## 8. Lazy JIT Geometry Evaluation (The DAG)

KupCAD uses a **Directed Acyclic Graph (DAG)** to defer expensive C++ CAD calculations.

When a script calls `cube(10).translate(x: 5)`, no C++ geometry operations are executed immediately.

```
Script Execution:
  c = cube(10)          --> Appends DAG Node #0 (.cube)
  t = c.translate(x: 5) --> Appends DAG Node #1 (.translate -> Node #0)

Materialization Phase (e.g., export_stl):
  ensureConcrete(t)     --> Traverses DAG Node #1
                            ├── Evaluates Node #0 via C++ Kernel (cubeImpl)
                            └── Evaluates Node #1 via C++ Kernel (transformImpl)

```

By buffering geometry operations inside `DAGBuilder`, the VM can optimize topological trees, eliminate redundant operations, and defer mesh evaluations until export or display.

---

## Summary Checklist

| Component          | Responsibility                            | Memory Strategy                             |
|--------------------|-------------------------------------------|---------------------------------------------|
| **Lexer**          | Source text $\rightarrow$ SoA Token Lists | Zero-allocation byte slices                 |
| **AST**            | Structural parsing & interning            | 8-byte cache-dense nodes, Arena-backed      |
| **Compiler**       | AST $\rightarrow$ Bytecode Chunk          | Fixed stack depth analysis                  |
| **VM**             | Execution, stack frame evaluation         | Pre-allocated dynamic evaluation stack      |
| **GC / ARC**       | Heap management                           | Tracing GC for metadata, ARC for C++ meshes |
| **Host**           | Decouples VM from IO & OS dependencies    | Function pointer callback interface         |
| **Kernel Bridge**  | Abstract VTable interface to 3D engines   | Function pointer dispatch table             |
| **Engine Drivers** | C++ FFI translation (Manifold/B-Rep)      | Direct native allocations                   |
| **DAG**            | CSG operation buffering                   | Contiguous arena array graph                |
