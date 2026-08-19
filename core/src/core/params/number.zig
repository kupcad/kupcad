const std = @import("std");
const value = @import("../value.zig");

pub fn normalize(val: value.Value) !f64 {
    if (val.isNumber()) return val.asNumber();

    // Auto-coerce string injections from the CLI (e.g., --param width="10.5")
    if (val.isObject() and val.asObj().obj_type == .string) {
        const str = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", val.asObj()))).chars;
        if (std.fmt.parseFloat(f64, str)) |num| {
            return num;
        } else |_| {}
    }

    return error.InvalidType;
}

pub fn validate(num: f64, min_val: f64, max_val: f64) !void {
    if (!std.math.isNan(min_val) and num < min_val) return error.BelowMin;
    if (!std.math.isNan(max_val) and num > max_val) return error.AboveMax;
}
