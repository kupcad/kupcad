//! `Host`: the optional callbacks the embedder gives the VM for binary operators and method
//! calls it doesn't handle itself, freeing meshes, imports and printing. Held by `vm.zig`.

const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;

// Forward reference to VM
const VM = @import("vm.zig").VM;

/// The Host Platform Interface groups all external callbacks/handlers
/// that decouple the VM runtime from CAD domain logic, file I/O, and UI streaming.
pub const Host = struct {
    binary_handler: ?*const fn (vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value = null,
    mesh_destructor: ?*const fn (handle: GeometryHandle) void = null,
    /// Compiles an imported module's source into its own namespace (see
    /// compiler/module_compiler.zig); the chunk is the caller's. Without one, imports fail.
    compile_module: ?*const fn (vm: *VM, path: []const u8, source: []const u8, namespace: *value.Namespace) anyerror!*chunk.Chunk = null,
    print_handler: ?*const fn (vm: *VM, message: []const u8) void = null,
};
