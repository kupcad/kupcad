const std = @import("std");
const value = @import("value.zig");
const ast = @import("ast.zig");

pub const ParamType = enum {
    number,
    string,
    boolean,
    symbol,
};

pub const ParamRegistry = struct {
    name: value.Value,
    param_type: ParamType,
    current_value: value.Value,
    min_val: f64,
    max_val: f64,
    choices: ?*value.ObjArray,
};

pub const ParamList = std.MultiArrayList(ParamRegistry);
