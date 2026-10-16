const std = @import("std");
const test_support = @import("../test_support.zig");
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
const ParsedPackage = @import("providers/provider.zig").ParsedPackage;
const helpers = @import("test_helpers.zig");
const TarEntry = helpers.TarEntry;

const SAMPLE_PKG = [_]TarEntry{.{ .name = "main.kup", .data = "def f() 1 end" }};
const BOGUS_INTEGRITY = "sha256-0000000000000000000000000000000000000000000000000000000000000000";

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
        self.manifest = try Manifest.init(testing.allocator, "test-app");
        self.lockfile = try Lockfile.init(testing.allocator);
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

    /// Writes a tar.gz into the tmp dir, adds it as dependency `alias` and returns
    /// its package id (caller frees).
    fn addLocalDep(self: *Fixture, alias: []const u8, entries: []const TarEntry) ![]const u8 {
        const gz = try helpers.buildTarGz(testing.allocator, entries);
        defer testing.allocator.free(gz);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.tar.gz", .{ self.tmp_path, alias });
        defer testing.allocator.free(path);
        try helpers.writeAbs(path, gz);

        const spec = try std.fmt.allocPrint(testing.allocator, "file:{s}", .{path});
        errdefer testing.allocator.free(spec);
        const pkg_id = try (try ParsedPackage.parse(spec)).pkgId(testing.allocator);
        errdefer testing.allocator.free(pkg_id);
        const alias_dup = try testing.allocator.dupe(u8, alias);
        errdefer testing.allocator.free(alias_dup);
        try self.manifest.dependencies.put(alias_dup, spec);
        return pkg_id;
    }

    fn resolve(self: *Fixture) !void {
        var resolver = Resolver.init(testing.allocator, testing.io, &self.cafs, &self.store, &self.manifest, &self.lockfile);
        defer resolver.deinit();
        try resolver.resolve();
    }

    /// Forgets every cached package so the next resolve takes the download path.
    fn clearStore(self: *Fixture) !void {
        self.store.deinit();
        self.store = try Store.init(testing.io, ":memory:");
    }

    fn entry(self: *Fixture, pkg_id: []const u8) !*LockedPackage {
        return self.lockfile.packages.getPtr(pkg_id) orelse error.TestExpectedLockEntry;
    }
};

/// Replaces an owned string field (lockfile entries own their strings).
fn setOwned(field: *[]const u8, value: []const u8) !void {
    const dup = try testing.allocator.dupe(u8, value);
    testing.allocator.free(field.*);
    field.* = dup;
}

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

// ---------------------------------------------------------------------------
// resolve: lockfile pinning, integrity, error propagation (audit fixes)
// ---------------------------------------------------------------------------

// Audit fix: install errors were swallowed and the install reported success.
test "Resolver: resolve propagates install errors instead of reporting success" {
    test_support.expectWarnings();
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.manifest.dependencies.put(try testing.allocator.dupe(u8, "missing"), try testing.allocator.dupe(u8, "file:/nonexistent-kupcad-audit/pkg.tar.gz"));
    try testing.expectError(error.FileNotFound, fx.resolve());
}

test "Resolver: resolve verifies cached content against the locked integrity" {
    test_support.expectWarnings();
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const pkg_id = try fx.addLocalDep("dep", &SAMPLE_PKG);
    defer testing.allocator.free(pkg_id);

    try fx.resolve();
    const e = try fx.entry(pkg_id);
    try testing.expect(std.mem.startsWith(u8, e.integrity, "sha256-"));
    try testing.expect(try fx.store.hasPackage(pkg_id, e.resolved));

    // Re-install against the same lockfile verifies and succeeds
    try fx.resolve();

    try setOwned(&(try fx.entry(pkg_id)).integrity, BOGUS_INTEGRITY);
    try testing.expectError(error.IntegrityMismatch, fx.resolve());
}

test "Resolver: downloads honor the locked commit and integrity" {
    test_support.expectWarnings();
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const pkg_id = try fx.addLocalDep("dep", &SAMPLE_PKG);
    defer testing.allocator.free(pkg_id);
    try fx.resolve();

    // Pinned commit + matching integrity, nothing cached: content is fetched and
    // recorded under the pinned commit, not a freshly derived one.
    const pinned = "0123456789abcdef0123456789abcdef01234567";
    try setOwned(&(try fx.entry(pkg_id)).resolved, pinned);
    try fx.clearStore();
    try fx.resolve();
    try testing.expectEqualStrings(pinned, (try fx.entry(pkg_id)).resolved);
    try testing.expect(try fx.store.hasPackage(pkg_id, pinned));

    // Mismatching download is rejected and never registered in the store.
    try setOwned(&(try fx.entry(pkg_id)).integrity, BOGUS_INTEGRITY);
    try fx.clearStore();
    try testing.expectError(error.IntegrityMismatch, fx.resolve());
    try testing.expect(!try fx.store.hasPackage(pkg_id, pinned));
}

test "Resolver: lock entries without integrity are refused" {
    test_support.expectWarnings();
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const pkg_id = try fx.addLocalDep("dep", &SAMPLE_PKG);
    defer testing.allocator.free(pkg_id);
    try fx.resolve();

    try setOwned(&(try fx.entry(pkg_id)).integrity, "");
    try testing.expectError(error.LockfileMissingIntegrity, fx.resolve());
}

test "Resolver: a pin for a different ref is re-resolved, stale entries dropped" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const pkg_id = try fx.addLocalDep("dep", &SAMPLE_PKG);
    defer testing.allocator.free(pkg_id);
    try fx.resolve();
    const good_integrity = try testing.allocator.dupe(u8, (try fx.entry(pkg_id)).integrity);
    defer testing.allocator.free(good_integrity);

    // The ref changed in kupcad.json (local deps have ref ""), so the old pin
    // (with its now-irrelevant integrity) must not be enforced.
    const e = try fx.entry(pkg_id);
    try setOwned(&e.ref, "v9");
    try setOwned(&e.integrity, BOGUS_INTEGRITY);

    // A package no longer in the dependency graph.
    try fx.lockfile.packages.put(try testing.allocator.dupe(u8, "github.com-gone-pkg"), .{
        .resolved = try testing.allocator.dupe(u8, "abc"),
        .ref = try testing.allocator.dupe(u8, "main"),
        .integrity = try testing.allocator.dupe(u8, BOGUS_INTEGRITY),
        .dependencies = StringMap.init(testing.allocator),
    });

    try fx.resolve();
    const fresh = try fx.entry(pkg_id);
    try testing.expectEqualStrings("", fresh.ref);
    try testing.expectEqualStrings(good_integrity, fresh.integrity);
    try testing.expect(fx.lockfile.packages.get("github.com-gone-pkg") == null);
}

test "Resolver: 1.x lockfiles verify with the legacy hash and are rewritten as current" {
    test_support.expectWarnings();
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const pkg_id = try fx.addLocalDep("dep", &SAMPLE_PKG);
    defer testing.allocator.free(pkg_id);
    try fx.resolve();

    const current = try testing.allocator.dupe(u8, (try fx.entry(pkg_id)).integrity);
    defer testing.allocator.free(current);
    const legacy = blk: {
        var files = (try fx.store.getPackageFiles(testing.allocator, pkg_id, (try fx.entry(pkg_id)).resolved)).?;
        defer helpers.freeMap(&files);
        break :blk try Store.computeIntegrityWith(testing.allocator, &files, .{ .algo = .legacy });
    };
    defer testing.allocator.free(legacy);
    try testing.expect(!std.mem.eql(u8, current, legacy));

    try setOwned(&fx.lockfile.version, "1.0.0");
    try testing.expect((try fx.lockfile.format()).legacy_hash);

    // A 1.x lockfile is checked with the 1.x algorithm, not the current one.
    try testing.expectError(error.IntegrityMismatch, fx.resolve());

    try setOwned(&(try fx.entry(pkg_id)).integrity, legacy);
    try fx.resolve();
    try testing.expectEqualStrings(current, (try fx.entry(pkg_id)).integrity);

    // Saving upgrades the format so the next install uses the current algorithm.
    const fs = fx.mem_vfs.vfs();
    try fx.lockfile.save(fs);
    var reloaded = try Lockfile.load(testing.allocator, fs);
    defer reloaded.deinit();
    try testing.expectEqualStrings(lockfile_mod.LOCKFILE_VERSION, reloaded.version);
    try testing.expect(!(try reloaded.format()).legacy_hash);
    try testing.expectEqualStrings(current, reloaded.packages.get(pkg_id).?.integrity);

    // The in-memory lockfile now holds current hashes, so reusing it (without reloading)
    // must verify with the current algorithm too; it used to stay 1.0.0 and mismatch.
    try testing.expectEqualStrings(lockfile_mod.LOCKFILE_VERSION, fx.lockfile.version);
    try fx.resolve();
}

test "Resolver: forbidden or malformed transitive deps fail the install" {
    test_support.expectWarnings();
    const cases = [_]struct { manifest: []const u8, err: anyerror }{
        .{ .manifest =
        \\{"dependencies":{"x":"file:/etc/passwd"}}
        , .err = error.ForbiddenTransitiveDependency },
        .{ .manifest =
        \\{"dependencies":{"x":"gitea:127.0.0.1/u/r"}}
        , .err = error.ForbiddenTransitiveDependency },
        .{ .manifest =
        \\{"dependencies":{"x":"127.0.0.1/u/r"}}
        , .err = error.UnknownPackageHost },
        // Alias from an untrusted kupcad.json is used as a symlink name
        .{ .manifest =
        \\{"dependencies":{"../../../../evil":"github.com/a/b"}}
        , .err = error.InvalidAlias },
        // Malformed manifests used to be skipped silently (install "succeeded")
        .{ .manifest =
        \\{"dependencies":["github.com/a/b"]}
        , .err = error.InvalidManifest },
        .{ .manifest =
        \\{"dependencies":{"x":1}}
        , .err = error.InvalidManifest },
        .{ .manifest = "not json", .err = error.InvalidManifest },
    };
    for (cases) |c| {
        var fx: Fixture = undefined;
        try fx.init();
        defer fx.deinit();
        const pkg_id = try fx.addLocalDep("p", &.{.{ .name = "kupcad.json", .data = c.manifest }});
        defer testing.allocator.free(pkg_id);
        testing.expectError(c.err, fx.resolve()) catch |err| {
            std.debug.print("transitive manifest: {s}\n", .{c.manifest});
            return err;
        };
    }
}

test "Resolver: an invalid alias fails before any package is fetched" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.manifest.dependencies.put(try testing.allocator.dupe(u8, "-bad"), try testing.allocator.dupe(u8, "github.com/u/r"));
    // Valid ones until one comes before "-bad" in iteration order, which the old code
    // would have spawned before reaching the invalid alias.
    var ids: [16][]const u8 = undefined;
    var count: usize = 0;
    defer for (ids[0..count]) |id| testing.allocator.free(id);
    while (count < ids.len) {
        var name_buf: [16]u8 = undefined;
        ids[count] = try fx.addLocalDep(try std.fmt.bufPrint(&name_buf, "good{d}", .{count}), &SAMPLE_PKG);
        count += 1;
        var it = fx.manifest.dependencies.keyIterator();
        if (!std.mem.eql(u8, it.next().?.*, "-bad")) break;
    } else return error.TestSetupFailed;

    var resolver = Resolver.init(testing.allocator, testing.io, &fx.cafs, &fx.store, &fx.manifest, &fx.lockfile);
    defer resolver.deinit();
    // It used to validate while spawning, returning with "good"'s worker still running
    // on a resolver about to be freed.
    try testing.expectError(error.InvalidAlias, resolver.resolve());
    try testing.expectEqual(@as(u32, 0), resolver.visited.count());
    try testing.expectEqual(@as(u32, 0), fx.lockfile.packages.count());
}
