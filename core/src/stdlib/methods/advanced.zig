const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

pub fn meshHull(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    var current_idx = receiver.asGeometry().dag_idx;

    // Union all passed target shapes before computing the convex hull
    for (args) |arg| {
        if (arg.isGeometry()) {
            current_idx = try vm.dag_builder.addBinary(.union_op, current_idx, arg.asGeometry().dag_idx);
        }
    }

    const hull_idx = try vm.dag_builder.addHull(current_idx);
    return try vm.allocateGeometry(.{ .symbolic = hull_idx });
}

pub fn meshMinkowski(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    if (args.len < 1 or !args[0].isGeometry()) return error.RuntimeError;
    const other = args[0];
    const new_idx = try vm.dag_builder.addBinary(.minkowski, receiver.asGeometry().dag_idx, other.asGeometry().dag_idx);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshTrimByPlane(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    if (args.len < 3) return error.RuntimeError;
    if (!args[0].isNumber() or !args[1].isNumber() or !args[2].isNumber()) return error.RuntimeError;

    const nx = args[0].asNumber();
    const ny = args[1].asNumber();
    const nz = args[2].asNumber();
    const offset = if (args.len > 3 and args[3].isNumber()) args[3].asNumber() else 0.0;

    const new_idx = try vm.dag_builder.addTrimByPlane(receiver.asGeometry().dag_idx, nx, ny, nz, offset);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshOffset(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    var delta: f64 = 1.0;
    var join_type: u8 = 1; // Default to round (1)
    var pos_count = args.len;

    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        pos_count -= 1;
        for (map.keys.items, 0..) |k, i| {
            if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                const k_str = if (k.asObj().obj_type == .string)
                    @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                else
                    @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                const v = map.values.items[i];
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

    const new_idx = try vm.dag_builder.addOffset(receiver.asCrossSection().dag_idx, delta, join_type);
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshSlice(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;

    var height: f64 = 0.0;
    if (args.len > 0 and args[0].isNumber()) {
        height = args[0].asNumber();
    }

    const new_idx = try vm.dag_builder.addSlice(receiver.asGeometry().dag_idx, height);
    return try vm.allocateCrossSection(new_idx);
}

pub fn meshProject(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;

    var cut = false;

    // Parse `cut: true` from kwargs
    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        if (vm.findMapKeyByString(map, "cut")) |idx| {
            if (map.values.items[idx].isBool()) cut = map.values.items[idx].asBool();
        }
    }

    if (cut) {
        // project(cut: true) is a 2D slice exactly at Z=0
        const new_idx = try vm.dag_builder.addSlice(receiver.asGeometry().dag_idx, 0.0);
        return try vm.allocateCrossSection(new_idx);
    } else {
        // Standard 2D shadow projection of the entire 3D volume
        const new_idx = try vm.dag_builder.addProject(receiver.asGeometry().dag_idx);
        return try vm.allocateCrossSection(new_idx);
    }
}

pub fn meshOnFace(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;
    const handle = try vm.ensureConcrete(receiver);
    const geom_obj = receiver.asGeometry();

    if (args.len == 0) return error.RuntimeError;
    const dir_arg = args[0];
    const dir_str = if (dir_arg.isObject() and dir_arg.asObj().obj_type == .symbol)
        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", dir_arg.asObj()))).chars
    else if (dir_arg.isObject() and dir_arg.asObj().obj_type == .string)
        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", dir_arg.asObj()))).chars
    else
        return error.RuntimeError;

    if (geom_obj.cached_topology == null) {
        geom_obj.cached_topology = try vm.allocator.create(value.TopologyCache);
        geom_obj.cached_topology.?.* = .{ .is_populated = true };
    }

    var filter = geom.FaceFilter.top;
    if (std.mem.eql(u8, dir_str, "bottom")) filter = .bottom;

    _ = kernel.queryFaces(handle, filter);
    return try vm.allocateWorkplane(geom_obj, [3]f64{ 0, 0, 0 }, [3]f64{ 0, 0, 1 });
}
