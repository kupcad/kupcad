const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");

pub fn meshBBox(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    const handle = try vm.ensureConcrete(receiver);
    const geom_obj = receiver.asGeometry();

    if (geom_obj.cached_bbox == null) {
        if (kernel.boundingBox(handle)) |k_box| {
            geom_obj.cached_bbox = value.BBox{
                .min_x = k_box.min[0],
                .min_y = k_box.min[1],
                .min_z = k_box.min[2],
                .max_x = k_box.max[0],
                .max_y = k_box.max[1],
                .max_z = k_box.max[2],
            };
        }
    }

    const box = geom_obj.cached_bbox orelse return value.Value.initNil();

    // Allocate native struct instead of heavy hash-map dictionary instance
    const bbox_inst = try vm.gc.allocateBBox(vm, box.min_x, box.min_y, box.min_z, box.max_x, box.max_y, box.max_z);
    return value.Value.initObj(&bbox_inst.obj);
}

pub fn meshVolume(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    const handle = try vm.ensureConcrete(receiver);
    return value.Value.initNumber(kernel.volume(handle));
}

pub fn meshSurfaceArea(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    const handle = try vm.ensureConcrete(receiver);
    return value.Value.initNumber(kernel.surfaceArea(handle));
}

pub fn meshMinGap(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    if (args.len < 1 or !args[0].isGeometry()) return error.RuntimeError;
    if (args.len > 1 and !args[1].isNumber()) return error.RuntimeError;
    const search_length = if (args.len > 1) args[1].asNumber() else 100.0;
    const handle = try vm.ensureConcrete(receiver);
    const other_handle = try vm.ensureConcrete(args[0]);
    return value.Value.initNumber(kernel.minGap(handle, other_handle, search_length));
}

pub fn meshContains(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    if (args.len < 1 or !args[0].isArray()) return error.RuntimeError;
    const pt_arr = args[0].asArray().items.items;
    if (pt_arr.len < 3) return error.RuntimeError;
    if (!pt_arr[0].isNumber() or !pt_arr[1].isNumber() or !pt_arr[2].isNumber()) return error.RuntimeError;

    const handle = try vm.ensureConcrete(receiver);
    const inside = kernel.containsPoint(handle, .{ pt_arr[0].asNumber(), pt_arr[1].asNumber(), pt_arr[2].asNumber() });
    return value.Value.initBool(inside);
}

pub fn meshRayCast(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    if (args.len < 2 or !args[0].isArray() or !args[1].isArray()) return error.RuntimeError;
    const o_arr = args[0].asArray().items.items;
    const e_arr = args[1].asArray().items.items;
    if (o_arr.len < 3 or e_arr.len < 3) return error.RuntimeError;
    if (!o_arr[0].isNumber() or !o_arr[1].isNumber() or !o_arr[2].isNumber()) return error.RuntimeError;
    if (!e_arr[0].isNumber() or !e_arr[1].isNumber() or !e_arr[2].isNumber()) return error.RuntimeError;

    const handle = try vm.ensureConcrete(receiver);
    const hits = kernel.rayCast(vm.scratch_arena.allocator(), handle, .{ o_arr[0].asNumber(), o_arr[1].asNumber(), o_arr[2].asNumber() }, .{ e_arr[0].asNumber(), e_arr[1].asNumber(), e_arr[2].asNumber() }) orelse return value.Value.initNil();
    // No need to free `hits`, scratch arena cleans it up!

    const hit_arr_obj = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&hit_arr_obj.obj));
    defer _ = vm.pop();

    for (hits) |hit| {
        const map_obj = try vm.gc.allocateMap(vm);
        vm.push(value.Value.initObj(&map_obj.obj));
        defer _ = vm.pop();

        const d_str = try vm.allocateString("distance");
        vm.push(d_str);
        try map_obj.map.put(vm.allocator, d_str, value.Value.initNumber(hit.distance));
        _ = vm.pop();

        const pos_str = try vm.allocateString("position");
        vm.push(pos_str);
        const pos_arr = try vm.gc.allocateArray(vm);
        vm.push(value.Value.initObj(&pos_arr.obj));
        try pos_arr.items.append(vm.allocator, value.Value.initNumber(hit.position[0]));
        try pos_arr.items.append(vm.allocator, value.Value.initNumber(hit.position[1]));
        try pos_arr.items.append(vm.allocator, value.Value.initNumber(hit.position[2]));
        try map_obj.map.put(vm.allocator, pos_str, value.Value.initObj(&pos_arr.obj));
        _ = vm.pop();
        _ = vm.pop();

        try hit_arr_obj.items.append(vm.allocator, value.Value.initObj(&map_obj.obj));
    }
    return value.Value.initObj(&hit_arr_obj.obj);
}
