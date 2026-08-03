const std = @import("std");
const token = @import("token.zig");

pub const ParseError = error{
    UnexpectedToken,
    InvalidExpression,
    OutOfMemory,
};

pub const Diagnostic = struct {
    loc: token.Location,
    message: []const u8,
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
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.list.append(self.allocator, .{ .loc = loc, .message = msg }) catch return;
    }
};
