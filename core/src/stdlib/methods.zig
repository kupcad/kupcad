const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const manifest = @import("manifest.zig");

pub fn cadInvokeHandler(vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = vm;
    _ = arg_count;
    _ = args;

    if (!receiver.isMesh()) {
        std.log.err("Runtime Error: Methods can only be called on Mesh objects.\n", .{});
        return error.RuntimeError;
    }

    // Phase 1 Mock: Accept transform methods dynamically mapped in our manifest
    inline for (manifest.mesh_methods) |method| {
        if (std.mem.eql(u8, method_name, method.name)) {
            return receiver; // Return the mutated mesh
        }
    }

    std.log.err("Runtime Error: Unknown method '{s}' on Mesh object.\n", .{method_name});
    return error.RuntimeError;
}
