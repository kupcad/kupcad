const std = @import("std");
const testing = std.testing;
const MemoryVfs = @import("memory.zig").MemoryVfs;

test "MemoryVfs: write and read file" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    const path = "model.kup";
    const content = "c = cube(10.0); export c;";

    try fs.writeFile(path, content);

    const read_data = try fs.readFile(testing.allocator, path);
    defer testing.allocator.free(read_data);

    try testing.expectEqualStrings(content, read_data);
}

test "MemoryVfs: overwrite file without leaking memory" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    const path = "model.kup";

    try fs.writeFile(path, "initial content");
    try fs.writeFile(path, "updated content with different length");

    const read_data = try fs.readFile(testing.allocator, path);
    defer testing.allocator.free(read_data);

    try testing.expectEqualStrings("updated content with different length", read_data);
}

test "MemoryVfs: return FileNotFound for unwritten path" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    const result = fs.readFile(testing.allocator, "non_existent.kup");

    try testing.expectError(error.FileNotFound, result);
}

test "MemoryVfs: return AccessDenied when reading directory as file" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    try fs.makePath("dir_node");

    const result = fs.readFile(testing.allocator, "dir_node");
    try testing.expectError(error.AccessDenied, result);
}

test "MemoryVfs: directory creation and duplicate call safety" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    try fs.makePath("workspace/src");
    try fs.makePath("workspace/src"); // Duplicate call should succeed silently

    const node = mem.nodes.get("workspace/src").?;
    try testing.expectEqual(.directory, node.kind);
}

test "MemoryVfs: hardLink increments reference count and shares content" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    const orig_path = "source.kup";
    const link_path = "link.kup";
    const content = "export val = 42;";

    try fs.writeFile(orig_path, content);
    try fs.hardLink(orig_path, link_path);

    const orig_node = mem.nodes.get(orig_path).?;
    const link_node = mem.nodes.get(link_path).?;

    try testing.expectEqual(@as(u32, 2), orig_node.nlink);
    try testing.expectEqual(@as(u32, 2), link_node.nlink);

    const read_link = try fs.readFile(testing.allocator, link_path);
    defer testing.allocator.free(read_link);
    try testing.expectEqualStrings(content, read_link);
}

test "MemoryVfs: symLink stores target path in content" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();

    const fs = mem.vfs();
    const target = "target.kup";
    const sym = "sym.kup";

    try fs.symLink(target, sym);

    const node = mem.nodes.get(sym).?;
    try testing.expectEqual(.symlink, node.kind);
    try testing.expectEqualStrings(target, node.content.?);
}
