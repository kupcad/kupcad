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
