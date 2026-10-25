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

test "NativeVfs: a symlink inside the root that leads out of it is followed nowhere" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest; // a symlink needs a privilege there
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "root/real");
    try tmp.dir.createDirPath(testing.io, "outside");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/secret.txt", .data = "secret" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "root/real/own.txt", .data = "own" });
    // A link the project came with, as the OS resolves it: out of the root, and in it
    try tmp.dir.symLink(testing.io, "../outside", "root/out", .{});
    try tmp.dir.symLink(testing.io, "real", "root/in", .{});
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    var nvfs = NativeVfs.init(testing.io, root);
    const fs = nvfs.vfs();

    // The path is inside as written; what it names isn't
    try testing.expectError(error.AccessDenied, fs.readFile(testing.allocator, "out/secret.txt"));
    try testing.expectError(error.AccessDenied, fs.writeFile("out/new.txt", "x"));
    try testing.expectError(error.AccessDenied, fs.makePath("out/sub/dir"));
    try testing.expectError(error.AccessDenied, fs.symLink("real", "out/link"));
    try testing.expectError(error.AccessDenied, fs.readFile(testing.allocator, "out"));
    try testing.expect(tmp.dir.statFile(testing.io, "outside/new.txt", .{}) == error.FileNotFound);
    // Through the link that stays inside, everything works
    const own = try fs.readFile(testing.allocator, "in/own.txt");
    defer testing.allocator.free(own);
    try testing.expectEqualStrings("own", own);
    try fs.writeFile("in/new.txt", "new");
    const written = try tmp.dir.readFileAlloc(testing.io, "root/real/new.txt", testing.allocator, .limited(16));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("new", written);
}

test "NativeVfs: a symlink to nothing is written through nowhere, and a stale one is made again" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest; // a symlink needs a privilege there
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "root/store/new");
    try tmp.dir.createDirPath(testing.io, "outside");
    // A project's links to what isn't there (yet): a file and a folder outside it, and a
    // package gone from the store
    try tmp.dir.symLink(testing.io, "../outside/model.stl", "root/model.stl", .{});
    try tmp.dir.symLink(testing.io, "../outside/gone", "root/gone", .{});
    try tmp.dir.symLink(testing.io, "store/old", "root/dep", .{});
    var root = try tmp.dir.openDir(testing.io, "root", .{});
    defer root.close(testing.io);
    var nvfs = NativeVfs.init(testing.io, root);
    const fs = nvfs.vfs();

    try testing.expectError(error.AccessDenied, fs.writeFile("model.stl", "solid"));
    try testing.expectError(error.AccessDenied, fs.writeFile("gone/model.stl", "solid"));
    try testing.expectError(error.AccessDenied, fs.makePath("gone/sub"));
    try testing.expectError(error.AccessDenied, fs.readFile(testing.allocator, "model.stl"));
    try testing.expect(tmp.dir.statFile(testing.io, "outside/model.stl", .{}) == error.FileNotFound);
    try testing.expect(tmp.dir.statFile(testing.io, "outside/gone", .{}) == error.FileNotFound);
    // A link is replaced, not written through: the stale one is made again
    try fs.symLink("store/new", "dep");
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try root.readLink(testing.io, "dep", &buf);
    try testing.expectEqualStrings("store/new", buf[0..n]);
}

test "NativeVfs: a file past what a read takes isn't read, nor allocated for" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.stl", .data = "12345" });
    var nvfs = NativeVfs.init(testing.io, tmp.dir);
    nvfs.max_read_bytes = 4;
    const fs = nvfs.vfs();
    try testing.expectError(error.FileTooBig, fs.readFile(testing.allocator, "big.stl"));
    nvfs.max_read_bytes = 5;
    const data = try fs.readFile(testing.allocator, "big.stl");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("12345", data);
}
