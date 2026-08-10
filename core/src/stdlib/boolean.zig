const std = @import("std");
const value = @import("../core/value.zig");
const manifold = @import("../bindings/manifold/manifold.zig");
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");

/// This acts as a hook from the pure VM to handle CAD-specific binary operations
pub fn csgBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    // If they aren't both meshes, we can't do CSG math
    if (!a.isMesh() or !b.isMesh()) {
        std.log.err("Runtime Error: Invalid operands for CSG operation\n", .{});
        return error.RuntimeError;
    }

    const m1: *manifold.ManifoldObj = @ptrCast(a.asMesh().kernel_handle.?);
    const m2: *manifold.ManifoldObj = @ptrCast(b.asMesh().kernel_handle.?);

    const result_m = switch (op) {
        .op_add => manifold.boolean(m1, m2, .add),
        .op_subtract => manifold.boolean(m1, m2, .subtract),
        // Note: When you add op_bitwise_and to your VM for `a & b`, handle it here:
        // .op_bitwise_and => manifold.boolean(m1, m2, .intersect),
        else => {
            std.log.err("Runtime Error: Unsupported CSG operator\n", .{});
            return error.RuntimeError;
        },
    };

    // Allocate the resulting mesh on the VM heap
    return try vm.allocateMesh(result_m, &[_]value.Vec3{}, &[_][3]u32{});
}
