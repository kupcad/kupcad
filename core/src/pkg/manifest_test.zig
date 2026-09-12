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

test "Manifest: gracefully rejects corrupted JSON files" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    const fs = mem_vfs.vfs();

    // Write a deliberately broken JSON payload (missing quotes and braces)
    const bad_json =
        \\{
        \\  "name": "broken-app,
        \\  "version: 1.0.0
        \\
    ;
    try fs.writeFile("kupcad.json", bad_json);

    // Attempt to load the corrupted manifest
    const result = Manifest.load(testing.allocator, fs);

    // std.json returns SyntaxError for malformed payloads
    try testing.expectError(error.SyntaxError, result);
}

test "Manifest: forward compatibility (ignores unknown JSON fields)" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    const fs = mem_vfs.vfs();

    // JSON payload with unknown future fields (e.g., "license", "authors")
    const future_json =
        \\{
        \\  "name": "future-app",
        \\  "version": "2.0.0",
        \\  "license": "MIT",
        \\  "authors": ["Alice"],
        \\  "dependencies": {}
        \\}
    ;
    try fs.writeFile("kupcad.json", future_json);

    // The parser should safely ignore the extra fields
    var manifest = try Manifest.load(testing.allocator, fs);
    defer manifest.deinit();

    try testing.expectEqualStrings("future-app", manifest.name);
    try testing.expectEqualStrings("2.0.0", manifest.version);
}
