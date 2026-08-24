const std = @import("std");
const value = @import("../../core/value.zig");

/// Parses positional arguments and/or kwargs map into a [x, y, z] struct.
pub fn parseVec3(args: []const value.Value, default_val: f64) !struct { f64, f64, f64 } {
    var pos_count = args.len;
    var kwargs: ?*value.ObjMap = null;

    if (args.len > 0 and args[args.len - 1].isObject() and args[args.len - 1].asObj().obj_type == .map) {
        kwargs = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
        pos_count -= 1;
    }

    if (pos_count > 0 and !args[0].isNumber()) return error.RuntimeError;
    if (pos_count > 1 and !args[1].isNumber()) return error.RuntimeError;
    if (pos_count > 2 and !args[2].isNumber()) return error.RuntimeError;

    var x = if (pos_count > 0) args[0].asNumber() else default_val;
    var y = if (pos_count > 1) args[1].asNumber() else default_val;
    var z = if (pos_count > 2) args[2].asNumber() else default_val;

    if (kwargs) |map| {
        var it = map.map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                const k_str = if (k.asObj().obj_type == .string)
                    @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                else
                    @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                const v = entry.value_ptr.*;
                if (v.isNumber()) {
                    if (std.mem.eql(u8, k_str, "x")) x = v.asNumber();
                    if (std.mem.eql(u8, k_str, "y")) y = v.asNumber();
                    if (std.mem.eql(u8, k_str, "z")) z = v.asNumber();
                }
            }
        }
    }
    return .{ x, y, z };
}
