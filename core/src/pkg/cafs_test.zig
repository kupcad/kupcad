const std = @import("std");
const testing = std.testing;
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Cafs: isolates physical filesystem operations using system temp directories" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    const cwd = std.Io.Dir.cwd();
    const files_dir = try std.fmt.allocPrint(testing.allocator, "{s}/files", .{tmp_path});
    defer testing.allocator.free(files_dir);

    var dir = try cwd.openDir(testing.io, files_dir, .{});
    dir.close(testing.io);
}

test "Cafs: blobPath generates correct absolute paths" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/files/deadbeef", .{tmp_path});
    defer testing.allocator.free(expected);

    const actual = try cafs.blobPath("deadbeef");
    defer testing.allocator.free(actual);

    try testing.expectEqualStrings(expected, actual);
}

test "Cafs: linkBlob falls back to physical read across devices" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    const hash = "112233445566";
    const blob_path = try cafs.blobPath(hash);
    defer testing.allocator.free(blob_path);

    var f = try std.Io.Dir.cwd().createFile(testing.io, blob_path, .{});
    try f.writeStreamingAll(testing.io, "cross device payload");
    f.close(testing.io);

    try cafs.linkBlob(hash, "virtual_file.txt");

    const content = try mem_vfs.vfs().readFile(testing.allocator, "virtual_file.txt");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("cross device payload", content);
}

test "Cafs: extractTarball leverages PID and timestamp for concurrent isolation" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    const cwd = std.Io.Dir.cwd();
    const dummy_tar = try std.fmt.allocPrint(testing.allocator, "{s}/dummy.tar.gz", .{tmp_path});
    defer testing.allocator.free(dummy_tar);

    var f = try cwd.createFile(testing.io, dummy_tar, .{});
    f.close(testing.io);

    var dummy_file = try cwd.openFile(testing.io, dummy_tar, .{});
    defer dummy_file.close(testing.io);

    var buf: [1024]u8 = undefined;
    var file_reader = dummy_file.reader(testing.io, &buf);

    const result = cafs.extractTarball(&file_reader.interface);
    try testing.expectError(error.ReadFailed, result);

    var global_dir = try cwd.openDir(testing.io, tmp_path, .{ .iterate = true });
    defer global_dir.close(testing.io);

    var it = global_dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "tmp_")) {
            return error.OrphanedTempDirFound;
        }
    }
}

test "Store: hasPackage and getPackageFiles correctly query SQLite cache" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    // 1. Verify unregistered package returns false
    try testing.expect(!try store.hasPackage("github.com/kupcad/std", "commit-abc"));

    // 2. Register a mock package
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("lib/main.kup", "hash_main_123");
    try files.put("kupcad.json", "hash_json_456");

    try store.registerPackage("github.com/kupcad/std", "commit-abc", "github", "sha256-mock", &files);

    // 3. Verify store queries
    try testing.expect(try store.hasPackage("github.com/kupcad/std", "commit-abc"));

    var cached_files = (try store.getPackageFiles(testing.allocator, "github.com/kupcad/std", "commit-abc")).?;
    defer {
        var it = cached_files.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        cached_files.deinit();
    }

    try testing.expectEqual(@as(usize, 2), cached_files.count());
    try testing.expectEqualStrings("hash_main_123", cached_files.get("lib/main.kup").?);
    try testing.expectEqualStrings("hash_json_456", cached_files.get("kupcad.json").?);
}

test "Cafs: resolvePackage fast-path short-circuits when package is cached offline" {
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

    // Pre-seed package into store
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("entry.kup", "hash_entry_999");

    try store.registerPackage("pkg-cached", "sha-100", "local", "sha256-cached", &files);

    // Call resolvePackage with `reader = null` (no network stream)
    var resolved_map = try cafs.resolvePackage(&store, "pkg-cached", "sha-100", "local", null);
    defer {
        var it = resolved_map.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        resolved_map.deinit();
    }

    try testing.expectEqualStrings("hash_entry_999", resolved_map.get("entry.kup").?);
}

test "Cafs: resolvePackage returns PackageNotFoundOffline on cache miss when reader is null" {
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

    // Attempting offline resolution without pre-seeding or a network reader must fail cleanly
    const result = cafs.resolvePackage(&store, "non-existent-pkg", "sha-000", "github", null);
    try testing.expectError(error.PackageNotFoundOffline, result);
}

test "Cafs: materializePackage links resolved package files into target VFS directory" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    // 1. Seed blobs in physical CAFS storage
    const hash_a = "hash_file_a";
    const blob_a = try cafs.blobPath(hash_a);
    defer testing.allocator.free(blob_a);
    var fa = try std.Io.Dir.cwd().createFile(testing.io, blob_a, .{});
    try fa.writeStreamingAll(testing.io, "const a = 42;");
    fa.close(testing.io);

    const hash_b = "hash_file_b";
    const blob_b = try cafs.blobPath(hash_b);
    defer testing.allocator.free(blob_b);
    var fb = try std.Io.Dir.cwd().createFile(testing.io, blob_b, .{});
    try fb.writeStreamingAll(testing.io, "const b = 100;");
    fb.close(testing.io);

    // 2. Build files map
    var files_map = std.StringHashMap([]const u8).init(testing.allocator);
    defer files_map.deinit();
    try files_map.put("src/a.kup", hash_a);
    try files_map.put("src/b.kup", hash_b);

    // 3. Materialize to target dir in VFS
    try cafs.materializePackage(&files_map, ".kupcad/pkg/my_pkg");

    // 4. Verify contents in VFS
    const content_a = try mem_vfs.vfs().readFile(testing.allocator, ".kupcad/pkg/my_pkg/src/a.kup");
    defer testing.allocator.free(content_a);
    try testing.expectEqualStrings("const a = 42;", content_a);

    const content_b = try mem_vfs.vfs().readFile(testing.allocator, ".kupcad/pkg/my_pkg/src/b.kup");
    defer testing.allocator.free(content_b);
    try testing.expectEqualStrings("const b = 100;", content_b);
}
