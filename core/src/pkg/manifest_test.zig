const std = @import("std");
const testing = std.testing;
const Manifest = @import("manifest.zig").Manifest;
const string_map = @import("string_map.zig");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Manifest: initializes with default values" {
    var manifest = try Manifest.init(testing.allocator, "test-project");
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
    var manifest1 = try Manifest.init(testing.allocator, "my-app");
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

    // Saved with a dependency added: what it doesn't read is kept, where it was
    try manifest.setDependency("std", "github.com/kupcad/std@v1");
    try manifest.save(fs);
    const saved = try fs.readFile(testing.allocator, "kupcad.json");
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings(
        \\{
        \\  "name": "future-app",
        \\  "version": "2.0.0",
        \\  "license": "MIT",
        \\  "authors": [
        \\    "Alice"
        \\  ],
        \\  "dependencies": {
        \\    "std": "github.com/kupcad/std@v1"
        \\  }
        \\}
        \\
    , saved);
}

// Audit fix: hostile manifests used to panic on `.?`/`.object` and unvalidated
// aliases became symlink names under .kupcad/pkg/.
test "Manifest: rejects ill-shaped manifests and unsafe aliases" {
    const cases = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "[]", .err = error.InvalidManifest },
        .{ .json =
        \\{"version":"1.0.0"}
        , .err = error.InvalidManifest },
        .{ .json =
        \\{"name":"a","version":1}
        , .err = error.InvalidManifest },
        .{ .json =
        \\{"name":"a","version":"1.0.0","dependencies":["x"]}
        , .err = error.InvalidManifest },
        .{ .json =
        \\{"name":"a","version":"1.0.0","dependencies":{"x":1}}
        , .err = error.InvalidManifest },
        .{ .json =
        \\{"name":"a","version":"1.0.0","dependencies":{"ok":"github.com/a/b","../evil":"github.com/a/b"}}
        , .err = error.InvalidAlias },
    };
    for (cases) |c| {
        var mem_vfs = MemoryVfs.init(testing.allocator);
        defer mem_vfs.deinit();
        try mem_vfs.vfs().writeFile("kupcad.json", c.json);
        testing.expectError(c.err, Manifest.load(testing.allocator, mem_vfs.vfs())) catch |err| {
            std.debug.print("manifest: {s}\n", .{c.json});
            return err;
        };
    }
}

// Audit fix: strings were written unescaped into kupcad.json.
test "Manifest: strings are JSON-escaped on save" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    const fs = mem_vfs.vfs();
    {
        var m = try Manifest.init(testing.allocator, "n\"ame");
        defer m.deinit();
        try m.dependencies.put(try testing.allocator.dupe(u8, "dep"), try testing.allocator.dupe(u8, "github.com/a/b@v\"1"));
        try m.save(fs);
    }
    var m2 = try Manifest.load(testing.allocator, fs);
    defer m2.deinit();
    try testing.expectEqualStrings("n\"ame", m2.name);
    try testing.expectEqual(@as(usize, 1), m2.dependencies.count());
    try testing.expectEqualStrings("github.com/a/b@v\"1", m2.dependencies.get("dep").?);
}

test "Manifest: setDependency adds an alias or replaces what it named" {
    // `put` with fresh copies leaked the old key and value when the alias existed.
    var manifest = try Manifest.init(testing.allocator, "p");
    defer manifest.deinit();
    try manifest.setDependency("std", "github.com/kupcad/std@v1");
    try manifest.setDependency("std", "github.com/kupcad/std@v2");
    try manifest.setDependency("bolts", "github.com/kupcad/bolts");
    try testing.expectEqual(@as(u32, 2), manifest.dependencies.count());
    try testing.expectEqualStrings("github.com/kupcad/std@v2", manifest.dependencies.get("std").?);
}

test "Manifest: a dependency's manifest gives its dependencies, checked as the project's are" {
    // The resolver parsed a dependency's kupcad.json by hand, a copy of Manifest.load's.
    var deps = try Manifest.parseDependencies(testing.allocator, "{ \"dependencies\": { \"screws\": \"github.com/kupcad/screws@v1\" } }");
    defer string_map.deinitOwned(testing.allocator, &deps);
    try testing.expectEqualStrings("github.com/kupcad/screws@v1", deps.get("screws").?);

    var none = try Manifest.parseDependencies(testing.allocator, "{}");
    defer string_map.deinitOwned(testing.allocator, &none);
    try testing.expectEqual(@as(u32, 0), none.count());

    for ([_][]const u8{ "[]", "{ \"dependencies\": [] }", "{ \"dependencies\": { \"a\": 1 } }", "not json" }) |bad| {
        try testing.expectError(error.InvalidManifest, Manifest.parseDependencies(testing.allocator, bad));
    }
    try testing.expectError(error.InvalidAlias, Manifest.parseDependencies(testing.allocator, "{ \"dependencies\": { \"../escape\": \"x\" } }"));
}
