const std = @import("std");
const testing = std.testing;
const Lockfile = @import("lockfile.zig").Lockfile;
const LockedPackage = @import("lockfile.zig").LockedPackage;
const StringMap = @import("lockfile.zig").StringMap;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Lockfile: initializes with default version" {
    var lockfile = Lockfile.init(testing.allocator);
    defer lockfile.deinit();

    try testing.expectEqualStrings("1.0.0", lockfile.version);
    try testing.expectEqual(@as(usize, 0), lockfile.packages.count());
}

test "Lockfile: saves deterministic JSON to VFS" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    const fs = mem_vfs.vfs();

    var lockfile = Lockfile.init(testing.allocator);
    defer lockfile.deinit();

    var deps = StringMap.init(testing.allocator);
    try deps.put(try testing.allocator.dupe(u8, "geom"), try testing.allocator.dupe(u8, "github.com/user/geom"));

    const pkg = LockedPackage{
        .resolved = try testing.allocator.dupe(u8, "abc123def456"),
        .ref = try testing.allocator.dupe(u8, "main"),
        .integrity = try testing.allocator.dupe(u8, "sha256-mockhash123"),
        .dependencies = deps,
    };

    try lockfile.packages.put(try testing.allocator.dupe(u8, "github.com-kupcad-std"), pkg);
    try lockfile.save(fs);

    const content = try fs.readFile(testing.allocator, "kupcad.lock");
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"resolved\": \"abc123def456\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"integrity\": \"sha256-mockhash123\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"github.com-kupcad-std\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"geom\": \"github.com/user/geom\"") != null);
}

test "Lockfile: gracefully handles missing lockfiles by returning empty defaults" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var lockfile = try Lockfile.load(testing.allocator, mem_vfs.vfs());
    defer lockfile.deinit();

    try testing.expectEqualStrings("1.0.0", lockfile.version);
    try testing.expectEqual(@as(usize, 0), lockfile.packages.count());
}

test "Lockfile: rejects malformed JSON payloads safely" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("kupcad.lock", "{ broken_json: true ");

    const result = Lockfile.load(testing.allocator, mem_vfs.vfs());
    try testing.expectError(error.UnexpectedToken, result);
}
