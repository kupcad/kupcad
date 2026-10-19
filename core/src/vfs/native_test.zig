const std = @import("std");
const builtin = @import("builtin");
const NativeVfs = @import("native.zig").NativeVfs;
const testing = std.testing;

test "NativeVfs: Sandbox allows safe relative and dot-slash paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    try fs.writeFile("safe_file.txt", "safe data");

    for ([_][]const u8{ "safe_file.txt", "./safe_file.txt" }) |path| {
        const data = try fs.readFile(testing.allocator, path);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings("safe data", data);
    }
}

test "NativeVfs: Sandbox rejects absolute paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    const abs_path = if (builtin.target.os.tag == .windows)
        "C:\\Windows\\System32\\hijack.dll"
    else
        "/etc/passwd";

    try testing.expectError(error.AccessDenied, fs.readFile(testing.allocator, abs_path));
    try testing.expectError(error.AccessDenied, fs.writeFile(abs_path, "malware"));
}

test "NativeVfs: Sandbox blocks directory traversal attacks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    try testing.expectError(error.AccessDenied, fs.readFile(testing.allocator, "../secrets.txt"));
    try testing.expectError(error.AccessDenied, fs.writeFile("safe_folder/../../secrets.txt", "hijacked"));
}

test "NativeVfs: Sandbox allows legal directory traversal within bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    try fs.makePath("nested_folder");
    try fs.writeFile("nested_folder/../nested_file.txt", "safe data");

    const data = try fs.readFile(testing.allocator, "nested_file.txt");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("safe data", data);
}

// Audit fix: targets were checked against the root instead of the link's directory,
// which rejected every workspace link (`../../../<pkg>`) the resolver creates.
test "NativeVfs: symlink targets are resolved relative to the link" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    const link_dir = ".kupcad/pkg/.store/a-1/.kupcad/pkg";
    try fs.makePath(link_dir);
    try fs.makePath(".kupcad/pkg/.store/b-2/pkg");
    try fs.writeFile(".kupcad/pkg/.store/b-2/pkg/main.kup", "b");

    try fs.symLink("../../../b-2/pkg", link_dir ++ "/b");
    try fs.symLink("../../../b-2/pkg", link_dir ++ "/b"); // idempotent re-link
    const data = try fs.readFile(testing.allocator, link_dir ++ "/b/main.kup");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("b", data);

    // Escapes the root once resolved from the link's directory.
    try testing.expectError(error.AccessDenied, fs.symLink("../../../../../../../etc", link_dir ++ "/c"));
    try testing.expectError(error.AccessDenied, fs.symLink("../x", "top_level_link"));
    try testing.expectError(error.AccessDenied, fs.symLink("/etc", ".kupcad/pkg/d"));
    try testing.expectError(error.AccessDenied, fs.symLink("", ".kupcad/pkg/e"));
}

test "NativeVfs: re-linking replaces stale symlinks but never real files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    const fs = nvfs.vfs();

    try fs.makePath("store/old");
    try fs.makePath("store/new");

    // A re-install pointing at a new commit retargets the existing link.
    try fs.symLink("store/old", "dep");
    try fs.symLink("store/new", "dep");
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.readLink(testing.io, "dep", &buf);
    try testing.expectEqualStrings("store/new", buf[0..n]);

    // A real file at the link path is left untouched.
    try fs.writeFile("user_file", "keep me");
    try testing.expectError(error.PathAlreadyExists, fs.symLink("store/new", "user_file"));
    const data = try fs.readFile(testing.allocator, "user_file");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("keep me", data);
}
