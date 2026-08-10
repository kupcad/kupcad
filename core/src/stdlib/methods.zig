const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn cadInvokeHandler(vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm; // Explicitly discard the unused VM parameter to satisfy the Zig compiler
    _ = arg_count; // You'll use this later when parsing arguments
    _ = args;

    if (!receiver.isMesh()) {
        std.log.err("Runtime Error: Methods can only be called on Mesh objects.\n", .{});
        return error.RuntimeError;
    }

    // Phase 1 Mock: Accept transform methods and return the mesh unmodified.
    // In Phase 3, we will apply math matrices to the Manifold kernel here.
    if (std.mem.eql(u8, method_name, "translate") or
        std.mem.eql(u8, method_name, "rotate") or
        std.mem.eql(u8, method_name, "chamfer"))
    {
        return receiver; // Return the mutated mesh
    }

    std.log.err("Runtime Error: Unknown method '{s}' on Mesh object.\n", .{method_name});
    return error.RuntimeError;
}
