const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const util = @import("util.zig");

pub fn meshTranslate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(args, 0.0);
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, vec[0], vec[1] };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return error.RuntimeError;
}

pub fn meshRotate(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(args, 0.0);
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addRotate(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const rad = vec[0] * std.math.pi / 180.0;
        const cos_a = std.math.cos(rad);
        const sin_a = std.math.sin(rad);
        const mat = [6]f64{ cos_a, sin_a, -sin_a, cos_a, 0.0, 0.0 };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return error.RuntimeError;
}

pub fn meshScale(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(args, 1.0);
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addScale(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = [6]f64{ vec[0], 0.0, 0.0, vec[1], 0.0, 0.0 };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return error.RuntimeError;
}

pub fn meshMirror(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    const vec = try util.parseVec3(args, 0.0);
    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addMirror(receiver.asGeometry().dag_idx, vec[0], vec[1], vec[2]);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    }
    return error.RuntimeError;
}

pub fn meshTransform(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1 or !args[0].isArray()) return error.RuntimeError;
    const arr = args[0].asArray().items.items;

    if (receiver.isGeometry()) {
        if (arr.len < 12) return error.RuntimeError;
        var mat: [12]f64 = undefined;
        for (0..12) |i| mat[i] = if (arr[i].isNumber()) arr[i].asNumber() else 0.0;
        const new_idx = try vm.dag_builder.addTransformMatrix(receiver.asGeometry().dag_idx, mat);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        if (arr.len < 6) return error.RuntimeError;
        var mat: [6]f64 = undefined;
        for (0..6) |i| mat[i] = if (arr[i].isNumber()) arr[i].asNumber() else 0.0;
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }
    return error.RuntimeError;
}

pub fn meshResize(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;

    var target_x: f64 = 0.0;
    var target_y: f64 = 0.0;
    var target_z: f64 = 0.0;
    var auto: bool = false;

    if (args.len > 0 and args[0].isArray()) {
        const arr = args[0].asArray().items.items;
        if (arr.len > 0 and arr[0].isNumber()) target_x = arr[0].asNumber();
        if (arr.len > 1 and arr[1].isNumber()) target_y = arr[1].asNumber();
        if (arr.len > 2 and arr[2].isNumber()) target_z = arr[2].asNumber();
    } else {
        vm.reportError("ArgumentError: resize() requires an array of target dimensions [x, y, z].\n", .{});
        return error.RuntimeError;
    }

    if (args.len > 1 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        if (vm.findMapKeyByString(map, "auto")) |idx| {
            if (map.values.items[idx].isBool()) auto = map.values.items[idx].asBool();
        }
    }

    // Force Manifold evaluation to get the exact Bounding Box
    const handle = try vm.ensureConcrete(receiver);
    const bbox = kernel.boundingBox(handle) orelse return error.RuntimeError;

    const cur_x = bbox.max[0] - bbox.min[0];
    const cur_y = bbox.max[1] - bbox.min[1];
    const cur_z = bbox.max[2] - bbox.min[2];

    // Calculate required scale multipliers
    var sx: f64 = if (cur_x > 0.0 and target_x > 0.0) target_x / cur_x else 1.0;
    var sy: f64 = if (cur_y > 0.0 and target_y > 0.0) target_y / cur_y else 1.0;
    var sz: f64 = if (cur_z > 0.0 and target_z > 0.0) target_z / cur_z else 1.0;

    // Apply auto-scaling for axes specified as 0.0
    if (auto) {
        var auto_scale: f64 = 1.0;
        if (target_x > 0.0) {
            auto_scale = sx;
        } else if (target_y > 0.0) {
            auto_scale = sy;
        } else if (target_z > 0.0) {
            auto_scale = sz;
        }

        if (target_x <= 0.0) sx = auto_scale;
        if (target_y <= 0.0) sy = auto_scale;
        if (target_z <= 0.0) sz = auto_scale;
    }

    const new_idx = try vm.dag_builder.addScale(receiver.asGeometry().dag_idx, sx, sy, sz);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}
