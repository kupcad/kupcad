const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const util = @import("util.zig");
const error_kind = @import("../../vm/error_kind.zig");

/// How far min_gap looks for the closest approach when no search length is given.
const DEFAULT_MIN_GAP_SEARCH_LENGTH: f64 = 100.0;

pub fn meshBBox(vm: *VM, receiver: value.Value) !value.Value {
    if (receiver.isGeometry()) {
        const handle = try vm.ensureConcrete(receiver);
        try vm.requireFeature(handle.engine, .bounding_box);
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
        const bbox_inst = try vm.gc.allocateBBox(vm, box.min_x, box.min_y, box.min_z, box.max_x, box.max_y, box.max_z);
        return value.Value.initObj(&bbox_inst.obj);
    } else if (receiver.isCrossSection()) {
        const handle = try vm.ensureConcreteCrossSection(receiver);
        try vm.requireFeature(handle.engine, .sketch_measure);
        const rect = kernel.crossSectionBounds(handle);

        const bbox_inst = try vm.gc.allocateBBox(
            vm,
            rect.min[0],
            rect.min[1],
            0.0,
            rect.max[0],
            rect.max[1],
            0.0,
        );
        return value.Value.initObj(&bbox_inst.obj);
    }

    return util.notDefinedFor(vm, "bbox", receiver);
}

pub fn meshVolume(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "volume", receiver);
    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .volume);
    return value.Value.initNumber(kernel.volume(handle));
}

pub fn meshSurfaceArea(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "surface_area", receiver);
    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .surface_area);
    return value.Value.initNumber(kernel.surfaceArea(handle));
}

pub fn meshMinGap(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "min_gap", receiver);
    if (args.len < 1 or !args[0].isGeometry()) {
        _ = vm.raiseError(.TypeError, "min_gap expects a Geometry to measure against, got {s}", .{if (args.len < 1) "nothing" else util.typeName(vm, args[0])});
        return error.RuntimeError;
    }
    const search_length = if (args.len > 1) try util.requireNumber(vm, args[1], "min_gap", "search_length") else DEFAULT_MIN_GAP_SEARCH_LENGTH;
    try util.requirePositive(vm, search_length, "min_gap", "search_length");
    const handle = try vm.ensureConcrete(receiver);
    const other_handle = try vm.ensureConcrete(args[0]);
    try vm.requireFeature(handle.engine, .min_gap);
    return value.Value.initNumber(kernel.minGap(handle, other_handle, search_length));
}

pub fn meshContains(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (receiver.isCrossSection()) return sketchContains(vm, receiver, args);
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "contains?", receiver);
    if (args.len < 1) {
        _ = vm.raiseError(.ArgumentError, "contains? expects a point [x, y, z]", .{});
        return error.RuntimeError;
    }
    const pt = try util.parseNumberArray(3, vm, args[0], .{ .method = "contains?", .name = "the point" }, 3, 0.0);

    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .contains_point);
    const inside = kernel.containsPoint(handle, pt);
    return value.Value.initBool(inside);
}

/// Sketch#contains?([x, y]) / ([x, y, z]): whether the point lies in the sketch's region.
/// The region is closed (points on the outline count, within the engine tolerance) and
/// holes are excluded. A sketch lives in the z = 0 plane, so a 3D point off that plane is
/// never contained; accepting [x, y, z] lets generic code pass 3D points.
fn sketchContains(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (args.len < 1) {
        _ = vm.raiseError(.ArgumentError, "contains? on a sketch expects a point [x, y]", .{});
        return error.RuntimeError;
    }
    const pt = try util.parseNumberArray(3, vm, args[0], .{ .method = "contains?", .name = "the point" }, 2, 0.0);
    const tolerance = vm.config().tolerance;
    if (@abs(pt[2]) > tolerance) return value.Value.initBool(false);

    const handle = try vm.ensureConcreteCrossSection(receiver);
    try vm.requireFeature(handle.engine, .contains_point);
    const inside = kernel.crossSectionContainsPoint(handle, .{ pt[0], pt[1] }, tolerance) orelse {
        _ = vm.raiseError(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"contains?"});
        return error.RuntimeError;
    };
    return value.Value.initBool(inside);
}

pub fn meshRayCast(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "ray_cast", receiver);
    if (args.len < 2) {
        _ = vm.raiseError(.ArgumentError, "ray_cast expects an origin [x, y, z] and an end point [x, y, z]", .{});
        return error.RuntimeError;
    }
    const origin = try util.parseNumberArray(3, vm, args[0], .{ .method = "ray_cast", .name = "the origin" }, 3, 0.0);
    const end = try util.parseNumberArray(3, vm, args[1], .{ .method = "ray_cast", .name = "the end point" }, 3, 0.0);
    // A zero-length ray has no direction.
    try util.requireNonZeroVector(vm, .{ end[0] - origin[0], end[1] - origin[1], end[2] - origin[2] }, "ray_cast", "ray (end - origin)");

    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .ray_cast);
    const hits = kernel.rayCast(vm.scratch_arena.allocator(), handle, origin, end) orelse return value.Value.initNil();
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
        try map_obj.map.put(vm.gc.trackingAllocator(), d_str, value.Value.initNumber(hit.distance));
        _ = vm.pop();

        const pos_str = try vm.allocateString("position");
        vm.push(pos_str);
        const pos_arr = try vm.gc.allocateArray(vm);
        vm.push(value.Value.initObj(&pos_arr.obj));
        try pos_arr.items.append(vm.gc.trackingAllocator(), value.Value.initNumber(hit.position[0]));
        try pos_arr.items.append(vm.gc.trackingAllocator(), value.Value.initNumber(hit.position[1]));
        try pos_arr.items.append(vm.gc.trackingAllocator(), value.Value.initNumber(hit.position[2]));
        try map_obj.map.put(vm.gc.trackingAllocator(), pos_str, value.Value.initObj(&pos_arr.obj));
        _ = vm.pop();
        _ = vm.pop();

        try hit_arr_obj.items.append(vm.gc.trackingAllocator(), value.Value.initObj(&map_obj.obj));
    }
    return value.Value.initObj(&hit_arr_obj.obj);
}

pub fn meshGenus(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "genus", receiver);
    const handle = try vm.ensureConcrete(receiver);
    try vm.requireFeature(handle.engine, .genus);
    return value.Value.initNumber(@floatFromInt(kernel.genus(handle)));
}
