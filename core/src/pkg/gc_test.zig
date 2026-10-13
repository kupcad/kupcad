const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const GarbageCollector = @import("gc.zig").GarbageCollector;

const Fixture = struct {
    tmp: testing.TmpDir,
    tmp_path: [:0]u8,
    mem_vfs: MemoryVfs,
    cafs: Cafs,
    store: Store,

    fn init(self: *Fixture) !void {
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
        self.store.deinit();
        self.cafs.deinit();
        self.mem_vfs.deinit();
        testing.allocator.free(self.tmp_path);
        self.tmp.cleanup();
    }

    fn gc(self: *Fixture) GarbageCollector {
        return GarbageCollector.init(testing.allocator, testing.io, &self.cafs, &self.store);
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
