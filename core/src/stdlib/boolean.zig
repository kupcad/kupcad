const std = @import("std");
const value = @import("../core/value.zig");
const dag = @import("../vm/dag.zig");
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const kernel_mod = @import("../kernel/kernel.zig");

pub fn csgBinaryHandler(vm: *VM, op: chunk.OpCode, a: value.Value, b: value.Value) anyerror!value.Value {
    if (!a.isGeometry() or !b.isGeometry()) {
        std.log.err("Runtime Error: Invalid operands for CSG operation\n", .{});
        return error.RuntimeError;
    }

    const geom_a = a.asGeometry();
    const geom_b = b.asGeometry();

    const dag_tag: dag.DAGTag = switch (op) {
        .op_add => .union_op,
        .op_subtract => .difference_op,
        // .op_bitwise_and => .intersection_op,
        else => return error.RuntimeError,
    };

    // Append a binary node linking the two parents
    const result_idx = try vm.dag_builder.addBinary(dag_tag, geom_a.dag_idx, geom_b.dag_idx);

    const ptr = try vm.allocator.create(value.ObjGeometry);
    ptr.* = .{
        .obj = .{
            .obj_type = .geometry,
            .is_marked = false,
            .next = null, // Leaves this out of the GC tracking loop
        },
        .ref_count = 1,
        .dag_idx = result_idx,
        .cached_handle = null,
        .cached_bbox = null,
        .cached_topology = null,
    };

    return value.Value.initGeometry(ptr);
}
