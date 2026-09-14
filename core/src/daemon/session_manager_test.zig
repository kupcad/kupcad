const std = @import("std");
const testing = std.testing;
const SessionManager = @import("session_manager.zig").SessionManager;

test "SessionManager: initializes and respects max_sessions capacity" {
    var manager = SessionManager.init(testing.allocator, 2);
    defer manager.deinit();

    try testing.expectEqual(@as(usize, 2), manager.max_sessions);
    try testing.expectEqual(@as(usize, 0), manager.sessions.count());
}

test "SessionManager: getOrInitializeSession creates and caches sessions" {
    var manager = SessionManager.init(testing.allocator, 2);
    defer manager.deinit();

    // Create a dummy file so std.fs.cwd().realpath doesn't fail
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.kup", .{tmp_path});
    defer testing.allocator.free(file_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = file_path, .data = "cube(10)" });

    const session1 = try manager.getOrInitializeSession(file_path, testing.io);
    try testing.expectEqual(@as(usize, 1), manager.sessions.count());
    try testing.expectEqual(@as(usize, 1), manager.lru_queue.items.len);

    const session2 = try manager.getOrInitializeSession(file_path, testing.io);

    // Should return the exact same pointer and NOT increase the total count
    try testing.expectEqual(session1, session2);
    try testing.expectEqual(@as(usize, 1), manager.sessions.count());
}

test "SessionManager: LRU eviction removes oldest sessions when capacity is exceeded" {
    var manager = SessionManager.init(testing.allocator, 2);
    defer manager.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const p1 = try std.fmt.allocPrint(testing.allocator, "{s}/file1.kup", .{tmp_path});
    defer testing.allocator.free(p1);
    const p2 = try std.fmt.allocPrint(testing.allocator, "{s}/file2.kup", .{tmp_path});
    defer testing.allocator.free(p2);
    const p3 = try std.fmt.allocPrint(testing.allocator, "{s}/file3.kup", .{tmp_path});
    defer testing.allocator.free(p3);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = p1, .data = "" });
    try cwd.writeFile(testing.io, .{ .sub_path = p2, .data = "" });
    try cwd.writeFile(testing.io, .{ .sub_path = p3, .data = "" });

    _ = try manager.getOrInitializeSession(p1, testing.io);
    _ = try manager.getOrInitializeSession(p2, testing.io);

    try testing.expectEqual(@as(usize, 2), manager.sessions.count());

    // Hitting capacity: getting p3 should evict p1 (the least recently used)
    _ = try manager.getOrInitializeSession(p3, testing.io);

    try testing.expectEqual(@as(usize, 2), manager.sessions.count());

    // p1's hash should be gone from the cache!
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(p1);
    const id1 = hasher.final();

    try testing.expect(!manager.sessions.contains(id1));
}
