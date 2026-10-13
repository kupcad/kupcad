const std = @import("std");
const testing = std.testing;
const ScriptSession = @import("session.zig").ScriptSession;
const Watcher = @import("watcher.zig").Watcher;
const kernel = @import("../kernel/kernel.zig");

/// Pushes the file's mtime forward explicitly so change detection never depends on the
/// filesystem's timestamp granularity (no sleeps needed).
const MTIME_BUMP_NS: i96 = std.time.ns_per_s;

test "Daemon Watcher: re-reads and re-evaluates the file after a modification" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const file_path = try std.fs.path.join(testing.allocator, &.{ dir, "watched.kup" });
    defer testing.allocator.free(file_path);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "watched.kup", .data = "x = cube(10)\n" });

    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();
    const root_id = try session.workspace.addModule(file_path, "x = cube(10)\n");
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();
    // Clear initial state (global_revision starts at 1).
    session.nodes.items[@backingInt(root_id)].is_stale = false;
    session.nodes.items[@backingInt(root_id)].verified_at = 1;

    var watcher = try Watcher.init(&session, file_path, testing.io);
    defer watcher.deinit();
    watcher.is_one_shot = true;

    {
        const file = try tmp.dir.createFile(testing.io, "watched.kup", .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, "x = cube(20)\n");
        const new_mtime = std.Io.Timestamp.fromNanoseconds(@intCast(watcher.last_mtime + MTIME_BUMP_NS));
        try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = new_mtime } });
    }

    try watcher.start(); // a single poll cycle

    // The change was detected: revision bumped and the node re-verified.
    try testing.expectEqual(@as(u64, 2), session.global_revision);
    const node = session.nodes.items[@backingInt(root_id)];
    try testing.expectEqual(@as(u64, 2), node.verified_at);
    try testing.expect(!node.is_stale);

    // ...and the new source was actually used (it used to re-run the stale initial source).
    try testing.expectEqualStrings("x = cube(20)\n", session.workspace.modules.items[@backingInt(root_id)].source);
    try testing.expectApproxEqAbs(@as(f64, 20 * 20 * 20), kernel.volume(node.cached_handle.?), 1e-6);
}
