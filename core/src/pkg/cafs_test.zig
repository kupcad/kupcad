const std = @import("std");
const test_support = @import("../test_support.zig");
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
        const archive = try self.extractAs(entries, .flat);
        testing.allocator.free(archive.root);
        return archive.files;
    }

    fn extractAs(self: *Fixture, entries: []const TarEntry, layout: cafs_mod.ArchiveLayout) !cafs_mod.Archive {
        const gz = try helpers.buildTarGz(testing.allocator, entries);
        defer testing.allocator.free(gz);
        var reader: std.Io.Reader = .fixed(gz);
        return self.cafs.extractTarball(&reader, layout);
    }

    fn expectExtractError(self: *Fixture, expected: anyerror, entries: []const TarEntry) !void {
        return self.expectExtractErrorAs(expected, entries, .flat);
    }

    fn expectExtractErrorAs(self: *Fixture, expected: anyerror, entries: []const TarEntry, layout: cafs_mod.ArchiveLayout) !void {
        var archive = self.extractAs(entries, layout) catch |err| return testing.expectEqual(expected, err);
        archive.deinit(testing.allocator);
        return error.TestExpectedError;
    }
};

/// The name a blob of `data` has in the store: its SHA-256, in hex.
fn hashOf(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

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

test "Cafs: init fails where the store's folders can't be made, instead of later" {
    // It warned and went on: the store's database then failed to open, as SqliteOpenFailed
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const under_a_file = try std.fs.path.join(testing.allocator, &.{ root, "file", "store" });
    defer testing.allocator.free(under_a_file);
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try testing.expectError(error.NotDir, Cafs.init(testing.allocator, testing.io, under_a_file, mem_vfs.vfs()));
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

    const hash = hashOf("cross device payload");
    try fx.writeBlob(&hash, "cross device payload");
    try fx.cafs.linkBlob(&hash, "virtual_file.txt");

    const content = try fx.mem_vfs.vfs().readFile(testing.allocator, "virtual_file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("cross device payload", content);
}

// ---------------------------------------------------------------------------
// Archive extraction (audit fixes: untrusted tarballs)
// ---------------------------------------------------------------------------

// A symlink entry followed by a file "through" it used to write outside the package.
test "Cafs: extractTarball does not let a symlink entry plant files outside the package" {
    const warnings = test_support.expectWarnings();
    defer warnings.restore();
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.tmp.dir.createDirPath(testing.io, "victim");
    const victim = try testing.allocator.print("{s}/victim", .{fx.tmp_path});
    defer testing.allocator.free(victim);

    var map = try fx.extract(&.{
        .{ .name = "pkg/link", .kind = .symlink, .link = victim },
        .{ .name = "pkg/link/planted.txt", .data = "pwned!" },
    });
    defer freeMap(&map);

    const planted = try testing.allocator.print("{s}/planted.txt", .{victim});
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
    // Two names one file on a case-insensitive disk (macOS, Windows): the second link
    // replaced the first, though the integrity hash covers both
    try fx.expectExtractError(error.DuplicateArchiveEntry, &.{
        .{ .name = "lib/A.kup", .data = "1" },
        .{ .name = "LIB/a.kup", .data = "2" },
    });
    // A file where another's folder is, either way round: linking failed half-way (NotDir)
    try fx.expectExtractError(error.ArchivePathConflict, &.{
        .{ .name = "a", .data = "1" },
        .{ .name = "a/b.kup", .data = "2" },
    });
    try fx.expectExtractError(error.ArchivePathConflict, &.{
        .{ .name = "A/b/c.kup", .data = "1" },
        .{ .name = "a/B", .data = "2" },
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
    if (fx.cafs.extractTarball(&reader, .flat)) |a| {
        var archive = a;
        archive.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |_| {}

    for ([_][]const u8{ "tmp", "files" }) |sub| {
        const path = try testing.allocator.print("{s}/{s}", .{ fx.tmp_path, sub });
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

    const hash = hashOf("shared");
    const blob = try cafs.blobPath(&hash);
    defer testing.allocator.free(blob);
    try helpers.writeAbs(blob, "shared");

    try fs.makePath("store/pkg");
    try cafs.linkBlob(&hash, "store/pkg/main.kup");
    try cafs.linkBlob(&hash, "store/pkg/main.kup"); // re-install replaces

    const stat = try proj.dir.statFile(testing.io, "store/pkg/main.kup", .{});
    try testing.expect(stat.nlink >= 2);

    // The trusted API refuses relative sources, and destinations stay sandboxed.
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted("../outside", "x"));
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted(blob, "../../escape"));
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted(blob, "/tmp/escape"));
    // linkBlob must not fall back to copying when the sandbox rejects the destination.
    try testing.expectError(error.AccessDenied, cafs.linkBlob(&hash, "../escape"));
}

test "Cafs: a blob that isn't what its name says is linked nowhere" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    // Written through a link into the store, say: its bytes no longer hash to its name
    const hash = hashOf("def plate\n  cube(1)\nend\n");
    try fx.writeBlob(&hash, "def plate\n  cube(1)\nend\nexport_stl(\"/tmp/x\")\n");
    try testing.expectError(error.BlobCorrupted, fx.cafs.linkBlob(&hash, "store/pkg/main.kup"));
    try testing.expectError(error.FileNotFound, fx.mem_vfs.vfs().readFile(testing.allocator, "store/pkg/main.kup"));
    // Put right, it links
    try fx.writeBlob(&hash, "def plate\n  cube(1)\nend\n");
    try fx.cafs.linkBlob(&hash, "store/pkg/main.kup");
    const linked = try fx.mem_vfs.vfs().readFile(testing.allocator, "store/pkg/main.kup");
    defer testing.allocator.free(linked);
    try testing.expectEqualStrings("def plate\n  cube(1)\nend\n", linked);
}

test "Cafs: a wrapped archive's top folder is not part of the package" {
    // GitHub, GitLab and Gitea wrap the repository in `repo-<sha>/`; it was kept, so
    // `import "github.com/u/r"` never found the package's files.
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var archive = try fx.extractAs(&.{
        .{ .name = "parts-0123abc/", .kind = .dir },
        .{ .name = "parts-0123abc/kupcad.json", .data = "{}" },
        .{ .name = "parts-0123abc/lib/bolt.kup", .data = "def bolt() 1 end" },
    }, .wrapped);
    defer archive.deinit(testing.allocator);
    try testing.expectEqualStrings("parts-0123abc", archive.root);
    try testing.expectEqual(@as(u32, 2), archive.files.count());
    try testing.expect(archive.files.contains("kupcad.json"));
    try testing.expect(archive.files.contains("lib/bolt.kup"));

    // An archive named directly is the package as it is.
    var flat = try fx.extractAs(&.{.{ .name = "parts/kupcad.json", .data = "{}" }}, .flat);
    defer flat.deinit(testing.allocator);
    try testing.expect(flat.files.contains("parts/kupcad.json"));
    try testing.expectEqualStrings("", flat.root);
}

test "Cafs: a wrapped archive must have exactly one top folder" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.expectExtractErrorAs(error.UnexpectedArchiveLayout, &.{.{ .name = "README.md", .data = "x" }}, .wrapped);
    try fx.expectExtractErrorAs(error.UnexpectedArchiveLayout, &.{
        .{ .name = "a/kupcad.json", .data = "{}" },
        .{ .name = "b/main.kup", .data = "x" },
    }, .wrapped);
}
