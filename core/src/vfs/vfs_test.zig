const std = @import("std");
const testing = std.testing;
const MemoryVfs = @import("memory.zig").MemoryVfs;
const NativeVfs = @import("native.zig").NativeVfs;

test "MemoryVfs: Stores and retrieves files natively in memory" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    const path = "virtual_model.step";
    const mock_content = "ISO-10303-21; HEADER; ENDSEC;";

    try fs.writeFile(path, mock_content);

    const read_content = try fs.readFile(testing.allocator, path);
    defer testing.allocator.free(read_content);

    try testing.expectEqualStrings(mock_content, read_content);
}

test "MemoryVfs: Returns FileNotFound for missing files" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    const result = fs.readFile(testing.allocator, "non_existent.stl");

    try testing.expectError(error.FileNotFound, result);
}

test "MemoryVfs: Properly handles directories and hard links" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();

    try fs.makePath(".kupcad/pkg/.store/test");
    try fs.writeFile("global/source.zig", "pub fn main() void {}");

    // Simulate cache hardlink
    try fs.hardLink("global/source.zig", ".kupcad/pkg/.store/test/source.zig");

    // Ensure the linked file is readable from the new path
    const read_content = try fs.readFile(testing.allocator, ".kupcad/pkg/.store/test/source.zig");
    defer testing.allocator.free(read_content);

    try testing.expectEqualStrings("pub fn main() void {}", read_content);

    // Ensure nlink incremented natively
    const source_node = mem.nodes.get("global/source.zig").?;
    try testing.expectEqual(@as(u32, 2), source_node.nlink);
}

test "NativeVfs: Reads and writes actual files on disk" {
    var native = NativeVfs{ .io = std.testing.io };
    const fs = native.vfs();

    const tmp_path = "test_output_tmp.txt";
    const data = "test data to disk";

    // Write to disk
    try fs.writeFile(tmp_path, data);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {}; // Cleanup

    // Read back
    const read_data = try fs.readFile(testing.allocator, tmp_path);
    defer testing.allocator.free(read_data);

    try testing.expectEqualStrings(data, read_data);
}
