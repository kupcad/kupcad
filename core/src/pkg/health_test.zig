const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const Doctor = @import("health.zig").Doctor;

test "Doctor: healMissingBlobs evicts blob and package records when physical files vanish" {
    std.testing.log_level = .err;

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var doc = Doctor.init(testing.allocator, testing.io, &cafs, &store);

    // 1. Register a package whose blob is not on disk
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("path", "missing_hash");
    try store.registerPackage("pkg", "sha", "github", "sha256-x", &files);

    // 2. Heal
    try doc.run(); // Executes all healing routines

    // 3. Verify DB eviction for missing physical files
    const stmt1 = try store.db.prepare("SELECT 1 FROM files WHERE hash = 'missing_hash'");
    defer stmt1.deinit();
    const row1 = try stmt1.one(struct { val: i32 }, .{}, .{});
    try testing.expect(row1 == null);

    const stmt2 = try store.db.prepare("SELECT 1 FROM package_files WHERE file_hash = 'missing_hash'");
    defer stmt2.deinit();
    const row2 = try stmt2.one(struct { val: i32 }, .{}, .{});
    try testing.expect(row2 == null);

    // The package itself is evicted too, otherwise it still looks cached and
    // linking fails on the missing blob (audit fix).
    try testing.expect(!try store.hasPackage("pkg", "sha"));
}

test "Doctor: healOrphanedBlobs indexes physical files missing from DB" {
    std.testing.log_level = .err;

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var doc = Doctor.init(testing.allocator, testing.io, &cafs, &store);

    // 1. Seed physical file WITHOUT creating a DB record
    const cwd = std.Io.Dir.cwd();
    const file_path = try testing.allocator.print("{s}/files/orphan_hash", .{tmp_path});
    defer testing.allocator.free(file_path);

    var file = try cwd.createFile(testing.io, file_path, .{});
    try file.writeStreamingAll(testing.io, "orphan data");
    file.close(testing.io);

    // 2. Heal
    try doc.run();

    // 3. Verify DB addition
    const stmt = try store.db.prepare("SELECT size FROM files WHERE hash = 'orphan_hash'");
    defer stmt.deinit();

    const row = try stmt.one(struct { size: i64 }, .{}, .{});
    try testing.expect(row != null);
    try testing.expectEqual(@as(i64, 11), row.?.size); // "orphan data".len == 11
}
