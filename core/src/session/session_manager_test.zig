const std = @import("std");
const test_support = @import("../test_support.zig");
const testing = std.testing;
const SessionManager = @import("session_manager.zig").SessionManager;
const ScriptSession = @import("session.zig").ScriptSession;

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

    try testing.expectEqual(@as(usize, 0), manager.sessions.count());
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

test "SessionManager: markUsed reorders the LRU queue and evictLRU drops its head" {
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
    sm.evictLRU();

    // 222 should have been evicted, leaving 111
    try std.testing.expectEqual(@as(usize, 1), sm.lru_queue.items.len);
    try std.testing.expectEqual(@as(u64, 111), sm.lru_queue.items[0]);

    sm.mutex.unlock(io);
}

test "SessionManager: evictLRU never frees a session that is still leased" {
    const warnings = test_support.expectWarnings();
    defer warnings.restore();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var paths: [3][]u8 = undefined;
    var n_paths: usize = 0;
    defer for (paths[0..n_paths]) |p| testing.allocator.free(p);
    for (&paths, [_][]const u8{ "a.kup", "b.kup", "c.kup" }) |*p, name| {
        p.* = try std.fs.path.join(testing.allocator, &.{ dir, name });
        n_paths += 1;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
    }

    var manager = SessionManager.init(testing.allocator, testing.io, 1);
    defer manager.deinit();

    const lease = try manager.acquireSession(paths[0]);
    const lease2 = try manager.acquireSession(paths[0]); // leases nest
    try testing.expectEqual(lease.session, lease2.session);

    // Capacity 1: before the fix this evicted (destroyed) the leased session.
    _ = try manager.getOrInitializeSession(paths[1]);
    try testing.expect(manager.sessions.get(lease.id) == lease.session);
    try testing.expectEqual(@as(usize, 2), manager.sessions.count()); // soft limit exceeded
    lease.session.global_revision += 1; // a use-after-free under the old behaviour

    manager.release(lease2);
    try testing.expect(manager.isPinned(lease.id));
    manager.release(lease);
    try testing.expect(!manager.isPinned(lease.id));

    // Once released it is the LRU victim again.
    _ = try manager.getOrInitializeSession(paths[2]);
    try testing.expect(!manager.sessions.contains(lease.id));
}

/// Creates, evicts (capacity 1), leases and reuses sessions with `allocator`.
fn churnSessions(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !void {
    var manager = SessionManager.init(allocator, testing.io, 1);
    defer manager.deinit();
    _ = try manager.getOrInitializeSession(a);
    _ = try manager.getOrInitializeSession(b); // evicts a
    const lease = try manager.acquireSession(a); // creates a again, evicting b
    defer manager.release(lease);
    _ = try manager.getOrInitializeSession(a);
}

test "SessionManager: running out of memory anywhere leaks nothing and keeps the queue whole" {
    // A failed ScriptSession.init leaked the session's allocation, a failed map insert the
    // whole session, and a failed queue append left a session no eviction could reach.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.kup", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.kup", .data = "" });
    const a = try std.fs.path.join(testing.allocator, &.{ dir, "a.kup" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ dir, "b.kup" });
    defer testing.allocator.free(b);
    try testing.checkAllAllocationFailures(testing.allocator, churnSessions, .{ a, b });
}

test "SessionManager: threads leasing and evicting the same sessions keep every lease valid" {
    // The retry loop in acquireSession (a session evicted between its creation and its pin)
    // had never run with more than one thread.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var paths: [3][]u8 = undefined;
    var made: usize = 0;
    defer for (paths[0..made]) |p| testing.allocator.free(p);
    for (&paths, [_][]const u8{ "a.kup", "b.kup", "c.kup" }) |*p, name| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "" });
        p.* = try std.fs.path.join(testing.allocator, &.{ dir, name });
        made += 1;
    }

    var manager = SessionManager.init(testing.allocator, testing.io, 2);
    defer manager.deinit();
    const Worker = struct {
        fn run(m: *SessionManager, all: []const []u8, seed: usize, failed: *std.atomic.Value(bool)) void {
            for (0..40) |i| {
                const lease = m.acquireSession(all[(seed + i) % all.len]) catch {
                    failed.store(true, .release);
                    return;
                };
                // A use of the session while it is leased: freed under it, this is a
                // use-after-free the testing allocator reports.
                lease.session.global_revision += 1;
                m.release(lease);
            }
        }
    };
    var failed = std.atomic.Value(bool).init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &manager, &paths, i, &failed });
    for (threads) |t| t.join();
    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(usize, 0), manager.pins.count());
    try testing.expectEqual(manager.sessions.count(), manager.lru_queue.items.len);
}
