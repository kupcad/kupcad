const std = @import("std");
const test_support = @import("../test_support.zig");
const testing = std.testing;
const Lockfile = @import("lockfile.zig").Lockfile;
const LockedPackage = @import("lockfile.zig").LockedPackage;
const StringMap = @import("lockfile.zig").StringMap;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Lockfile: initializes empty" {
    var lockfile = Lockfile.init(testing.allocator);
    defer lockfile.deinit();

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

    try testing.expect(std.mem.indexOf(u8, content, "\"version\": \"" ++ @import("lockfile.zig").LOCKFILE_VERSION ++ "\"") != null);
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

    try testing.expectEqual(@as(usize, 0), lockfile.packages.count());
}

test "Lockfile: rejects malformed JSON payloads safely" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("kupcad.lock", "{ broken_json: true ");

    const result = Lockfile.load(testing.allocator, mem_vfs.vfs());
    try testing.expectError(error.UnexpectedToken, result);
}

fn loadVersion(mem_vfs: *MemoryVfs, version: []const u8) !Lockfile {
    const content = try std.fmt.allocPrint(testing.allocator, "{{\"version\":\"{s}\",\"packages\":{{}}}}", .{version});
    defer testing.allocator.free(content);
    try mem_vfs.vfs().writeFile("kupcad.lock", content);
    return Lockfile.load(testing.allocator, mem_vfs.vfs());
}

test "Lockfile: it reads its own major and refuses any other" {
    const warnings = test_support.expectWarnings();
    defer warnings.restore();
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    for ([_][]const u8{ "1.0.0", "1.4.2" }) |version| {
        var lockfile = try loadVersion(&mem_vfs, version);
        lockfile.deinit();
    }
    // Another (or garbled) format fails at load with a clear error, instead of being
    // verified with hashes it didn't take and reported later as an IntegrityMismatch.
    for ([_][]const u8{ "2.0.0", "0.9.0", "not-a-version", "" }) |version| {
        try testing.expectError(error.UnsupportedLockfileVersion, loadVersion(&mem_vfs, version));
    }
    try mem_vfs.vfs().writeFile("kupcad.lock", "{\"packages\":{}}");
    try testing.expectError(error.UnsupportedLockfileVersion, Lockfile.load(testing.allocator, mem_vfs.vfs()));
}

// Audit fix: strings were written unescaped, so a hostile alias or ref could
// inject keys into kupcad.lock.
test "Lockfile: strings are JSON-escaped on save" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    const fs = mem_vfs.vfs();

    const evil_alias = "x\": \"injected\", \"y";
    {
        var lockfile = Lockfile.init(testing.allocator);
        defer lockfile.deinit();
        var deps = StringMap.init(testing.allocator);
        try deps.put(try testing.allocator.dupe(u8, evil_alias), try testing.allocator.dupe(u8, "github.com/a/b"));
        try lockfile.packages.put(try testing.allocator.dupe(u8, "github.com-a-p"), .{
            .resolved = try testing.allocator.dupe(u8, "abc"),
            .ref = try testing.allocator.dupe(u8, "ma\"in"),
            .integrity = try testing.allocator.dupe(u8, "sha256-x"),
            .dependencies = deps,
        });
        try lockfile.save(fs);
    }

    var loaded = try Lockfile.load(testing.allocator, fs);
    defer loaded.deinit();
    const pkg = loaded.packages.get("github.com-a-p").?;
    try testing.expectEqual(@as(usize, 1), pkg.dependencies.count());
    try testing.expect(pkg.dependencies.get(evil_alias) != null);
    try testing.expectEqualStrings("ma\"in", pkg.ref);
}
