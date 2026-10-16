//! The types of a script's `param(...)` entries: `ParamRegistry` holds one parameter's name,
//! type, current value, range and choices, and the VM keeps them in a `ParamList`.

const std = @import("std");
const value = @import("value.zig");

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
