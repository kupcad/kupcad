const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const GarbageCollector = @import("gc.zig").GarbageCollector;

test "GarbageCollector: prune(true) removes orphaned files and index records" {
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

    var gc = GarbageCollector.init(testing.allocator, testing.io, &cafs, &store);

    // 1. Seed physical file
    const cwd = std.Io.Dir.cwd();
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/files/stale_hash", .{tmp_path});
    defer testing.allocator.free(file_path);

    var file = try cwd.createFile(testing.io, file_path, .{});
    try file.writeStreamingAll(testing.io, "old data");
    file.close(testing.io);

    // 2. Seed DB record
    try store.db.exec("INSERT INTO files (hash, size, created_at) VALUES ('stale_hash', 8, 0)", .{}, .{});

    // 3. Force Prune
    try gc.prune(true);

    // 4. Verify physical deletion
    const file_opened = cwd.openFile(testing.io, file_path, .{});
    try testing.expectError(error.FileNotFound, file_opened);

    // 5. Verify DB deletion
    const stmt = try store.db.prepare("SELECT 1 FROM files WHERE hash = 'stale_hash'");
    defer stmt.deinit();
    const row = try stmt.one(struct { val: i32 }, .{}, .{});
    try testing.expect(row == null);
}
