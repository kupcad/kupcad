const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const kernel_mod = @import("../kernel/kernel.zig");

pub fn csgBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    if (!a.isMesh() or !b.isMesh()) {
        std.log.err("Runtime Error: Invalid operands for CSG operation\n", .{});
        return error.RuntimeError;
    }

    const kernel = vm.active_kernel orelse return error.RuntimeError;

    // Map VM Opcodes to the generic Geometry Kernel Interface
    const bool_op: kernel_mod.BooleanOp = switch (op) {
        .op_add => .union_op,
        .op_subtract => .difference_op,
        // .op_bitwise_and => .intersection_op, (when implemented in VM)
        else => {
            std.log.err("Runtime Error: Unsupported CSG operator\n", .{});
            return error.RuntimeError;
        },
    };

    // DISPATCH: Perform the CSG boolean dynamically through the VTable
    const result_h = kernel.boolean(a.asMesh().kernel_handle, b.asMesh().kernel_handle, bool_op);
    return try vm.allocateMesh(result_h, &[_]value.Vec3{}, &[_][3]u32{});
}
