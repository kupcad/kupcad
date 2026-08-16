const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const geom = @import("../kernel/geometry_handle.zig");

pub fn meshRotate(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const x = if (arg_count > 0) args[0].asNumber() else 0.0;
    const y = if (arg_count > 1) args[1].asNumber() else 0.0;
    const z = if (arg_count > 2) args[2].asNumber() else 0.0;
    const new_idx = try vm.dag_builder.addRotate(receiver.asGeometry().dag_idx, x, y, z);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshScale(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const x = if (arg_count > 0) args[0].asNumber() else 1.0;
    // Smart default: If user only provides X, scale uniformly (x, x, x)
    const y = if (arg_count > 1) args[1].asNumber() else x;
    const z = if (arg_count > 2) args[2].asNumber() else x;

    const new_idx = try vm.dag_builder.addScale(receiver.asGeometry().dag_idx, x, y, z);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshTranslate(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const x = if (arg_count > 0) args[0].asNumber() else 0.0;
    const y = if (arg_count > 1) args[1].asNumber() else 0.0;
    const z = if (arg_count > 2) args[2].asNumber() else 0.0;
    const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, x, y, z);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshOnFace(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    // Force JIT Materialization
    const handle = try vm.ensureConcrete(receiver);
    const geom_obj = receiver.asGeometry();

    // Extract direction symbol (e.g., :top)
    if (arg_count < 1 or !args[0].isString()) return error.RuntimeError;
    const direction_sym = args[0].asString();

    // Lazy Topology Initialization
    if (geom_obj.cached_topology == null) {
        geom_obj.cached_topology = try vm.allocator.create(value.TopologyCache);
        geom_obj.cached_topology.?.* = .{ .is_populated = true };
    }

    var filter = geom.FaceFilter.top;
    if (std.mem.eql(u8, direction_sym, "bottom")) filter = .bottom;

    // Query Kernel (Mocked for now)
    _ = vm.active_kernel.?.queryFaces(handle, filter);

    // Spawn Workplane tied to parent geometry!
    return try vm.allocateWorkplane(geom_obj, [3]f64{ 0, 0, 0 }, [3]f64{ 0, 0, 1 });
}

pub fn meshBBox(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;

    // Force JIT Materialization!
    const handle = try vm.ensureConcrete(receiver);
    const geom_obj = receiver.asGeometry();

    // Cache the bounding box so we don't recalculate it continuously
    if (geom_obj.cached_bbox == null) {
        if (vm.active_kernel.?.boundingBox(handle)) |k_box| {
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

    // Allocate the resulting dictionary map
    const map_obj = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&map_obj.obj)); // protect from GC
    defer _ = vm.pop();

    // Helper to build coordinates into a KupCAD Array
    const build_arr = struct {
        fn build(v: *VM, coords: [3]f64) !value.Value {
            const a = try v.gc.allocateArray(v);
            v.push(value.Value.initObj(&a.obj));
            defer _ = v.pop();
            try a.items.append(v.allocator, value.Value.initNumber(coords[0]));
            try a.items.append(v.allocator, value.Value.initNumber(coords[1]));
            try a.items.append(v.allocator, value.Value.initNumber(coords[2]));
            return value.Value.initObj(&a.obj);
        }
    }.build;

    const min_str = try vm.allocateString("min");
    vm.push(min_str);
    defer _ = vm.pop();
    const max_str = try vm.allocateString("max");
    vm.push(max_str);
    defer _ = vm.pop();

    const min_arr = try build_arr(vm, [3]f64{ box.min_x, box.min_y, box.min_z });
    const max_arr = try build_arr(vm, [3]f64{ box.max_x, box.max_y, box.max_z });

    vm.retainValue(min_str);
    vm.retainValue(min_arr);
    try map_obj.keys.append(vm.allocator, min_str);
    try map_obj.values.append(vm.allocator, min_arr);

    vm.retainValue(max_str);
    vm.retainValue(max_arr);
    try map_obj.keys.append(vm.allocator, max_str);
    try map_obj.values.append(vm.allocator, max_arr);

    return value.Value.initObj(&map_obj.obj);
}

pub fn meshVolume(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const handle = try vm.ensureConcrete(receiver);
    const vol = vm.active_kernel.?.volume(handle);
    return value.Value.initNumber(vol);
}

pub fn meshSurfaceArea(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    _ = arg_count;
    _ = args;
    const handle = try vm.ensureConcrete(receiver);
    const area = vm.active_kernel.?.surfaceArea(handle);
    return value.Value.initNumber(area);
}

pub fn meshExtrude(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    const height = if (arg_count > 0) args[0].asNumber() else 1.0;
    // For now, default twist and scale. You can expand kwargs here later!
    const new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, height, 0, 0.0, 1.0, 1.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshRevolve(vm: *VM, receiver: value.Value, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
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
    const delta = if (arg_count > 0) args[0].asNumber() else 1.0;
    const new_idx = try vm.dag_builder.addOffset(receiver.asCrossSection().dag_idx, delta, 1); // 1 = round
    return try vm.allocateCrossSection(new_idx);
}
