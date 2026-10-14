const std = @import("std");
const token = @import("token.zig");
const LineIndex = @import("line_index.zig").LineIndex;

pub const ParseError = error{
    AstTooDeep,
    UnexpectedToken,
    InvalidExpression,
    OutOfMemory,
};

pub const Diagnostic = struct {
    loc: token.Location,
    message: []const u8,

    /// "line:col: message", the one-line form for where there is no room for a caret.
    pub fn formatLine(self: Diagnostic, allocator: std.mem.Allocator, line_index: *const LineIndex) ![]u8 {
        const line = line_index.getLine(self.loc.offset) + 1;
        const col = line_index.getUtf8Column(self.loc.offset) + 1;
        return allocator.print("{d}:{d}: {s}", .{ line, col, self.message });
    }
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.list.items) |d| {
            self.allocator.free(d.message);
        }
        self.list.deinit(self.allocator);
    }

    pub fn add(self: *Diagnostics, loc: token.Location, comptime fmt: []const u8, args: anytype) void {
        const msg = self.allocator.print(fmt, args) catch return;
        self.list.append(self.allocator, .{ .loc = loc, .message = msg }) catch return;
    }
};
