const std = @import("std");
const testing = std.testing;
const Resolver = @import("resolver.zig").Resolver;
const Manifest = @import("manifest.zig").Manifest;
const lockfile_mod = @import("lockfile.zig");
const Lockfile = lockfile_mod.Lockfile;
const StringMap = lockfile_mod.StringMap;
const Store = @import("store.zig").Store;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

const Fixture = struct {
    tmp: testing.TmpDir,
    tmp_path: [:0]u8,
    mem_vfs: MemoryVfs,
    cafs: Cafs,
    store: Store,
    manifest: Manifest,
    lockfile: Lockfile,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.tmp_path = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.tmp_path);
        self.mem_vfs = MemoryVfs.init(testing.allocator);
        errdefer self.mem_vfs.deinit();
        self.cafs = try Cafs.init(testing.allocator, testing.io, self.tmp_path, self.mem_vfs.vfs());
        errdefer self.cafs.deinit();
        self.store = try Store.init(testing.io, ":memory:");
        self.manifest = Manifest.init(testing.allocator, "test-app");
        self.lockfile = Lockfile.init(testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        self.lockfile.deinit();
        self.manifest.deinit();
        self.store.deinit();
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

    /// Records `pkg_id@commit` in the store, lockfile and manifest (as `alias`).
    fn addPackage(self: *Fixture, alias: []const u8, url: []const u8, pkg_id: []const u8, commit: []const u8, files: *std.StringHashMap([]const u8)) !void {
        try self.store.registerPackage(pkg_id, commit, "github", "sha256-mock", files);
        try self.lockfile.packages.put(try testing.allocator.dupe(u8, pkg_id), .{
            .resolved = try testing.allocator.dupe(u8, commit),
            .ref = try testing.allocator.dupe(u8, "main"),
            .integrity = try testing.allocator.dupe(u8, "sha256-mock"),
            .dependencies = StringMap.init(testing.allocator),
        });
        try self.manifest.dependencies.put(try testing.allocator.dupe(u8, alias), try testing.allocator.dupe(u8, url));
    }

    fn link(self: *Fixture) !void {
        var resolver = Resolver.init(testing.allocator, testing.io, &self.cafs, &self.store, &self.manifest, &self.lockfile);
        defer resolver.deinit();
        try resolver.linkWorkspace(self.mem_vfs.vfs());
    }

    fn expectFile(self: *Fixture, path: []const u8, expected: []const u8) !void {
        const content = try self.mem_vfs.vfs().readFile(testing.allocator, path);
        defer testing.allocator.free(content);
        try testing.expectEqualStrings(expected, content);
    }
};

test "Resolver: linkWorkspace links locked packages (flat and nested files) into the store" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.writeBlob("1234567890abcdef", "def init() 10 end");
    try fx.writeBlob("hash1", "mock content");

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", "1234567890abcdef");
    // Several files in one deep directory share the cached directory creation.
    try files.put("src/deep/nested/a.kup", "hash1");
    try files.put("src/deep/nested/b.kup", "hash1");
    try fx.addPackage("testpkg", "github.com/user/testpkg", "github.com-user-testpkg", "commit1", &files);

    try fx.link();

    const store_dir = ".kupcad/pkg/.store/github.com-user-testpkg-commit1/pkg";
    try fx.expectFile(store_dir ++ "/main.kup", "def init() 10 end");
    try fx.expectFile(store_dir ++ "/src/deep/nested/a.kup", "mock content");
    try fx.expectFile(store_dir ++ "/src/deep/nested/b.kup", "mock content");
}

// Lockfile and store values are joined into filesystem paths; a tampered
// kupcad.lock or index must not be able to place files outside the store.
test "Resolver: linkWorkspace rejects unsafe lockfile and index paths" {
    {
        var fx: Fixture = undefined;
        try fx.init();
        defer fx.deinit();
        var files = std.StringHashMap([]const u8).init(testing.allocator);
        defer files.deinit();
        try fx.addPackage("dep", "github.com/user/dep", "github.com-user-dep", "../../../../escape", &files);
        try testing.expectError(error.InvalidPathSegment, fx.link());
    }
    {
        var fx: Fixture = undefined;
        try fx.init();
        defer fx.deinit();
        try fx.writeBlob("h", "x");
        var files = std.StringHashMap([]const u8).init(testing.allocator);
        defer files.deinit();
        try files.put("../../../../../escape.kup", "h");
        try fx.addPackage("dep", "github.com/user/dep", "github.com-user-dep", "commit1", &files);
        try testing.expectError(error.UnsafeArchivePath, fx.link());
    }
    {
        var fx: Fixture = undefined;
        try fx.init();
        defer fx.deinit();
        var files = std.StringHashMap([]const u8).init(testing.allocator);
        defer files.deinit();
        try fx.addPackage("../evil", "github.com/user/dep", "github.com-user-dep", "commit1", &files);
        try testing.expectError(error.InvalidAlias, fx.link());
    }
}
