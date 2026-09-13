const std = @import("std");
const testing = std.testing;
const Resolver = @import("resolver.zig").Resolver;
const Manifest = @import("manifest.zig").Manifest;
const lockfile_mod = @import("lockfile.zig");
const Lockfile = lockfile_mod.Lockfile;
const LockedPackage = lockfile_mod.LockedPackage;
const StringMap = lockfile_mod.StringMap;
const Store = @import("store.zig").Store;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Resolver: linkWorkspace builds correct symlink and hardlink trees" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var manifest = Manifest.init(testing.allocator, "test-app");
    defer manifest.deinit();

    var lockfile = Lockfile.init(testing.allocator);
    defer lockfile.deinit();

    // 1. Mock a physical downloaded package file in CAFS
    const hash = "1234567890abcdef";
    const blob_path = try cafs.blobPath(hash);
    defer testing.allocator.free(blob_path);

    var f = try std.Io.Dir.cwd().createFile(testing.io, blob_path, .{});
    try f.writeStreamingAll(testing.io, "def init() 10 end");
    f.close(testing.io);

    // 2. Register the fake package in the SQLite Store
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", hash);
    try store.registerPackage("github.com-user-testpkg", "commit1", "github", "sha256-mock", &files);

    // 3. Register the package constraints in the Lockfile
    const deps = StringMap.init(testing.allocator);
    const locked = LockedPackage{
        .resolved = try testing.allocator.dupe(u8, "commit1"),
        .ref = try testing.allocator.dupe(u8, "main"),
        .integrity = try testing.allocator.dupe(u8, "sha256-mock"),
        .dependencies = deps,
    };
    try lockfile.packages.put(try testing.allocator.dupe(u8, "github.com-user-testpkg"), locked);

    // 4. Inject it into the project Manifest
    try manifest.dependencies.put(try testing.allocator.dupe(u8, "testpkg"), try testing.allocator.dupe(u8, "github.com/user/testpkg"));

    // 5. Execute Linker
    var resolver = Resolver.init(testing.allocator, testing.io, &cafs, &store, &manifest, &lockfile);
    try resolver.linkWorkspace(mem_vfs.vfs());

    // 6. Verify the VFS routed everything accurately into the locked workspace
    const content = try mem_vfs.vfs().readFile(testing.allocator, ".kupcad/pkg/.store/github.com-user-testpkg-commit1/pkg/main.kup");
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("def init() 10 end", content);
}
