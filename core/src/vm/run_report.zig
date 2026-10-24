//! What a run tells its host besides its model and its error: its warnings (a mesh mended,
//! a feature the engine lacks), each where the script was when it warned (`VM.warn`), and
//! the parameter whose value stopped it (stdlib/params.zig), for a host's control to mark.
//! A fresh VM's is empty; `VM.resetRunOutput` empties it before a session runs a module.

const std = @import("std");

/// How many warnings a run keeps: a warning that differs at every pass of a loop keeps the
/// first ones, and the log has them all.
pub const MAX_WARNINGS = 100;

/// A place in the running document: its 1-based line, and its 1-based column in UTF-8 bytes.
pub const LinePosition = struct { line: u32, column: u32 };

pub const Warning = struct {
    message: []u8,
    /// Null where the script wasn't running (a warning while the model was meshed).
    position: ?LinePosition,
};

pub const RunReport = struct {
    warnings: std.ArrayList(Warning) = .empty,
    /// The name of the parameter whose value stopped the run, owned.
    refused_param: ?[]u8 = null,

    pub fn deinit(self: *RunReport, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.warnings.deinit(allocator);
    }

    pub fn clear(self: *RunReport, allocator: std.mem.Allocator) void {
        for (self.warnings.items) |w| allocator.free(w.message);
        self.warnings.clearRetainingCapacity();
        if (self.refused_param) |name| allocator.free(name);
        self.refused_param = null;
    }

    /// Keeps `message` (owned by `allocator`, which the report takes) at `position`; one kept
    /// already, word for word, is freed instead (a run warns of a thing once: a loop's pass,
    /// a module imported twice), and so is one past MAX_WARNINGS.
    pub fn addWarning(self: *RunReport, allocator: std.mem.Allocator, message: []u8, position: ?LinePosition) !void {
        if (self.warnings.items.len >= MAX_WARNINGS or self.has(message)) return allocator.free(message);
        errdefer allocator.free(message);
        try self.warnings.append(allocator, .{ .message = message, .position = position });
    }

    fn has(self: *const RunReport, message: []const u8) bool {
        for (self.warnings.items) |kept| {
            if (std.mem.eql(u8, kept.message, message)) return true;
        }
        return false;
    }

    /// Notes that the value of the parameter `name` stopped the run.
    pub fn refuse(self: *RunReport, allocator: std.mem.Allocator, name: []const u8) !void {
        const owned = try allocator.dupe(u8, name);
        if (self.refused_param) |old| allocator.free(old);
        self.refused_param = owned;
    }
};
