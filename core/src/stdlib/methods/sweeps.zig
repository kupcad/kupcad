const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;

pub fn meshExtrude(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;

    var height: f64 = 1.0;
    var slices: i32 = 0;
    var twist: f64 = 0.0;
    var scale_x: f64 = 1.0;
    var scale_y: f64 = 1.0;
    var center: bool = false;
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
                if (std.mem.eql(u8, k_str, "h") and v.isNumber()) height = v.asNumber();
                if (std.mem.eql(u8, k_str, "slices") and v.isNumber()) slices = @intFromFloat(v.asNumber());
                if (std.mem.eql(u8, k_str, "twist") and v.isNumber()) twist = v.asNumber();
                if (std.mem.eql(u8, k_str, "scale") and v.isNumber()) {
                    scale_x = v.asNumber();
                    scale_y = v.asNumber();
                }
                if (std.mem.eql(u8, k_str, "scale_x") and v.isNumber()) scale_x = v.asNumber();
                if (std.mem.eql(u8, k_str, "scale_y") and v.isNumber()) scale_y = v.asNumber();
                if (std.mem.eql(u8, k_str, "center") and v.isBool()) center = v.asBool();
            }
        }
    }

    if (pos_count > 0) {
        if (!args[0].isNumber()) return error.RuntimeError;
        height = args[0].asNumber();
    }

    var new_idx = try vm.dag_builder.addExtrude(receiver.asCrossSection().dag_idx, height, slices, twist, scale_x, scale_y);

    // Auto-translate to center
    if (center) {
        new_idx = try vm.dag_builder.addTranslate(new_idx, 0.0, 0.0, -height / 2.0);
    }

    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshRevolve(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isCrossSection()) return error.RuntimeError;
    var degrees: f64 = 360.0;
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

                if (std.mem.eql(u8, k_str, "deg") and map.values.items[i].isNumber()) degrees = map.values.items[i].asNumber();
            }
        }
    }

    if (pos_count > 0) {
        if (!args[0].isNumber()) return error.RuntimeError;
        degrees = args[0].asNumber();
    }

    const new_idx = try vm.dag_builder.addRevolve(receiver.asCrossSection().dag_idx, 0, degrees);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}
