const std = @import("std");
const testing = std.testing;
const Lockfile = @import("lockfile.zig").Lockfile;
const LockedPackage = @import("lockfile.zig").LockedPackage;
const StringMap = @import("lockfile.zig").StringMap;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "Lockfile: initializes with default version" {
    var lockfile = Lockfile.init(testing.allocator);
    defer lockfile.deinit();

    try testing.expectEqualStrings(@import("lockfile.zig").LOCKFILE_VERSION, lockfile.version);
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

    try testing.expectEqualStrings(@import("lockfile.zig").LOCKFILE_VERSION, lockfile.version);
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

test "Lockfile: integrity scheme follows the major version; unknown majors are rejected" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const known = [_]struct { version: []const u8, legacy: bool }{
        .{ .version = "1.0.0", .legacy = true },
        .{ .version = "1.4.2", .legacy = true },
        .{ .version = "2.0.0", .legacy = false },
        // A minor bump must not flip to the legacy hash (it used to: anything != 2.0.0).
        .{ .version = "2.1.0", .legacy = false },
    };
    for (known) |case| {
        var lockfile = try loadVersion(&mem_vfs, case.version);
        defer lockfile.deinit();
        try testing.expectEqual(case.legacy, try lockfile.usesLegacyIntegrity());
    }

    // A newer (or garbled) format fails at load with a clear error, instead of
    // being verified as 1.x and reported later as an IntegrityMismatch.
    for ([_][]const u8{ "3.0.0", "0.9.0", "not-a-version" }) |version| {
        try testing.expectError(error.UnsupportedLockfileVersion, loadVersion(&mem_vfs, version));
    }
}

test "Lockfile: save upgrades the in-memory version along with the file" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var lockfile = try loadVersion(&mem_vfs, "1.0.0");
    defer lockfile.deinit();
    try testing.expect(try lockfile.usesLegacyIntegrity());

    try lockfile.save(mem_vfs.vfs());
    // A reused lockfile used to keep "1.0.0" and verify the freshly written hashes as legacy.
    try testing.expectEqualStrings(@import("lockfile.zig").LOCKFILE_VERSION, lockfile.version);
    try testing.expect(!try lockfile.usesLegacyIntegrity());
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
