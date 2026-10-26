//! A script's `param(...)` entries: `ParamRegistry` holds one parameter's name and the value
//! it took (its rules are param_rules.zig's, read where it is declared), and the VM keeps them
//! in a `ParamList`.

const std = @import("std");
const value = @import("value.zig");

pub const ParamRegistry = struct {
    name: value.Value,
    current_value: value.Value,
};

pub const ParamList = std.MultiArrayList(ParamRegistry);

/// A module in the VM's import cache: what it exports, and the parameters declared and the
/// warnings given while it ran (its own and its imports'). An import served from the cache
/// doesn't run the module's code, so it declares and warns of these again: a run that
/// imports it reads and reports them as one that ran it does.
pub const CachedModule = struct {
    exports: value.Value,
    params: std.ArrayList(ParamRegistry) = .empty,
    /// The warnings' messages, owned.
    warnings: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *CachedModule, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
        for (self.warnings.items) |message| allocator.free(message);
        self.warnings.deinit(allocator);
    }
};
