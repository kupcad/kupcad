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

test "GarbageCollector: prune(false) skips files younger than 7 days" {
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

    // 1. Seed physical file (Age is 0 days because it was just created)
    const cwd = std.Io.Dir.cwd();
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/files/fresh_hash", .{tmp_path});
    defer testing.allocator.free(file_path);

    var file = try cwd.createFile(testing.io, file_path, .{});
    try file.writeStreamingAll(testing.io, "fresh data");
    file.close(testing.io);

    // 2. Force Prune with force=false
    try gc.prune(false);

    // 3. Verify physical file was SPARED
    var spared_file = cwd.openFile(testing.io, file_path, .{}) catch return error.ShouldNotHaveBeenDeleted;
    spared_file.close(testing.io);
}

test "GarbageCollector: prune(true) skips files actively linked to projects (nlink > 1)" {
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

    // 1. Seed physical CAFS file
    const cwd = std.Io.Dir.cwd();
    const cafs_file_path = try std.fmt.allocPrint(testing.allocator, "{s}/files/active_hash", .{tmp_path});
    defer testing.allocator.free(cafs_file_path);

    var file = try cwd.createFile(testing.io, cafs_file_path, .{});
    try file.writeStreamingAll(testing.io, "active data");
    file.close(testing.io);

    // 2. Create a physical hardlink simulating an active project using the package
    const project_link_path = try std.fmt.allocPrint(testing.allocator, "{s}/active_hash_link", .{tmp_path});
    defer testing.allocator.free(project_link_path);
    try std.Io.Dir.hardLink(cwd, cafs_file_path, cwd, project_link_path, testing.io, .{});

    // 3. Force Prune! (Force overrides age, but NOT nlink)
    try gc.prune(true);

    // 4. Verify physical file was SPARED because its link count is 2
    var spared_file = cwd.openFile(testing.io, cafs_file_path, .{}) catch return error.ShouldNotHaveBeenDeleted;
    spared_file.close(testing.io);
}
