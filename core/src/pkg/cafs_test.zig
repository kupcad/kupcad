const std = @import("std");
const testing = std.testing;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Cafs: isolates physical filesystem operations using system temp directories" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Create an OS-managed temporary directory that auto-cleans on scope exit
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Resolve the absolute path to pass into CAFS using the capability-based API
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    const cwd = std.Io.Dir.cwd();
    const files_dir = try std.fmt.allocPrint(testing.allocator, "{s}/files", .{tmp_path});
    defer testing.allocator.free(files_dir);

    // Verify native directory structure was successfully established in /tmp
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

    // 1. Seed a physical file in the OS temp directory
    const hash = "112233445566";
    const blob_path = try cafs.blobPath(hash);
    defer testing.allocator.free(blob_path);

    var f = try std.Io.Dir.cwd().createFile(testing.io, blob_path, .{});
    try f.writeStreamingAll(testing.io, "cross device payload");
    f.close(testing.io);

    // 2. Link it into the in-memory Virtual Filesystem
    try cafs.linkBlob(hash, "virtual_file.txt");

    // 3. Verify it was correctly bridged across the boundary
    const content = try mem_vfs.vfs().readFile(testing.allocator, "virtual_file.txt");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("cross device payload", content);
}
