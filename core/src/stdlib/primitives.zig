const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

/// Helper to safely extract a value from the trailing keyword arguments map
fn getKwarg(map_val: ?value.Value, key: []const u8) ?value.Value {
    if (map_val) |mv| {
        if (mv.isObject() and mv.asObj().obj_type == .map) {
            const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", mv.asObj())));
            for (map.keys.items, 0..) |k, i| {
                // Check both Strings and Symbols for the key
                if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                    const k_str = if (k.asObj().obj_type == .string)
                        @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                    else
                        @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                    if (std.mem.eql(u8, k_str, key)) {
                        return map.values.items[i];
                    }
                }
            }
        }
    }
    return null;
}

pub fn nativeCube(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    var x: f64 = 1.0;
    var y: f64 = 1.0;
    var z: f64 = 1.0;
    var center: bool = false;

    var pos_count = arg_count;
    var kwargs: ?value.Value = null;

    // Check if the last argument is a map (Keyword Arguments)
    if (arg_count > 0 and args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        kwargs = args[arg_count - 1];
        pos_count -= 1;
    }

    // 1. Parse Positional Arguments
    if (pos_count > 0 and args[0].isNumber()) {
        x = args[0].asNumber();
        y = x; // Default to a uniform cube if only 1 arg is passed
        z = x;
    }
    if (pos_count > 1 and args[1].isNumber()) y = args[1].asNumber();
    if (pos_count > 2 and args[2].isNumber()) z = args[2].asNumber();
    if (pos_count > 3 and args[3].isBool()) center = args[3].asBool();

    // 2. Parse Keyword Arguments (Overrides positionals)
    if (getKwarg(kwargs, "size")) |v| {
        if (v.isNumber()) {
            x = v.asNumber();
            y = x;
            z = x;
        }
    }
    if (getKwarg(kwargs, "x")) |v| {
        if (v.isNumber()) x = v.asNumber();
    }
    if (getKwarg(kwargs, "y")) |v| {
        if (v.isNumber()) y = v.asNumber();
    }
    if (getKwarg(kwargs, "z")) |v| {
        if (v.isNumber()) z = v.asNumber();
    }
    if (getKwarg(kwargs, "center")) |v| {
        if (v.isBool()) center = v.asBool();
    }

    const dag_idx = try vm.dag_builder.addCube(x, y, z, center);
    const geom_obj = try vm.gc.allocateGeometry(.{ .symbolic = dag_idx });
    return value.Value.initGeometry(geom_obj);
}

pub fn nativeCylinder(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    var r: f64 = 1.0;
    var h: f64 = 1.0;
    var center: bool = false;

    var pos_count = arg_count;
    var kwargs: ?value.Value = null;

    if (arg_count > 0 and args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        kwargs = args[arg_count - 1];
        pos_count -= 1;
    }

    if (pos_count > 0 and args[0].isNumber()) r = args[0].asNumber();
    if (pos_count > 1 and args[1].isNumber()) h = args[1].asNumber();
    if (pos_count > 2 and args[2].isBool()) center = args[2].asBool();

    if (getKwarg(kwargs, "r")) |v| {
        if (v.isNumber()) r = v.asNumber();
    }
    if (getKwarg(kwargs, "d")) |v| {
        if (v.isNumber()) r = v.asNumber() / 2.0;
    }
    if (getKwarg(kwargs, "h")) |v| {
        if (v.isNumber()) h = v.asNumber();
    }
    if (getKwarg(kwargs, "center")) |v| {
        if (v.isBool()) center = v.asBool();
    }

    const dag_idx = try vm.dag_builder.addCylinder(r, h, center);
    const geom_obj = try vm.gc.allocateGeometry(.{ .symbolic = dag_idx });
    return value.Value.initGeometry(geom_obj);
}

pub fn nativeSphere(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    var r: f64 = 1.0;

    var pos_count = arg_count;
    var kwargs: ?value.Value = null;

    if (arg_count > 0 and args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        kwargs = args[arg_count - 1];
        pos_count -= 1;
    }

    if (pos_count > 0 and args[0].isNumber()) r = args[0].asNumber();

    if (getKwarg(kwargs, "r")) |v| {
        if (v.isNumber()) r = v.asNumber();
    }
    if (getKwarg(kwargs, "d")) |v| {
        if (v.isNumber()) r = v.asNumber() / 2.0;
    }

    const dag_idx = try vm.dag_builder.addSphere(r);
    const geom_obj = try vm.gc.allocateGeometry(.{ .symbolic = dag_idx });
    return value.Value.initGeometry(geom_obj);
}
