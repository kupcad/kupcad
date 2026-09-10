const std = @import("std");
const testing = std.testing;
const Vfs = @import("vfs.zig").Vfs;

test "VFS: MemoryFS correctly stores and retrieves files" {
    var vfs = Vfs.initMemory();
    defer vfs.deinit(testing.allocator);

    const path = "test_model.step";
    const mock_content = "ISO-10303-21; HEADER; ENDSEC;";

    try vfs.putMemoryFile(testing.allocator, path, mock_content);

    const read_content = try vfs.readFile(testing.allocator, testing.io, path);
    defer testing.allocator.free(read_content);

    try testing.expectEqualStrings(mock_content, read_content);
}

test "VFS: MemoryFS returns FileNotFound for missing files" {
    var vfs = Vfs.initMemory();
    defer vfs.deinit(testing.allocator);

    const result = vfs.readFile(testing.allocator, testing.io, "non_existent.stl");
    try testing.expectError(error.FileNotFound, result);
}

test "VFS: MemoryFS writeFile returns ReadOnlyFileSystem" {
    var vfs = Vfs.initMemory();
    defer vfs.deinit(testing.allocator);

    const result = vfs.writeFile(testing.io, "out.stl", "data");
    try testing.expectError(error.ReadOnlyFileSystem, result);
}
