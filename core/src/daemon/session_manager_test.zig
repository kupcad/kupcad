const std = @import("std");
const testing = std.testing;
const SessionManager = @import("session_manager.zig").SessionManager;
const ScriptSession = @import("session.zig").ScriptSession;

test "SessionManager: initializes and respects max_sessions capacity" {
    var manager = SessionManager.init(testing.allocator, testing.io, 2);
    defer manager.deinit();

    try testing.expectEqual(@as(usize, 2), manager.max_sessions);
    try testing.expectEqual(@as(usize, 0), manager.sessions.count());
}

test "SessionManager: getOrInitializeSession creates and caches sessions" {
    var manager = SessionManager.init(testing.allocator, testing.io, 2);
    defer manager.deinit();

    // Create a dummy file so std.fs.cwd().realpath doesn't fail
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const file_path = try testing.allocator.print("{s}/test.kup", .{tmp_path});
    defer testing.allocator.free(file_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = file_path, .data = "cube(10)" });

    const session1 = try manager.getOrInitializeSession(file_path);
    try testing.expectEqual(@as(usize, 1), manager.sessions.count());
    try testing.expectEqual(@as(usize, 1), manager.lru_queue.items.len);

    const session2 = try manager.getOrInitializeSession(file_path);

    // Should return the exact same pointer and NOT increase the total count
    try testing.expectEqual(session1, session2);
    try testing.expectEqual(@as(usize, 1), manager.sessions.count());
}

test "SessionManager: LRU eviction removes oldest sessions when capacity is exceeded" {
    var manager = SessionManager.init(testing.allocator, testing.io, 2);
    defer manager.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    const p1 = try testing.allocator.print("{s}/file1.kup", .{tmp_path});
    defer testing.allocator.free(p1);
    const p2 = try testing.allocator.print("{s}/file2.kup", .{tmp_path});
    defer testing.allocator.free(p2);
    const p3 = try testing.allocator.print("{s}/file3.kup", .{tmp_path});
    defer testing.allocator.free(p3);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = p1, .data = "" });
    try cwd.writeFile(testing.io, .{ .sub_path = p2, .data = "" });
    try cwd.writeFile(testing.io, .{ .sub_path = p3, .data = "" });

    _ = try manager.getOrInitializeSession(p1);
    _ = try manager.getOrInitializeSession(p2);

    try testing.expectEqual(@as(usize, 2), manager.sessions.count());

    // Hitting capacity: getting p3 should evict p1 (the least recently used)
    _ = try manager.getOrInitializeSession(p3);

    try testing.expectEqual(@as(usize, 2), manager.sessions.count());

    // p1's hash should be gone from the cache!
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(p1);
    const id1 = hasher.final();

    try testing.expect(!manager.sessions.contains(id1));
}

test "SessionManager: Thread-safe double-checked LRU queue" {
    const io = std.testing.io;
    var sm = SessionManager.init(std.testing.allocator, io, 2);
    defer sm.deinit();

    // Simulate Lock Acquisition
    sm.mutex.lockUncancelable(io);

    // Create real dummy sessions instead of `undefined` to prevent deinit() segfaults upon eviction
    const s1 = try std.testing.allocator.create(ScriptSession);
    s1.* = try ScriptSession.init(std.testing.allocator, io);
    try sm.sessions.put(std.testing.allocator, 111, s1);
    try sm.lru_queue.append(std.testing.allocator, 111);

    const s2 = try std.testing.allocator.create(ScriptSession);
    s2.* = try ScriptSession.init(std.testing.allocator, io);
    try sm.sessions.put(std.testing.allocator, 222, s2);
    try sm.lru_queue.append(std.testing.allocator, 222);

    // Push 111 to the back of the LRU
    sm.markUsed(111);
    try std.testing.expectEqual(@as(u64, 222), sm.lru_queue.items[0]);
    try std.testing.expectEqual(@as(u64, 111), sm.lru_queue.items[1]);

    // Force eviction (this will safely deinit and destroy `s2` which maps to 222)
    try sm.evictLRU();

    // 222 should have been evicted, leaving 111
    try std.testing.expectEqual(@as(usize, 1), sm.lru_queue.items.len);
    try std.testing.expectEqual(@as(u64, 111), sm.lru_queue.items[0]);

    sm.mutex.unlock(io);
}
