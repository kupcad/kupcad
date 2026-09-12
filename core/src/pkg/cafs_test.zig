const std = @import("std");
const testing = std.testing;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Cafs: initializes and creates capability-based global directories" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const global_dir = "test_cafs_init";
    defer std.Io.Dir.cwd().deleteTree(testing.io, global_dir) catch {};

    var cafs = try Cafs.init(testing.allocator, testing.io, global_dir, mem_vfs.vfs());
    defer cafs.deinit();

    // Verify directories were created natively
    const cwd = std.Io.Dir.cwd();
    const files_dir = try std.fmt.allocPrint(testing.allocator, "{s}/files", .{global_dir});
    defer testing.allocator.free(files_dir);

    var dir = try cwd.openDir(testing.io, files_dir, .{});
    dir.close(testing.io); // If openDir succeeds, the path exists
}

test "Cafs: securely links blobs from physical CAFS into virtual project space" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const global_dir = "test_cafs_link";
    defer std.Io.Dir.cwd().deleteTree(testing.io, global_dir) catch {};

    var cafs = try Cafs.init(testing.allocator, testing.io, global_dir, mem_vfs.vfs());
    defer cafs.deinit();

    const fs = mem_vfs.vfs();
    const mock_hash = "deadbeef";

    // Seed physical CAFS with mock blob using std.Io
    const files_dir_path = try std.fmt.allocPrint(testing.allocator, "{s}/files/{s}", .{ global_dir, mock_hash });
    defer testing.allocator.free(files_dir_path);

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(testing.io, files_dir_path, .{});

    // Use writeStreamingAll instead of writeAll
    try file.writeStreamingAll(testing.io, "mock blob content");

    file.close(testing.io);

    // Link into VFS project space
    const dest_path = "project/.kupcad/deps/deadbeef.kup";
    try fs.makePath("project/.kupcad/deps");
    try cafs.linkBlob(mock_hash, dest_path);

    // Verify VFS resolves the hardlink fallback properly
    const read_content = try fs.readFile(testing.allocator, dest_path);
    defer testing.allocator.free(read_content);

    try testing.expectEqualStrings("mock blob content", read_content);
}
