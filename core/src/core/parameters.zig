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
    /// The warnings, as the run that cached it placed them.
    warnings: std.ArrayList(CachedWarning) = .empty,
    /// Where it named its parts (`named`), each a CachedWarning whose message is the name.
    part_sources: std.ArrayList(CachedWarning) = .empty,

    pub fn deinit(self: *CachedModule, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
        for (self.warnings.items) |w| w.deinit(allocator);
        self.warnings.deinit(allocator);
        for (self.part_sources.items) |s| s.deinit(allocator);
        self.part_sources.deinit(allocator);
    }
};

/// A warning a cached module's run gave: its message, and its place in the module whose code
/// gave it (the path in the project, null for one placed at the import), each owned.
pub const CachedWarning = struct {
    message: []u8,
    /// Its 1-based line and column; 0 for none (the model was being meshed).
    line: u32 = 0,
    column: u32 = 0,
    module: ?[]u8 = null,

    pub fn deinit(self: CachedWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.module) |m| allocator.free(m);
    }
};
