//! `union`, `difference` and `intersection` on solids and sketches: each adds one balanced
//! chain of boolean nodes to the DAG over the receiver and its operands (shapes or arrays of
//! them), checking that every operand is of the receiver's kind.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const dag = @import("../../vm/dag.zig");
const util = @import("util.zig");

inline fn gatherAndBalance(vm: *VM, receiver: value.Value, args: []const value.Value, comptime name: []const u8, op_3d: dag.DAGTag, op_2d: dag.DAGTag) !value.Value {
    var scratch = std.ArrayList(u32).empty;
    const alloc = vm.scratch_arena.allocator();

    const is_3d = receiver.isGeometry();
    const tag = if (is_3d) op_3d else op_2d;

    try scratch.append(alloc, if (is_3d) receiver.asGeometry().dag_idx else receiver.asCrossSection().dag_idx);
    try appendOperands(vm, alloc, &scratch, args, is_3d, name);

    // Nothing to combine with (`a.union([])`, a list of optional parts all left out): as
    // set theory has it, a union with or a difference by nothing is `a`, and an
    // intersection with nothing is empty (it used to be `a` too).
    if (scratch.items.len == 1) {
        if (tag != .intersection_op and tag != .cs_intersection_op) return receiver;
        const empty_idx = try vm.dag_builder.addEmpty(is_3d);
        return if (is_3d) try vm.allocateGeometry(.{ .symbolic = empty_idx }) else try vm.allocateCrossSection(empty_idx);
    }

    const new_idx = try vm.dag_builder.addBalancedChain(tag, scratch.items);

    if (is_3d) {
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else {
        return try vm.allocateCrossSection(new_idx);
    }
}

/// Appends the DAG nodes of `args`, each a shape of the receiver's kind (`is_3d`) or an
/// Array of them. Anything else is a TypeError saying where it is: they used to be skipped,
/// so `a.union(nil)` or a Sketch in a Solid's union gave `a` back unchanged.
pub fn appendOperands(vm: *VM, alloc: std.mem.Allocator, list: *std.ArrayList(u32), args: []const value.Value, is_3d: bool, method: []const u8) !void {
    for (args, 1..) |arg, argument| {
        if (arg.isArray()) {
            for (arg.asArray().items.items, 0..) |item, index| try appendOperand(vm, alloc, list, item, is_3d, method, argument, index);
        } else try appendOperand(vm, alloc, list, arg, is_3d, method, argument, null);
    }
}

fn appendOperand(vm: *VM, alloc: std.mem.Allocator, list: *std.ArrayList(u32), val: value.Value, is_3d: bool, method: []const u8, argument: usize, index: ?usize) !void {
    if (is_3d and val.isGeometry()) return list.append(alloc, val.asGeometry().dag_idx);
    if (!is_3d and val.isCrossSection()) return list.append(alloc, val.asCrossSection().dag_idx);
    const expected = if (is_3d) "a Solid" else "a Sketch";
    if (index) |i| {
        // An optional part left out is a nil in the list.
        const hint = if (val.isNil()) "; leave out the nils with .compact" else "";
        _ = vm.raiseError(.TypeError, "{s} expects {s} at index {d} of argument {d}, got {s}{s}", .{ method, expected, i, argument, util.typeName(vm, val), hint });
    } else {
        _ = vm.raiseError(.TypeError, "{s} expects {s} or an Array of them for argument {d}, got {s}", .{ method, expected, argument, util.typeName(vm, val) });
    }
    return error.RuntimeError;
}

pub fn meshUnion(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    return gatherAndBalance(vm, receiver, args, "union", .union_op, .cs_union_op);
}

pub fn meshDifference(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    return gatherAndBalance(vm, receiver, args, "difference", .difference_op, .cs_difference_op);
}

pub fn meshIntersection(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    return gatherAndBalance(vm, receiver, args, "intersection", .intersection_op, .cs_intersection_op);
}
