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
    try testing.expectEqual(@as(usize, 0), try walker.walkPaths(.{ .io = testing.io }, testing.allocator, &.{ root, direct }, &ctx, testProcessFn));

    // 3 from the directory walk + the directly named file
    try testing.expectEqual(@as(usize, 4), ctx.kup_files_found);
    try testing.expectEqual(@as(usize, 4), ctx.bytes_seen);
}

test "Walker: paths that can't be read are counted, and the rest are still walked" {
    // Callers turn the count into a failure; before, a missing path was only logged, so
    // `kupcad check missing.kup` reported success.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ok.kup", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const ok = try std.fs.path.join(testing.allocator, &.{ root, "ok.kup" });
    defer testing.allocator.free(ok);
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "missing.kup" });
    defer testing.allocator.free(missing);

    var ctx = WalkerContext{};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 2), try walker.walkPaths(.{ .io = testing.io, .capture = &out.writer }, testing.allocator, &.{ missing, ok, "/nonexistent/kupcad/dir" }, &ctx, testProcessFn));
    try testing.expectEqual(@as(usize, 1), ctx.kup_files_found);
    // Each one is reported through the command's reporter (it used to go straight to stderr).
    const expected = try std.fmt.allocPrint(testing.allocator, "Error: Could not read '{s}': FileNotFound\nError: Could not read '/nonexistent/kupcad/dir': FileNotFound\n", .{missing});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, out.written());
}
