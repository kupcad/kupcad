//! `normalize`: the characters of a string or symbol value, or error.InvalidType for anything
//! else. Used by `stdlib/params.zig` to check the value of a String or Symbol parameter.

const value = @import("../value.zig");

pub fn normalize(val: value.Value) ![]const u8 {
    return val.nameChars() orelse error.InvalidType;
}
