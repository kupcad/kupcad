const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

// --- Utilizing Strongly Typed Receivers ---

pub fn meshHull(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    var current_idx = receiver.dag_idx;

    // Union all passed target shapes before computing the convex hull
    for (args) |arg| {
        if (arg.isGeometry()) {
            current_idx = try vm.dag_builder.addBinary(.union_op, current_idx, arg.asGeometry().dag_idx);
        }
    }

    const hull_idx = try vm.dag_builder.addHull(current_idx);
    return try vm.allocateGeometry(.{ .symbolic = hull_idx });
}

pub fn meshMinkowski(vm: *VM, receiver: *value.ObjGeometry, other: *value.ObjGeometry) !value.Value {
    const new_idx = try vm.dag_builder.addBinary(.minkowski, receiver.dag_idx, other.dag_idx);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshTrimByPlane(vm: *VM, receiver: *value.ObjGeometry, nx: f64, ny: f64, nz: f64, offset: ?f64) !value.Value {
    const new_idx = try vm.dag_builder.addTrimByPlane(receiver.dag_idx, nx, ny, nz, offset orelse 0.0);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshOffset(vm: *VM, receiver: *value.ObjCrossSection, args: []const value.Value) !value.Value {
    var delta: f64 = 1.0;
    var join_type: u8 = 1; // Default to round (1)

    var pos_count = args.len;
    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        pos_count -= 1;

        var it = map.map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                const k_str = if (k.asObj().obj_type == .string)
                    @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                else
                    @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                const v = entry.value_ptr.*;
                if (std.mem.eql(u8, k_str, "delta") and v.isNumber()) delta = v.asNumber();
                if (std.mem.eql(u8, k_str, "join") and v.isSymbol()) {
                    const sym = v.asSymbol().chars;
                    if (std.mem.eql(u8, sym, "square")) join_type = 0;
                    if (std.mem.eql(u8, sym, "miter")) join_type = 2;
                    if (std.mem.eql(u8, sym, "bevel")) join_type = 3;
                }
            }
        }
    }

    if (pos_count > 0) {
        if (!args[0].isNumber()) return error.RuntimeError;
        delta = args[0].asNumber();
    }

    const new_idx = try vm.dag_builder.addOffset(receiver.dag_idx, delta, join_type);
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshSlice(vm: *VM, receiver: *value.ObjGeometry, height: ?f64) !value.Value {
    const new_idx = try vm.dag_builder.addSlice(receiver.dag_idx, height orelse 0.0);
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshProject(vm: *VM, receiver: *value.ObjGeometry, args: []const value.Value) !value.Value {
    var cut = false;

    // Parse `cut: true` from kwargs
    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        if (map.map.get(try vm.allocateSymbol("cut"))) |val| {
            if (val.isBool()) cut = val.asBool();
        } else if (map.map.get(try vm.allocateString("cut"))) |val| {
            if (val.isBool()) cut = val.asBool();
        }
    }

    if (cut) {
        // project(cut: true) is a 2D slice exactly at Z=0
        const new_idx = try vm.dag_builder.addSlice(receiver.dag_idx, 0.0);
        return try vm.allocateCrossSection(new_idx);
    } else {
        // Standard 2D shadow projection of the entire 3D volume
        const new_idx = try vm.dag_builder.addProject(receiver.dag_idx);
        return try vm.allocateCrossSection(new_idx);
    }
}

pub fn meshOnFace(vm: *VM, receiver: *value.ObjGeometry, dir_arg: value.Value) !value.Value {
    // Note: ensureConcrete handles evaluating the DAG, so we pass it a Value wrapper
    const handle = try vm.ensureConcrete(value.Value.initGeometry(receiver));

    const dir_str = if (dir_arg.isObject() and dir_arg.asObj().obj_type == .symbol)
        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", dir_arg.asObj()))).chars
    else if (dir_arg.isObject() and dir_arg.asObj().obj_type == .string)
        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", dir_arg.asObj()))).chars
    else
        return error.RuntimeError;

    if (receiver.cached_topology == null) {
        receiver.cached_topology = try vm.allocator.create(value.TopologyCache);
        receiver.cached_topology.?.* = .{ .is_populated = true };
    }

    var filter = geom.FaceFilter.top;
    if (std.mem.eql(u8, dir_str, "bottom")) filter = .bottom;

    _ = kernel.queryFaces(handle, filter);

    return try vm.allocateWorkplane(receiver, [3]f64{ 0, 0, 0 }, [3]f64{ 0, 0, 1 });
}
