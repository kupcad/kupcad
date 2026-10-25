const std = @import("std");
const testing = std.testing;
const packed_files = @import("packed.zig");
const MemoryVfs = @import("memory.zig").MemoryVfs;

/// The content of the file at `path` in `vfs`, owned by the test's allocator.
fn read(vfs: *MemoryVfs, path: []const u8) ![]u8 {
    return vfs.vfs().readFile(testing.allocator, path);
}

test "packed files: packed and unpacked, each file is where it was, a later one over an earlier" {
    const bytes = try packed_files.pack(testing.allocator, &.{
        .{ .path = "lib.kup", .content = "side = 2\nexport side\n" },
        .{ .path = "data/size.json", .content = "{\"side\": 3}" },
        .{ .path = "empty.txt", .content = "" },
        .{ .path = "lib.kup", .content = "side = 5\n" },
    });
    defer testing.allocator.free(bytes);
    // Each field is its length (4 bytes) then its bytes
    try testing.expectEqual(4 * 8 + "lib.kup".len * 2 + "side = 2\nexport side\n".len + "data/size.json".len + "{\"side\": 3}".len + "empty.txt".len + "side = 5\n".len, bytes.len);
    try testing.expectEqual(@as(u32, "lib.kup".len), std.mem.readInt(u32, bytes[0..4], .little));

    var vfs = MemoryVfs.init(testing.allocator);
    defer vfs.deinit();
    try packed_files.unpack(vfs.vfs(), bytes);
    const lib = try read(&vfs, "lib.kup");
    defer testing.allocator.free(lib);
    try testing.expectEqualStrings("side = 5\n", lib);
    const size = try read(&vfs, "data/size.json");
    defer testing.allocator.free(size);
    try testing.expectEqualStrings("{\"side\": 3}", size);
    const empty = try read(&vfs, "empty.txt");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
    try testing.expectError(error.FileNotFound, read(&vfs, "other.kup"));
}

test "packed files: an empty buffer is no files, and one cut short is refused whole" {
    var vfs = MemoryVfs.init(testing.allocator);
    defer vfs.deinit();
    try packed_files.unpack(vfs.vfs(), "");
    try testing.expectEqual(@as(u32, 0), vfs.nodes.count());

    const whole = try packed_files.pack(testing.allocator, &.{
        .{ .path = "a.kup", .content = "x = 1" },
        .{ .path = "b.kup", .content = "y = 2" },
    });
    defer testing.allocator.free(whole);
    // Cut in a length, after a path, and in a content: each refused, though a whole file
    // came before the cut (the second file's path is 4 + 5 + 4 + 5 + 4 + 5 bytes in)
    for ([_]usize{ 2, 4 + "a.kup".len, 4 + "a.kup".len + 4 + 2, whole.len - 1 }) |cut| {
        try testing.expectError(error.MalformedFiles, packed_files.unpack(vfs.vfs(), whole[0..cut]));
    }
    // A length past the end, however the rest looks
    var lying = try testing.allocator.dupe(u8, whole);
    defer testing.allocator.free(lying);
    std.mem.writeInt(u32, lying[0..4], std.math.maxInt(u32), .little);
    try testing.expectError(error.MalformedFiles, packed_files.unpack(vfs.vfs(), lying));
}
