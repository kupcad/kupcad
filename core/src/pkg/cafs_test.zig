const std = @import("std");
const testing = std.testing;
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

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
};

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

test "Cafs: resolvePackage serves cached packages offline and verifies their integrity" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("entry.kup", "hash_entry_999");
    const integrity = try Store.computeIntegrity(testing.allocator, &files);
    defer testing.allocator.free(integrity);
    try store.registerPackage("pkg-cached", "sha-100", "local", integrity, &files);

    // reader = null: no network stream, must come from the store
    for ([_]?[]const u8{ null, integrity }) |expected| {
        var resolved = try fx.cafs.resolvePackage(&store, "pkg-cached", "sha-100", "local", null, expected);
        defer Store.freeFileMap(testing.allocator, &resolved);
        try testing.expectEqualStrings("hash_entry_999", resolved.get("entry.kup").?);
    }

    // A tampered index must not be trusted just because it is local.
    try testing.expectError(error.IntegrityMismatch, fx.cafs.resolvePackage(&store, "pkg-cached", "sha-100", "local", null, "sha256-other"));
}

test "Cafs: resolvePackage returns PackageNotFoundOffline on cache miss when reader is null" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    try testing.expectError(error.PackageNotFoundOffline, fx.cafs.resolvePackage(&store, "non-existent-pkg", "sha-000", "github", null, null));
}

test "Cafs: materializePackage links resolved package files into target VFS directory" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.writeBlob("hash_file_a", "const a = 42;");
    try fx.writeBlob("hash_file_b", "const b = 100;");

    var files_map = std.StringHashMap([]const u8).init(testing.allocator);
    defer files_map.deinit();
    try files_map.put("src/a.kup", "hash_file_a");
    try files_map.put("src/b.kup", "hash_file_b");

    try fx.cafs.materializePackage(&files_map, ".kupcad/pkg/my_pkg");

    const content_a = try fx.mem_vfs.vfs().readFile(testing.allocator, ".kupcad/pkg/my_pkg/src/a.kup");
    defer testing.allocator.free(content_a);
    try testing.expectEqualStrings("const a = 42;", content_a);

    const content_b = try fx.mem_vfs.vfs().readFile(testing.allocator, ".kupcad/pkg/my_pkg/src/b.kup");
    defer testing.allocator.free(content_b);
    try testing.expectEqualStrings("const b = 100;", content_b);
}
