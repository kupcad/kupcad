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

pub fn meshCenter(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    // Signature: center(axes: String = "xyz")
    var axes_str: []const u8 = "xyz";
    if (args.len > 0 and args[0].isString()) {
        axes_str = args[0].asString().chars;
    }

    const handle = try vm.ensureConcrete(receiver);
    const bbox = kernel.boundingBox(handle) orelse return error.RuntimeError;

    const cx = bbox.min[0] + (bbox.max[0] - bbox.min[0]) / 2.0;
    const cy = bbox.min[1] + (bbox.max[1] - bbox.min[1]) / 2.0;
    const cz = bbox.min[2] + (bbox.max[2] - bbox.min[2]) / 2.0;

    var tx: f64 = 0;
    var ty: f64 = 0;
    var tz: f64 = 0;

    for (axes_str) |c| {
        switch (c) {
            'x', 'X' => tx = -cx,
            'y', 'Y' => ty = -cy,
            'z', 'Z' => tz = -cz,
            else => {},
        }
    }

    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, tx, ty, tz);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, tx, ty };
        const new_idx = try vm.dag_builder.addCrossSectionTransform(receiver.asCrossSection().dag_idx, mat);
        return try vm.allocateCrossSection(new_idx);
    }

    return error.RuntimeError;
}

pub fn meshAlign(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    // Signature: align(target, axes, my_align, target_align = my_align, offset = 0.0)
    if (args.len < 3 or !args[1].isString() or !args[2].isString()) {
        vm.reportError("ArgumentError: align(target, axes, my_align, [target_align], [offset]) requires at least 3 args.\n", .{});
        return error.RuntimeError;
    }

    const target = args[0];
    const axis_str = args[1].asString().chars;
    const my_align_str = args[2].asString().chars;
    var target_align_str = my_align_str;
    var offset: f64 = 0.0;

    if (args.len > 3) {
        if (args[3].isString()) target_align_str = args[3].asString().chars;
        if (args[3].isNumber()) offset = args[3].asNumber(); // Allow skipping target_align
    }
    if (args.len > 4 and args[4].isNumber()) {
        offset = args[4].asNumber();
    }

    const my_handle = try vm.ensureConcrete(receiver);
    const target_handle = try vm.ensureConcrete(target);

    const my_bbox = kernel.boundingBox(my_handle) orelse return error.RuntimeError;
    const target_bbox = kernel.boundingBox(target_handle) orelse return error.RuntimeError;

    var tx: f64 = 0;
    var ty: f64 = 0;
    var tz: f64 = 0;

    for (axis_str) |c| {
        var axis_idx: usize = 0;
        switch (c) {
            'x', 'X' => axis_idx = 0,
            'y', 'Y' => axis_idx = 1,
            'z', 'Z' => axis_idx = 2,
            else => continue,
        }

        const my_min = my_bbox.min[axis_idx];
        const my_max = my_bbox.max[axis_idx];
        const my_center = my_min + (my_max - my_min) / 2.0;

        const target_min = target_bbox.min[axis_idx];
        const target_max = target_bbox.max[axis_idx];
        const target_center = target_min + (target_max - target_min) / 2.0;

        var my_pt: f64 = 0.0;
        if (std.mem.eql(u8, my_align_str, "min")) my_pt = my_min else if (std.mem.eql(u8, my_align_str, "max")) my_pt = my_max else if (std.mem.eql(u8, my_align_str, "center")) my_pt = my_center else {
            vm.reportError("ArgumentError: invalid alignment '{s}' (use 'min', 'max', or 'center')\n", .{my_align_str});
            return error.RuntimeError;
        }

        var target_pt: f64 = 0.0;
        if (std.mem.eql(u8, target_align_str, "min")) target_pt = target_min else if (std.mem.eql(u8, target_align_str, "max")) target_pt = target_max else if (std.mem.eql(u8, target_align_str, "center")) target_pt = target_center else {
            vm.reportError("ArgumentError: invalid alignment '{s}'\n", .{target_align_str});
            return error.RuntimeError;
        }

        const delta = target_pt - my_pt + offset;
        if (axis_idx == 0) tx = delta;
        if (axis_idx == 1) ty = delta;
        if (axis_idx == 2) tz = delta;
    }

    if (receiver.isGeometry()) {
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, tx, ty, tz);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    } else if (receiver.isCrossSection()) {
        const mat = [6]f64{ 1.0, 0.0, 0.0, 1.0, tx, ty };
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
            if (map.map.values()[idx].isBool()) auto = map.map.values()[idx].asBool();
        }
    }

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
