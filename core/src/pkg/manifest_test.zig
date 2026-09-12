const std = @import("std");
const testing = std.testing;
const Manifest = @import("manifest.zig").Manifest;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Manifest: initializes with default values" {
    var manifest = Manifest.init(testing.allocator, "test-project");
    defer manifest.deinit();

    try testing.expectEqualStrings("test-project", manifest.name);
    try testing.expectEqualStrings("0.1.0", manifest.version);
    try testing.expectEqual(@as(usize, 0), manifest.dependencies.count());
}

test "Manifest: saves and loads from VFS correctly" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    const fs = mem_vfs.vfs();

    // 1. Create and save a manifest
    var manifest1 = Manifest.init(testing.allocator, "my-app");
    try manifest1.dependencies.put(try testing.allocator.dupe(u8, "std"), try testing.allocator.dupe(u8, "github.com/kupcad/std"));
    try manifest1.save(fs);
    manifest1.deinit();

    // 2. Load it back from the virtual filesystem
    var manifest2 = try Manifest.load(testing.allocator, fs);
    defer manifest2.deinit();

    // 3. Verify parity
    try testing.expectEqualStrings("my-app", manifest2.name);
    try testing.expectEqualStrings("0.1.0", manifest2.version);

    const dep_url = manifest2.dependencies.get("std") orelse return error.MissingDependency;
    try testing.expectEqualStrings("github.com/kupcad/std", dep_url);
}

test "Manifest: returns ManifestNotFound for missing kupcad.json" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const result = Manifest.load(testing.allocator, mem_vfs.vfs());
    try testing.expectError(error.ManifestNotFound, result);
}
