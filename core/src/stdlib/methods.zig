const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");

fn parseVec3(arg_count: u8, args: [*]value.Value, default_val: f64) !struct { f64, f64, f64 } {
    if (arg_count > 0 and !args[0].isNumber()) return error.RuntimeError;
    if (arg_count > 1 and !args[1].isNumber()) return error.RuntimeError;
    if (arg_count > 2 and !args[2].isNumber()) return error.RuntimeError;

    const x = if (arg_count > 0) args[0].asNumber() else default_val;
    const y = if (arg_count > 1) args[1].asNumber() else default_val;
    const z = if (arg_count > 2) args[2].asNumber() else default_val;

    return .{ x, y, z };
}

pub fn meshRotate(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vec = try parseVec3(arg_count, args, 0.0);

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

pub fn meshScale(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vec = try parseVec3(arg_count, args, 1.0);

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

pub fn meshTranslate(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vec = try parseVec3(arg_count, args, 0.0);

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

pub fn meshOnFace(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    // Force JIT Materialization
    const handle = try vm.ensureConcrete(receiver);
    const geom_obj = receiver.asGeometry();

    // Check type explicitly before relying on asString representation
    if (arg_count < 1 or (!args[0].isString() and !(args[0].isObject() and args[0].asObj().obj_type == .symbol))) return error.RuntimeError;

    // Extract direction symbol
    const direction_sym = if (args[0].isObject() and args[0].asObj().obj_type == .string)
        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars
    else
        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", args[0].asObj()))).chars;

    // Lazy Topology Initialization
    if (geom_obj.cached_topology == null) {
        geom_obj.cached_topology = try vm.allocator.create(value.TopologyCache);
        geom_obj.cached_topology.?.* = .{ .is_populated = true };
    }
    var filter = geom.FaceFilter.top;
    if (std.mem.eql(u8, direction_sym, "bottom")) filter = .bottom;

    // Query Kernel (Mocked for now)
    _ = kernel.queryFaces(handle, filter);
    // Spawn Workplane tied to parent geometry
    return try vm.allocateWorkplane(geom_obj, [3]f64{ 0, 0, 0 }, [3]f64{ 0, 0, 1 });
}

pub fn meshBBox(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;

    // Force JIT Materialization
    const handle = try vm.ensureConcrete(receiver);
    const geom_obj = receiver.asGeometry();

    // Cache the bounding box so we don't recalculate it continuously
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

    // Allocate a BoundingBox class instance instead of a Map
    const bbox_inst = try vm.gc.allocateInstance(vm, vm.bbox_class.?);
    vm.push(value.Value.initObj(&bbox_inst.obj)); // protect from GC
    defer _ = vm.pop();

    // Pre-calculate highly useful dimensional properties
    const size_x = box.max_x - box.min_x;
    const size_y = box.max_y - box.min_y;
    const size_z = box.max_z - box.min_z;

    const center_x = box.min_x + (size_x / 2.0);
    const center_y = box.min_y + (size_y / 2.0);
    const center_z = box.min_z + (size_z / 2.0);

    // Attach Scalar Properties (e.g. `bbox.size_x`, `bbox.center_y`)
    try vm.setInstanceField(bbox_inst, "size_x", value.Value.initNumber(size_x));
    try vm.setInstanceField(bbox_inst, "size_y", value.Value.initNumber(size_y));
    try vm.setInstanceField(bbox_inst, "size_z", value.Value.initNumber(size_z));

    try vm.setInstanceField(bbox_inst, "center_x", value.Value.initNumber(center_x));
    try vm.setInstanceField(bbox_inst, "center_y", value.Value.initNumber(center_y));
    try vm.setInstanceField(bbox_inst, "center_z", value.Value.initNumber(center_z));

    try vm.setInstanceField(bbox_inst, "min_x", value.Value.initNumber(box.min_x));
    try vm.setInstanceField(bbox_inst, "min_y", value.Value.initNumber(box.min_y));
    try vm.setInstanceField(bbox_inst, "min_z", value.Value.initNumber(box.min_z));

    try vm.setInstanceField(bbox_inst, "max_x", value.Value.initNumber(box.max_x));
    try vm.setInstanceField(bbox_inst, "max_y", value.Value.initNumber(box.max_y));
    try vm.setInstanceField(bbox_inst, "max_z", value.Value.initNumber(box.max_z));

    return value.Value.initObj(&bbox_inst.obj);
}

pub fn meshVolume(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const handle = try vm.ensureConcrete(receiver);
    const vol = kernel.volume(handle);
    return value.Value.initNumber(vol);
}

pub fn meshSurfaceArea(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const handle = try vm.ensureConcrete(receiver);
    const area = kernel.surfaceArea(handle);
    return value.Value.initNumber(area);
}

pub fn meshExtrude(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    if (arg_count > 0 and !args[0].isNumber()) return error.RuntimeError;

    const height = if (arg_count > 0) args[0].asNumber() else 1.0;
    const new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, height, 0, 0.0, 1.0, 1.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshRevolve(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    if (arg_count > 0 and !args[0].isNumber()) return error.RuntimeError;

    const degrees = if (arg_count > 0) args[0].asNumber() else 360.0;
    const new_idx = try vm.dag_builder.addRevolve(receiver.asCrossSection().dag_idx, 0, degrees);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshHull(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const new_idx = try vm.dag_builder.addHull(receiver.asGeometry().dag_idx);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshTrimByPlane(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count < 3) return error.RuntimeError;
    if (!args[0].isNumber() or !args[1].isNumber() or !args[2].isNumber()) return error.RuntimeError;
    if (arg_count > 3 and !args[3].isNumber()) return error.RuntimeError;

    const nx = args[0].asNumber();
    const ny = args[1].asNumber();
    const nz = args[2].asNumber();
    const offset = if (arg_count > 3) args[3].asNumber() else 0.0;
    const new_idx = try vm.dag_builder.addTrimByPlane(receiver.asGeometry().dag_idx, nx, ny, nz, offset);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshMinkowski(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count < 1 or !args[0].isGeometry()) return error.RuntimeError;
    const new_idx = try vm.dag_builder.addBinary(.minkowski, receiver.asGeometry().dag_idx, args[0].asGeometry().dag_idx);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshOffset(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    if (arg_count > 0 and !args[0].isNumber()) return error.RuntimeError;

    const delta = if (arg_count > 0) args[0].asNumber() else 1.0;
    const new_idx = try vm.dag_builder.addOffset(receiver.asCrossSection().dag_idx, delta, 1); // 1 = round
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshTransform(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count < 1 or !args[0].isArray()) return error.RuntimeError;
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

pub fn meshMinGap(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count < 1 or !args[0].isGeometry()) return error.RuntimeError;
    if (arg_count > 1 and !args[1].isNumber()) return error.RuntimeError;

    const search_length = if (arg_count > 1) args[1].asNumber() else 100.0;
    const a_handle = try vm.ensureConcrete(receiver);
    const b_handle = try vm.ensureConcrete(args[0]);
    const gap = kernel.minGap(a_handle, b_handle, search_length);
    return value.Value.initNumber(gap);
}

pub fn meshContains(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count < 1 or !args[0].isArray()) return error.RuntimeError;
    const pt_arr = args[0].asArray().items.items;
    if (pt_arr.len < 3) return error.RuntimeError;
    if (!pt_arr[0].isNumber() or !pt_arr[1].isNumber() or !pt_arr[2].isNumber()) return error.RuntimeError;

    const handle = try vm.ensureConcrete(receiver);
    const inside = kernel.containsPoint(handle, .{ pt_arr[0].asNumber(), pt_arr[1].asNumber(), pt_arr[2].asNumber() });
    return value.Value.initBool(inside);
}

pub fn meshRayCast(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count < 2 or !args[0].isArray() or !args[1].isArray()) return error.RuntimeError;
    const o_arr = args[0].asArray().items.items;
    const e_arr = args[1].asArray().items.items;

    if (o_arr.len < 3 or e_arr.len < 3) return error.RuntimeError;
    if (!o_arr[0].isNumber() or !o_arr[1].isNumber() or !o_arr[2].isNumber()) return error.RuntimeError;
    if (!e_arr[0].isNumber() or !e_arr[1].isNumber() or !e_arr[2].isNumber()) return error.RuntimeError;

    const handle = try vm.ensureConcrete(receiver);
    const hits = kernel.rayCast(vm.allocator, handle, .{ o_arr[0].asNumber(), o_arr[1].asNumber(), o_arr[2].asNumber() }, .{ e_arr[0].asNumber(), e_arr[1].asNumber(), e_arr[2].asNumber() }) orelse return value.Value.initNil();
    defer vm.allocator.free(hits);

    const hit_arr_obj = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&hit_arr_obj.obj)); // GC protect
    defer _ = vm.pop();

    for (hits) |hit| {
        const map_obj = try vm.gc.allocateMap(vm);
        vm.push(value.Value.initObj(&map_obj.obj));
        defer _ = vm.pop();

        // Put Distance
        const d_str = try vm.allocateString("distance");
        try map_obj.keys.append(vm.allocator, d_str);
        try map_obj.values.append(vm.allocator, value.Value.initNumber(hit.distance));

        // Put Position
        const pos_str = try vm.allocateString("position");
        const pos_arr = try vm.gc.allocateArray(vm);
        try pos_arr.items.append(vm.allocator, value.Value.initNumber(hit.position[0]));
        try pos_arr.items.append(vm.allocator, value.Value.initNumber(hit.position[1]));
        try pos_arr.items.append(vm.allocator, value.Value.initNumber(hit.position[2]));

        try map_obj.keys.append(vm.allocator, pos_str);
        try map_obj.values.append(vm.allocator, value.Value.initObj(&pos_arr.obj));

        try hit_arr_obj.items.append(vm.allocator, value.Value.initObj(&map_obj.obj));
    }
    return value.Value.initObj(&hit_arr_obj.obj);
}
