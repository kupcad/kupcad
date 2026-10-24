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

/// A module in the VM's import cache: what it exports, and the parameters declared while it
/// ran (its own `param(...)` calls and its imports'). An import served from the cache doesn't
/// run the module's code, so it declares these again: a run that imports it reads them as one
/// that ran it does.
pub const CachedModule = struct {
    exports: value.Value,
    params: std.ArrayList(ParamRegistry) = .empty,

    pub fn deinit(self: *CachedModule, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
    }
};
