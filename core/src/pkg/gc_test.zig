const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const gc_mod = @import("gc.zig");
const GarbageCollector = gc_mod.GarbageCollector;
const countRows = @import("test_helpers.zig").countRows;

const Fixture = struct {
    tmp: testing.TmpDir,
    tmp_path: [:0]u8,
    mem_vfs: MemoryVfs,
    cafs: Cafs,
    store: Store,
    /// What the collector printed.
    out: std.Io.Writer.Allocating,

    fn init(self: *Fixture) !void {
        self.out = .init(testing.allocator);
        errdefer self.out.deinit();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.tmp_path = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.tmp_path);
        self.mem_vfs = MemoryVfs.init(testing.allocator);
        errdefer self.mem_vfs.deinit();
        self.cafs = try Cafs.init(testing.allocator, testing.io, self.tmp_path, self.mem_vfs.vfs());
        errdefer self.cafs.deinit();
        self.store = try Store.init(testing.io, ":memory:");
    }

    fn deinit(self: *Fixture) void {
        self.out.deinit();
        self.store.deinit();
        self.cafs.deinit();
        self.mem_vfs.deinit();
        testing.allocator.free(self.tmp_path);
        self.tmp.cleanup();
    }

    fn gc(self: *Fixture) GarbageCollector {
        return GarbageCollector.init(testing.allocator, testing.io, &self.cafs, &self.store, .{ .io = testing.io, .capture = &self.out.writer });
    }

    /// Writes a blob just now (age 0) and returns its absolute path (caller frees).
    fn writeBlob(self: *Fixture, hash: []const u8, data: []const u8) ![]const u8 {
        const path = try self.cafs.blobPath(hash);
        errdefer testing.allocator.free(path);
        var f = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, data);
        return path;
    }
};

fn expectExists(path: []const u8) !void {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return error.ShouldNotHaveBeenDeleted;
}

test "GarbageCollector: prune(true) removes orphaned files and index records" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const path = try fx.writeBlob("stale_hash", "old data");
    defer testing.allocator.free(path);
    try fx.store.db.exec("INSERT INTO files (hash, size, created_at) VALUES ('stale_hash', 8, 0)", .{}, .{});

    var gc = fx.gc();
    try gc.prune(true);

    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));
    const stmt = try fx.store.db.prepare("SELECT 1 FROM files WHERE hash = 'stale_hash'");
    defer stmt.deinit();
    try testing.expect((try stmt.one(struct { val: i32 }, .{}, .{})) == null);
}

test "GarbageCollector: prune(false) skips files younger than 7 days" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const path = try fx.writeBlob("fresh_hash", "fresh data");
    defer testing.allocator.free(path);

    var gc = fx.gc();
    try gc.prune(false);
    try expectExists(path);
}

test "GarbageCollector: prune(true) skips files actively linked to projects (nlink > 1)" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const path = try fx.writeBlob("active_hash", "active data");
    defer testing.allocator.free(path);

    // A hard link simulates a project that uses the blob.
    const cwd = std.Io.Dir.cwd();
    const project_link = try testing.allocator.print("{s}/active_hash_link", .{fx.tmp_path});
    defer testing.allocator.free(project_link);
    try std.Io.Dir.hardLink(cwd, path, cwd, project_link, testing.io, .{});

    // force overrides age, but not nlink
    var gc = fx.gc();
    try gc.prune(true);
    try expectExists(path);
}

// Audit fix: prune deleted blobs but left their packages looking cached, so
// linking later failed on the missing files.
test "GarbageCollector: prune evicts packages whose blobs were deleted" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    testing.allocator.free(try fx.writeBlob("deadbeef", "content"));
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", "deadbeef");
    try fx.store.registerPackage("pkg", "c1", "github", "sha256-x", &files);

    // A package that doesn't reference the pruned blob must survive.
    var other = std.StringHashMap([]const u8).init(testing.allocator);
    defer other.deinit();
    try other.put("lib.kup", "keepme");
    try fx.store.registerPackage("other", "c9", "github", "sha256-y", &other);

    var gc = fx.gc();
    try gc.prune(true);

    try testing.expect(!try fx.store.hasPackage("pkg", "c1"));
    try testing.expectEqual(@as(i64, 0), try countRows(&fx.store, "SELECT COUNT(*) FROM package_files WHERE package_id = 'pkg'"));
    try testing.expect(try fx.store.hasPackage("other", "c9"));
    try testing.expectEqual(@as(i64, 1), try countRows(&fx.store, "SELECT COUNT(*) FROM package_files WHERE package_id = 'other'"));
}

// Audit fix: a CAFS file name crafted as SQL was formatted into the DELETE, so
// prune deleted every `files` row. (Doctor half: health_test.zig.)
test "GarbageCollector: prune binds blob names as SQL parameters" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const evil_name = "zz' OR '1'='1";
    // Only the evil blob is physically present and unreferenced; 'keep' is just a row.
    try fx.store.db.exec("INSERT INTO files (hash, size, created_at) VALUES ('keep', 0, 0)", .{}, .{});
    testing.allocator.free(try fx.writeBlob(evil_name, "x"));

    var gc = fx.gc();
    try gc.prune(true);

    try testing.expectEqual(@as(i64, 1), try countRows(&fx.store, "SELECT COUNT(*) FROM files WHERE hash = 'keep'"));
}

/// Sets a blob's modification time `seconds` in the past.
fn age(path: []const u8, seconds: i64) !void {
    var f = try std.Io.Dir.cwd().openFile(testing.io, path, .{ .mode = .read_write });
    defer f.close(testing.io);
    const now = std.Io.Clock.real.now(testing.io);
    const then: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - @as(i96, seconds) * std.time.ns_per_s };
    try f.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = then } });
}

test "GarbageCollector: prune(false) keeps the blobs of a package an install just used" {
    // A project on another device holds copies, so the store's blobs keep one link: an
    // install that reused old blobs had its package pruned and evicted right after.
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const path = try fx.writeBlob("copied", "content");
    defer testing.allocator.free(path);
    try age(path, gc_mod.RETENTION_SECONDS + 60);
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", "copied");
    try fx.store.registerPackage("pkg", "c1", "github", "sha256-x", &files);

    var gc = fx.gc();
    try gc.prune(false);
    try expectExists(path);
    try testing.expect(try fx.store.hasPackage("pkg", "c1"));

    // Once no install has used the package for the retention period, it goes.
    try fx.store.db.exec("UPDATE packages SET last_used = 0", .{}, .{});
    try gc.prune(false);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));
    try testing.expect(!try fx.store.hasPackage("pkg", "c1"));
}
