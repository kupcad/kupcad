const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub fn meshUnion(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1) return error.RuntimeError;
    const other = args[0];

    if (receiver.isGeometry() and other.isGeometry()) {
        const new_idx = try vm.dag_builder.addBinary(.union_op, receiver.asGeometry().dag_idx, other.asGeometry().dag_idx);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection() and other.isCrossSection()) {
        const new_idx = try vm.dag_builder.addBinary(.cs_union_op, receiver.asCrossSection().dag_idx, other.asCrossSection().dag_idx);
        return try vm.allocateCrossSection(new_idx);
    }
    return error.RuntimeError;
}

pub fn meshDifference(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1) return error.RuntimeError;
    const other = args[0];

    if (receiver.isGeometry() and other.isGeometry()) {
        const new_idx = try vm.dag_builder.addBinary(.difference_op, receiver.asGeometry().dag_idx, other.asGeometry().dag_idx);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection() and other.isCrossSection()) {
        const new_idx = try vm.dag_builder.addBinary(.cs_difference_op, receiver.asCrossSection().dag_idx, other.asCrossSection().dag_idx);
        return try vm.allocateCrossSection(new_idx);
    }
    return error.RuntimeError;
}

pub fn meshIntersection(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1) return error.RuntimeError;
    const other = args[0];

    if (receiver.isGeometry() and other.isGeometry()) {
        const new_idx = try vm.dag_builder.addBinary(.intersection_op, receiver.asGeometry().dag_idx, other.asGeometry().dag_idx);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection() and other.isCrossSection()) {
        const new_idx = try vm.dag_builder.addBinary(.cs_intersection_op, receiver.asCrossSection().dag_idx, other.asCrossSection().dag_idx);
        return try vm.allocateCrossSection(new_idx);
    }
    return error.RuntimeError;
}
