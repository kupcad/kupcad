const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const dag = @import("../../vm/dag.zig");

inline fn gatherAndBalance(vm: *VM, receiver: value.Value, args: []const value.Value, op_3d: dag.DAGTag, op_2d: dag.DAGTag) !value.Value {
    var scratch = std.ArrayListUnmanaged(u32).empty;
    const alloc = vm.scratch_arena.allocator();

    const is_3d = receiver.isGeometry();
    const tag = if (is_3d) op_3d else op_2d;

    try scratch.append(alloc, if (is_3d) receiver.asGeometry().dag_idx else receiver.asCrossSection().dag_idx);

    // Recursively flatten direct arguments and arrays into the chain
    for (args) |arg| {
        if (is_3d and arg.isGeometry()) {
            try scratch.append(alloc, arg.asGeometry().dag_idx);
        } else if (!is_3d and arg.isCrossSection()) {
            try scratch.append(alloc, arg.asCrossSection().dag_idx);
        } else if (arg.isArray()) {
            for (arg.asArray().items.items) |item| {
                if (is_3d and item.isGeometry()) {
                    try scratch.append(alloc, item.asGeometry().dag_idx);
                } else if (!is_3d and item.isCrossSection()) {
                    try scratch.append(alloc, item.asCrossSection().dag_idx);
                }
            }
        }
    }

    // Short-circuit if no valid arguments were provided
    if (scratch.items.len == 1) return receiver;

    const new_idx = try vm.dag_builder.addBalancedChain(tag, scratch.items);

    if (is_3d) {
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else {
        return try vm.allocateCrossSection(new_idx);
    }
}

pub fn meshUnion(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    return gatherAndBalance(vm, receiver, args, .union_op, .cs_union_op);
}

pub fn meshDifference(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    return gatherAndBalance(vm, receiver, args, .difference_op, .cs_difference_op);
}

pub fn meshIntersection(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    return gatherAndBalance(vm, receiver, args, .intersection_op, .cs_intersection_op);
}
