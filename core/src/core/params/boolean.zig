//! Reads a boolean parameter value: true or false, the numbers 1 and 0, or the strings
//! "true", "false", "1" and "0"; anything else is error.InvalidType. Used by stdlib/params.zig.

const std = @import("std");
const value = @import("../value.zig");

pub fn normalize(val: value.Value) !bool {
    if (val.isBool()) return val.asBool();

    // Normalize binary integers
    if (val.isNumber()) {
        const num = val.asNumber();
        if (num == 1.0) return true;
        if (num == 0.0) return false;
    }

    // Normalize string keywords
    if (val.isString()) {
        const str = val.asString().chars;
        if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1")) return true;
        if (std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "0")) return false;
    }

    return error.InvalidType;
}
