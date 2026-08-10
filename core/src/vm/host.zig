const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;

// Forward reference to VM
const VM = @import("vm.zig").VM;

/// The Host Platform Interface groups all external callbacks/handlers
/// that decouple the VM runtime from CAD domain logic, file I/O, and UI streaming.
pub const Host = struct {
    binary_handler: ?*const fn (vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value = null,
    invoke_handler: ?*const fn (vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value = null,
    mesh_destructor: ?*const fn (handle: GeometryHandle) void = null,
    import_handler: ?*const fn (vm: *VM, path: []const u8) anyerror!value.Value = null,
    print_handler: ?*const fn (vm: *VM, message: []const u8) void = null,
};
