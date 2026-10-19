//! Number parameters, for stdlib/params.zig: `normalize` reads a value as a number (text
//! from `-p` is parsed) and `validate` checks it against the parameter's min and max.

const std = @import("std");
const value = @import("../value.zig");

pub fn normalize(val: value.Value) !f64 {
    if (val.isNumber()) return val.asNumber();

    // Text from the host (`-p width=10.5`), read as a number; a finite one, as a script's
    // numbers are (parseFloat reads "inf" and "nan" too)
    if (val.isString()) {
        const num = std.fmt.parseFloat(f64, val.asString().chars) catch return error.InvalidType;
        if (std.math.isFinite(num)) return num;
    }

    return error.InvalidType;
}

pub fn validate(num: f64, min_val: f64, max_val: f64) !void {
    if (!std.math.isNan(min_val) and num < min_val) return error.BelowMin;
    if (!std.math.isNan(max_val) and num > max_val) return error.AboveMax;
}
