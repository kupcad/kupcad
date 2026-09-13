const std = @import("std");
const builtin = @import("builtin");
const NativeVfs = @import("native.zig").NativeVfs;
const testing = std.testing;

test "NativeVfs: Sandbox allows safe relative paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    const safe_path = "vfs_test_safe_file.txt";
    try fs.writeFile(safe_path, "safe data");

    const data = try fs.readFile(testing.allocator, safe_path);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("safe data", data);
}

test "NativeVfs: Sandbox allows neutral dot-slash paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    const safe_path = "vfs_test_safe_file_2.txt";
    try fs.writeFile(safe_path, "safe data");

    const data = try fs.readFile(testing.allocator, "./vfs_test_safe_file_2.txt");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("safe data", data);
}

test "NativeVfs: Sandbox rejects absolute paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    const abs_path = if (builtin.os.tag == .windows)
        "C:\\Windows\\System32\\hijack.dll"
    else
        "/etc/passwd";

    const result = fs.readFile(testing.allocator, abs_path);
    try testing.expectError(error.AccessDenied, result);

    const write_result = fs.writeFile(abs_path, "malware");
    try testing.expectError(error.AccessDenied, write_result);
}

test "NativeVfs: Sandbox blocks directory traversal attacks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    const result1 = fs.readFile(testing.allocator, "../secrets.txt");
    try testing.expectError(error.AccessDenied, result1);

    const result2 = fs.writeFile("safe_folder/../../secrets.txt", "hijacked");
    try testing.expectError(error.AccessDenied, result2);
}

test "NativeVfs: Sandbox allows legal directory traversal within bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    const safe_path = "vfs_test_nested_file.txt";
    try fs.makePath("vfs_test_nested_folder");

    // Writing to a sibling/parent directory that is still within the root depth is mathematically safe
    try fs.writeFile("vfs_test_nested_folder/../vfs_test_nested_file.txt", "safe data");

    const data = try fs.readFile(testing.allocator, safe_path);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("safe data", data);
}
