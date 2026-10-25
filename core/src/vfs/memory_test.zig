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

test "MemoryVfs: deleteFile removes the file" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    const fs = mem.vfs();

    try fs.writeFile("a.kup", "cube(1)");
    try testing.expect(mem.deleteFile("a.kup"));
    try testing.expect(!mem.deleteFile("a.kup"));
    try testing.expectError(error.FileNotFound, fs.readFile(testing.allocator, "a.kup"));
}

test "MemoryVfs: a link onto an existing path replaces it without leaking" {
    // The old node's content and the new copy of the path were both left behind.
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    const fs = mem.vfs();

    try fs.writeFile("src.kup", "source");
    try fs.writeFile("other.kup", "old");
    try fs.symLink("src.kup", "other.kup");
    try testing.expectEqual(.symlink, mem.nodes.get("other.kup").?.kind);
    try testing.expectEqualStrings("src.kup", mem.nodes.get("other.kup").?.content.?);
    try testing.expectEqual(@as(u32, 2), mem.nodes.count());
}

test "MemoryVfs: node replacement survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var mem = MemoryVfs.init(allocator);
            defer mem.deinit();
            const fs = mem.vfs();
            try fs.writeFile("a.kup", "one");
            try fs.writeFile("a.kup", "two");
            try fs.symLink("a.kup", "b.kup");
        }
    }.run, .{});
}
