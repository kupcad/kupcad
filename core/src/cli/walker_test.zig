const std = @import("std");
const testing = std.testing;
const walker = @import("walker.zig");

const WalkerContext = struct {
    kup_files_found: usize = 0,
    bytes_seen: usize = 0,
};

// Mock callback that matches the ProcessFileFn signature
fn testProcessFn(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    _ = io;
    _ = allocator;
    try testing.expect(std.mem.endsWith(u8, file_path, ".kup"));
    var ctx: *WalkerContext = @ptrCast(@alignCast(context.?));
    ctx.kup_files_found += 1;
    ctx.bytes_seen += source.len;
}

test "Walker: recursively finds only .kup files and accepts direct file paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub/deep");
    const files = [_][]const u8{ "a.kup", "sub/b.kup", "sub/deep/c.kup", "notes.txt", "sub/d.kup.bak" };
    for (files) |name| try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "x" });

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const direct = try std.fs.path.join(testing.allocator, &.{ root, "a.kup" });
    defer testing.allocator.free(direct);

    var ctx = WalkerContext{};
    try walker.walkPaths(testing.io, testing.allocator, &.{ root, direct }, &ctx, testProcessFn);

    // 3 from the directory walk + the directly named file
    try testing.expectEqual(@as(usize, 4), ctx.kup_files_found);
    try testing.expectEqual(@as(usize, 4), ctx.bytes_seen);
}
