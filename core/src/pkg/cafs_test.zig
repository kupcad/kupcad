const std = @import("std");
const testing = std.testing;
const cafs_mod = @import("cafs.zig");
const Cafs = cafs_mod.Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const helpers = @import("test_helpers.zig");
const TarEntry = helpers.TarEntry;
const freeMap = helpers.freeMap;

/// CAFS rooted in a fresh tmp dir, linking into an in-memory project VFS.
const Fixture = struct {
    tmp: testing.TmpDir,
    tmp_path: [:0]u8,
    mem_vfs: MemoryVfs,
    cafs: Cafs,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.tmp_path = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.tmp_path);
        self.mem_vfs = MemoryVfs.init(testing.allocator);
        errdefer self.mem_vfs.deinit();
        self.cafs = try Cafs.init(testing.allocator, testing.io, self.tmp_path, self.mem_vfs.vfs());
    }

    fn deinit(self: *Fixture) void {
        self.cafs.deinit();
        self.mem_vfs.deinit();
        testing.allocator.free(self.tmp_path);
        self.tmp.cleanup();
    }

    fn writeBlob(self: *Fixture, hash: []const u8, data: []const u8) !void {
        const path = try self.cafs.blobPath(hash);
        defer testing.allocator.free(path);
        var f = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, data);
    }

    fn extract(self: *Fixture, entries: []const TarEntry) !std.StringHashMap([]const u8) {
        const gz = try helpers.buildTarGz(testing.allocator, entries);
        defer testing.allocator.free(gz);
        var reader: std.Io.Reader = .fixed(gz);
        return self.cafs.extractTarball(&reader);
    }

    fn expectExtractError(self: *Fixture, expected: anyerror, entries: []const TarEntry) !void {
        var map = self.extract(entries) catch |err| return testing.expectEqual(expected, err);
        freeMap(&map);
        return error.TestExpectedError;
    }
};

fn existsAbs(path: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

test "Cafs: init creates the blob directory under the global dir" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var dir = try fx.tmp.dir.openDir(testing.io, "files", .{});
    dir.close(testing.io);
}

test "Cafs: blobPath generates correct absolute paths" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const expected = try testing.allocator.print("{s}/files/deadbeef", .{fx.tmp_path});
    defer testing.allocator.free(expected);
    const actual = try fx.cafs.blobPath("deadbeef");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "Cafs: linkBlob copies when the VFS cannot hard-link" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.writeBlob("112233445566", "cross device payload");
    try fx.cafs.linkBlob("112233445566", "virtual_file.txt");

    const content = try fx.mem_vfs.vfs().readFile(testing.allocator, "virtual_file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("cross device payload", content);
}

// ---------------------------------------------------------------------------
// Archive extraction (audit fixes: untrusted tarballs)
// ---------------------------------------------------------------------------

// A symlink entry followed by a file "through" it used to write outside the package.
test "Cafs: extractTarball does not let a symlink entry plant files outside the package" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.tmp.dir.createDirPath(testing.io, "victim");
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{fx.tmp_path});
    defer testing.allocator.free(victim);

    var map = try fx.extract(&.{
        .{ .name = "pkg/link", .kind = .symlink, .link = victim },
        .{ .name = "pkg/link/planted.txt", .data = "pwned!" },
    });
    defer freeMap(&map);

    const planted = try std.fmt.allocPrint(testing.allocator, "{s}/planted.txt", .{victim});
    defer testing.allocator.free(planted);
    try testing.expect(!existsAbs(planted));
    try testing.expect(map.get("pkg/link") == null);
}

test "Cafs: sanitizeEntryPath rejects escaping and non-portable names" {
    var buf: [256]u8 = undefined;
    const rejected = [_][]const u8{
        "",     "/etc/passwd", "//x",  "../escape.txt", "a/../../b",
        "a/..", "a\\..\\b",    "C:/x", "a/b:stream",    "a\x00b",
        ".",    "./",
    };
    for (rejected) |name| {
        testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&buf, name)) catch |err| {
            std.debug.print("accepted unsafe entry name: \"{f}\"\n", .{std.zig.fmtString(name)});
            return err;
        };
    }

    const normalized = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "pkg/main.kup", .out = "pkg/main.kup" },
        .{ .in = "./a//b", .out = "a/b" },
        .{ .in = "a/./b/", .out = "a/b" },
    };
    for (normalized) |c| try testing.expectEqualStrings(c.out, try cafs_mod.sanitizeEntryPath(&buf, c.in));

    // Names that don't fit the output buffer are rejected, not truncated.
    var small: [4]u8 = undefined;
    try testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&small, "abcde"));
    try testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&small, "ab/cd"));
}

test "Cafs: extractTarball rejects escaping and duplicate entries" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.expectExtractError(error.UnsafeArchivePath, &.{.{ .name = "../escape.txt", .data = "x" }});
    // A later duplicate (after normalization) would silently replace verified content.
    try fx.expectExtractError(error.DuplicateArchiveEntry, &.{
        .{ .name = "a.kup", .data = "1" },
        .{ .name = "./a.kup", .data = "2" },
    });
}

// Decompression bombs used to be extracted without bound.
test "Cafs: extractTarball enforces decompressed size and file count limits" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const big: [4096]u8 = @splat('A');

    fx.cafs.extract_limits = .{ .max_total_bytes = big.len };
    {
        var map = try fx.extract(&.{.{ .name = "exact.bin", .data = &big }});
        freeMap(&map);
    }
    fx.cafs.extract_limits = .{ .max_total_bytes = big.len - 1 };
    try fx.expectExtractError(error.ArchiveTooLarge, &.{.{ .name = "bomb.bin", .data = &big }});

    const three = [_]TarEntry{ .{ .name = "a", .data = "1" }, .{ .name = "b", .data = "2" }, .{ .name = "c", .data = "3" } };
    fx.cafs.extract_limits = .{ .max_file_count = three.len };
    {
        var map = try fx.extract(&three);
        freeMap(&map);
    }
    fx.cafs.extract_limits = .{ .max_file_count = three.len - 1 };
    try fx.expectExtractError(error.ArchiveTooManyFiles, &three);
}

test "Cafs: failed extraction leaves no partial blobs or temp files" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const payload: [4096]u8 = @splat('B');
    const gz = try helpers.buildTarGz(testing.allocator, &.{.{ .name = "big.bin", .data = &payload }});
    defer testing.allocator.free(gz);

    // Cut the stream in the middle of the file body.
    var reader: std.Io.Reader = .fixed(gz[0 .. gz.len / 2]);
    if (fx.cafs.extractTarball(&reader)) |m| {
        var map = m;
        freeMap(&map);
        return error.TestExpectedError;
    } else |_| {}

    for ([_][]const u8{ "tmp", "files" }) |sub| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ fx.tmp_path, sub });
        defer testing.allocator.free(path);
        var dir = try std.Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        if (try it.next(testing.io)) |entry| {
            std.debug.print("leftover in cafs/{s}: {s}\n", .{ sub, entry.name });
            return error.TestUnexpectedLeftover;
        }
    }
}

// ---------------------------------------------------------------------------
// Linking into a NativeVfs sandbox
// ---------------------------------------------------------------------------

// Real installs failed with AccessDenied: the sandbox rejected the absolute blob source.
test "Cafs: linkBlob hard-links blobs into a NativeVfs sandbox" {
    var proj = testing.tmpDir(.{});
    defer proj.cleanup();
    var global = testing.tmpDir(.{});
    defer global.cleanup();
    const global_path = try global.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(global_path);

    var native = NativeVfs.init(testing.io, proj.dir);
    const fs = native.vfs();
    var cafs = try Cafs.init(testing.allocator, testing.io, global_path, fs);
    defer cafs.deinit();

    const blob = try cafs.blobPath("cafe");
    defer testing.allocator.free(blob);
    try helpers.writeAbs(blob, "shared");

    try fs.makePath("store/pkg");
    try cafs.linkBlob("cafe", "store/pkg/main.kup");
    try cafs.linkBlob("cafe", "store/pkg/main.kup"); // re-install replaces

    const stat = try proj.dir.statFile(testing.io, "store/pkg/main.kup", .{});
    try testing.expect(stat.nlink >= 2);

    // The trusted API refuses relative sources, and destinations stay sandboxed.
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted("../outside", "x"));
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted(blob, "../../escape"));
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted(blob, "/tmp/escape"));
    // linkBlob must not fall back to copying when the sandbox rejects the destination.
    try testing.expectError(error.AccessDenied, cafs.linkBlob("cafe", "../escape"));
}
