const std = @import("std");
const value = @import("../value.zig");

pub fn normalize(val: value.Value) ![]const u8 {
    if (val.isObject() and val.asObj().obj_type == .string) {
        return @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", val.asObj()))).chars;
    }

    // Allow Symbol interpolation mappings
    if (val.isObject() and val.asObj().obj_type == .symbol) {
        return @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", val.asObj()))).chars;
    }

    return error.InvalidType;
}
