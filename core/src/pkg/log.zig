const std = @import("std");
const builtin = @import("builtin");

/// Prints to stderr during normal execution, but mutes output during `zig build test`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        std.debug.print(fmt, args);
    }
}
