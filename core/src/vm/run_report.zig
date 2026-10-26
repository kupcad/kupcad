//! What a run tells its host besides its model and its error: its warnings (a mesh mended,
//! a feature the engine lacks), each where the script was when it warned (`VM.warn`), the
//! parameter whose value stopped it (stdlib/params.zig), for a host's control to mark, and,
//! for a preview, what it printed (its frame's, the console beside the model's).
//! A fresh VM's is empty; `VM.resetRunOutput` empties it before a session runs a module.

const std = @import("std");
const Step = @import("../core/param_rules.zig").Step;

/// How many warnings a run keeps: a warning that differs at every pass of a loop keeps the
/// first ones, and the log has them all.
pub const MAX_WARNINGS = 100;
/// How much of what a run prints it keeps: a script that prints in a loop keeps the start.
pub const MAX_OUTPUT_BYTES = 64 * 1024;

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
    /// Where in its value, owned: `[1, "depth"]` for `:cutouts[1][:depth]`; empty for the whole.
    refused_path: []Step = &.{},
    /// What the run printed (`puts`, `print`, `inspect`), as it printed it, where its host keeps it
    /// (a preview's run: stdlib/registry.zig); up to MAX_OUTPUT_BYTES, `output_cut` past them.
    output: std.ArrayList(u8) = .empty,
    output_cut: bool = false,

    pub fn deinit(self: *RunReport, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.warnings.deinit(allocator);
        self.output.deinit(allocator);
    }

    pub fn clear(self: *RunReport, allocator: std.mem.Allocator) void {
        for (self.warnings.items) |w| allocator.free(w.message);
        self.warnings.clearRetainingCapacity();
        self.forgetRefusal(allocator);
        self.output.clearRetainingCapacity();
        self.output_cut = false;
    }

    /// Keeps `text` the run printed, as much of it as MAX_OUTPUT_BYTES leaves room for, cut
    /// between characters, not inside one.
    pub fn addOutput(self: *RunReport, allocator: std.mem.Allocator, text: []const u8) !void {
        var end = @min(text.len, MAX_OUTPUT_BYTES - self.output.items.len);
        if (end < text.len) {
            self.output_cut = true;
            // A UTF-8 continuation byte (10xxxxxx) is inside a character
            while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
        }
        try self.output.appendSlice(allocator, text[0..end]);
    }

    /// Forgets the parameter named as the one that stopped the run: its error was rescued.
    pub fn forgetRefusal(self: *RunReport, allocator: std.mem.Allocator) void {
        if (self.refused_param) |name| allocator.free(name);
        self.refused_param = null;
        freePath(allocator, self.refused_path);
        self.refused_path = &.{};
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

    /// Notes that the value of the parameter `name`, at `path` in it, stopped the run.
    pub fn refuse(self: *RunReport, allocator: std.mem.Allocator, name: []const u8, path: []const Step) !void {
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        const owned_path = try allocator.alloc(Step, path.len);
        var made: usize = 0;
        errdefer freePath(allocator, owned_path[0..made]);
        for (path, owned_path) |step, *copy| {
            copy.* = switch (step) {
                .index => step,
                .field => |f| .{ .field = try allocator.dupe(u8, f) },
            };
            made += 1;
        }
        self.forgetRefusal(allocator);
        self.refused_param = owned;
        self.refused_path = owned_path;
    }
};

fn freePath(allocator: std.mem.Allocator, path: []Step) void {
    for (path) |step| switch (step) {
        .field => |f| allocator.free(f),
        .index => {},
    };
    allocator.free(path);
}
