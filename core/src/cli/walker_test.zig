const std = @import("std");
const testing = std.testing;
const walker = @import("walker.zig");

const WalkerContext = struct {
    kup_files_found: usize = 0,
};

// Mock callback that matches the ProcessFileFn signature
fn testProcessFn(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    _ = io;
    _ = allocator;
    _ = file_path;
    _ = source;
    var ctx = @as(*WalkerContext, @ptrCast(@alignCast(context.?)));
    ctx.kup_files_found += 1;
}

test "Walker: Recursively finds .kup files in directory" {
    const paths = &[_][]const u8{"src/fixtures"};
    var ctx = WalkerContext{};

    // We pass the global testing IO handle provided by Zig 0.16!
    try walker.walkPaths(testing.io, testing.allocator, paths, &ctx, testProcessFn);

    try testing.expect(ctx.kup_files_found >= 3);
}
