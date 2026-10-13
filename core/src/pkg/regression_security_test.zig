//! Regression tests for issues found in the Oct 2026 audit.
//! Package manager: archive extraction, lockfile pinning/integrity, provider
//! validation, store/GC consistency, CAFS links. No network access.

const std = @import("std");
const testing = std.testing;

const cafs_mod = @import("cafs.zig");
const Cafs = cafs_mod.Cafs;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const GC = @import("gc.zig").GarbageCollector;
const Doctor = @import("health.zig").Doctor;
const Manifest = @import("manifest.zig").Manifest;
const lockfile_mod = @import("lockfile.zig");
const Lockfile = lockfile_mod.Lockfile;
const LockedPackage = lockfile_mod.LockedPackage;
const StringMap = lockfile_mod.StringMap;
const Resolver = @import("resolver.zig").Resolver;
const ParsedPackage = @import("providers/provider.zig").ParsedPackage;
const validate = @import("validate.zig");
const limits = @import("limits.zig");
const sqlite = @import("sqlite");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;

// ---------------------------------------------------------------------------
// In-memory tar / gzip builders (hand-rolled ustar + stored-deflate gzip)
// ---------------------------------------------------------------------------

const TarEntry = struct {
    name: []const u8,
    kind: enum { file, symlink, dir } = .file,
    data: []const u8 = "",
    link: []const u8 = "",
};

fn writeOctal(field: []u8, value: u64) void {
    // N-1 octal digits followed by NUL
    _ = std.fmt.bufPrint(field[0 .. field.len - 1], "{o:0>[1]}", .{ value, field.len - 1 }) catch unreachable;
    field[field.len - 1] = 0;
}

fn buildTar(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (entries) |e| {
        var h: [512]u8 = @splat(0);
        @memcpy(h[0..e.name.len], e.name);
        writeOctal(h[100..108], if (e.kind == .dir) 0o755 else 0o644);
        writeOctal(h[108..116], 0);
        writeOctal(h[116..124], 0);
        writeOctal(h[124..136], e.data.len);
        writeOctal(h[136..148], 0);
        h[156] = switch (e.kind) {
            .file => '0',
            .symlink => '2',
            .dir => '5',
        };
        @memcpy(h[157..][0..e.link.len], e.link);
        @memcpy(h[257..263], "ustar\x00");
        @memcpy(h[263..265], "00");
        @memset(h[148..156], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        _ = std.fmt.bufPrint(h[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
        try out.appendSlice(allocator, &h);
        try out.appendSlice(allocator, e.data);
        const pad = (512 - e.data.len % 512) % 512;
        try out.appendNTimes(allocator, 0, pad);
    }
    try out.appendNTimes(allocator, 0, 1024);
    return out.toOwnedSlice(allocator);
}

/// gzip container with uncompressed ("stored") deflate blocks.
fn gzipStored(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff });
    var off: usize = 0;
    while (true) {
        const n = @min(data.len - off, 65535);
        const final = off + n == data.len;
        try out.append(allocator, if (final) 1 else 0);
        const len: u16 = @intCast(n);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
        try out.appendSlice(allocator, data[off..][0..n]);
        off += n;
        if (final) break;
    }
    const crc = std.hash.Crc32.hash(data);
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, crc)));
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @truncate(data.len)))));
    return out.toOwnedSlice(allocator);
}

fn buildTarGz(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    const tar = try buildTar(allocator, entries);
    defer allocator.free(tar);
    return gzipStored(allocator, tar);
}

fn freeMap(map: *std.StringHashMap([]const u8)) void {
    Store.freeFileMap(testing.allocator, map);
}

fn tmpAbsPath(tmp: *testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
}

fn writeAbs(path: []const u8, data: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, data);
}

fn existsAbs(path: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

fn countRows(store: *Store, sql: []const u8) !i64 {
    const stmt = try store.db.prepare(sql);
    defer stmt.deinit();
    return (try stmt.one(struct { n: i64 }, .{}, .{})).?.n;
}

/// Replaces an owned string field (lockfile entries own their strings).
fn setOwned(field: *[]const u8, value: []const u8) !void {
    const dup = try testing.allocator.dupe(u8, value);
    testing.allocator.free(field.*);
    field.* = dup;
}

/// tmp dir + CAFS backed by a MemoryVfs project; the base for most tests here.
const CafsFixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    mem_vfs: MemoryVfs,
    cafs: Cafs,

    fn init(self: *CafsFixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root = try tmpAbsPath(&self.tmp);
        errdefer testing.allocator.free(self.root);
        self.mem_vfs = MemoryVfs.init(testing.allocator);
        errdefer self.mem_vfs.deinit();
        const cafs_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cafs", .{self.root});
        defer testing.allocator.free(cafs_dir);
        self.cafs = try Cafs.init(testing.allocator, testing.io, cafs_dir, self.mem_vfs.vfs());
    }

    fn deinit(self: *CafsFixture) void {
        self.cafs.deinit();
        self.mem_vfs.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn extract(self: *CafsFixture, entries: []const TarEntry) !std.StringHashMap([]const u8) {
        const gz = try buildTarGz(testing.allocator, entries);
        defer testing.allocator.free(gz);
        var reader: std.Io.Reader = .fixed(gz);
        return self.cafs.extractTarball(&reader);
    }

    fn expectExtractError(self: *CafsFixture, expected: anyerror, entries: []const TarEntry) !void {
        var map = self.extract(entries) catch |err| return testing.expectEqual(expected, err);
        freeMap(&map);
        return error.TestExpectedError;
    }

    fn writeBlob(self: *CafsFixture, hash: []const u8, data: []const u8) !void {
        const path = try self.cafs.blobPath(hash);
        defer testing.allocator.free(path);
        try writeAbs(path, data);
    }
};

// ---------------------------------------------------------------------------
// Archive extraction
// ---------------------------------------------------------------------------

test "pkg security: tarball symlink entry cannot plant files outside the package" {
    var fx: CafsFixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.tmp.dir.createDirPath(testing.io, "victim");
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{fx.root});
    defer testing.allocator.free(victim);

    var map = try fx.extract(&.{
        .{ .name = "pkg/link", .kind = .symlink, .link = victim },
        .{ .name = "pkg/link/planted.txt", .data = "pwned!" },
    });
    defer freeMap(&map);

    const planted = try std.fmt.allocPrint(testing.allocator, "{s}/planted.txt", .{victim});
    defer testing.allocator.free(planted);
    try testing.expect(!existsAbs(planted));
    try testing.expect(map.get("pkg/link") == null);
}

test "pkg security: sanitizeEntryPath rejects escaping and non-portable names" {
    var buf: [256]u8 = undefined;
    const rejected = [_][]const u8{
        "",     "/etc/passwd", "//x",  "../escape.txt", "a/../../b",
        "a/..", "a\\..\\b",    "C:/x", "a/b:stream",    "a\x00b",
        ".",    "./",
    };
    for (rejected) |name| {
        testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&buf, name)) catch |err| {
            std.debug.print("accepted unsafe entry name: \"{f}\"\n", .{std.zig.fmtString(name)});
            return err;
        };
    }

    const normalized = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "pkg/main.kup", .out = "pkg/main.kup" },
        .{ .in = "./a//b", .out = "a/b" },
        .{ .in = "a/./b/", .out = "a/b" },
    };
    for (normalized) |c| try testing.expectEqualStrings(c.out, try cafs_mod.sanitizeEntryPath(&buf, c.in));

    // Names that don't fit the output buffer are rejected, not truncated.
    var small: [4]u8 = undefined;
    try testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&small, "abcde"));
    try testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&small, "ab/cd"));
}

test "pkg security: extractTarball rejects escaping and duplicate entries" {
    var fx: CafsFixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.expectExtractError(error.UnsafeArchivePath, &.{.{ .name = "../escape.txt", .data = "x" }});
    // A later duplicate (after normalization) would silently replace verified content.
    try fx.expectExtractError(error.DuplicateArchiveEntry, &.{
        .{ .name = "a.kup", .data = "1" },
        .{ .name = "./a.kup", .data = "2" },
    });
}

test "pkg security: extraction enforces decompressed size and file count limits" {
    var fx: CafsFixture = undefined;
    try fx.init();
    defer fx.deinit();

    const big: [4096]u8 = @splat('A');

    fx.cafs.extract_limits = .{ .max_total_bytes = big.len };
    {
        var map = try fx.extract(&.{.{ .name = "exact.bin", .data = &big }});
        freeMap(&map);
    }
    fx.cafs.extract_limits = .{ .max_total_bytes = big.len - 1 };
    try fx.expectExtractError(error.ArchiveTooLarge, &.{.{ .name = "bomb.bin", .data = &big }});

    const three = [_]TarEntry{ .{ .name = "a", .data = "1" }, .{ .name = "b", .data = "2" }, .{ .name = "c", .data = "3" } };
    fx.cafs.extract_limits = .{ .max_file_count = three.len };
    {
        var map = try fx.extract(&three);
        freeMap(&map);
    }
    fx.cafs.extract_limits = .{ .max_file_count = three.len - 1 };
    try fx.expectExtractError(error.ArchiveTooManyFiles, &three);
}

test "pkg security: failed extraction leaves no partial blobs or temp files" {
    var fx: CafsFixture = undefined;
    try fx.init();
    defer fx.deinit();

    const payload: [4096]u8 = @splat('B');
    const gz = try buildTarGz(testing.allocator, &.{.{ .name = "big.bin", .data = &payload }});
    defer testing.allocator.free(gz);

    // Cut the stream in the middle of the file body.
    var reader: std.Io.Reader = .fixed(gz[0 .. gz.len / 2]);
    if (fx.cafs.extractTarball(&reader)) |m| {
        var map = m;
        freeMap(&map);
        return error.TestExpectedError;
    } else |_| {}

    for ([_][]const u8{ "tmp", "files" }) |sub| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/cafs/{s}", .{ fx.root, sub });
        defer testing.allocator.free(path);
        var dir = try std.Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        if (try it.next(testing.io)) |entry| {
            std.debug.print("leftover in cafs/{s}: {s}\n", .{ sub, entry.name });
            return error.TestUnexpectedLeftover;
        }
    }
}

// ---------------------------------------------------------------------------
// Specifier / alias validation (SSRF, path traversal)
// ---------------------------------------------------------------------------

test "pkg security: refs and hosts that could become request URLs are rejected" {
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("host.example/u/r@http://127.0.0.1:8080/x"));
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("github.com/u/r@../../x"));
    try testing.expectError(error.InvalidHost, ParsedPackage.parse("127.0.0.1:8080/u/r"));
}

test "pkg security: transitive deps may only reference public git hosts" {
    const allowed = [_][]const u8{ "codeberg.org/u/r", "github.com/u/r", "gitlab.com/u/r@v1" };
    for (allowed) |spec| try testing.expect((try ParsedPackage.parse(spec)).isAllowedTransitive());

    const forbidden = [_][]const u8{
        "127.0.0.1/u/r", "localhost/u/r", "2130706433/u/r", "file:/etc/passwd", "https://evil.example/p.tar.gz",
    };
    for (forbidden) |spec| {
        testing.expect(!(try ParsedPackage.parse(spec)).isAllowedTransitive()) catch |err| {
            std.debug.print("transitive spec allowed: {s}\n", .{spec});
            return err;
        };
    }
}

test "pkg security: dependency aliases are restricted to a safe charset" {
    const max_alias: [limits.MAX_ALIAS_LEN]u8 = @splat('x');
    const too_long: [limits.MAX_ALIAS_LEN + 1]u8 = @splat('x');

    const valid = [_][]const u8{ "good_name-1.0", "a", &max_alias };
    for (valid) |alias| try validate.validateAlias(alias);

    const invalid = [_][]const u8{ "", "../../etc", "..", ".store", "-flag", "a/b", "a\\b", "a\"b", "a b", &too_long };
    for (invalid) |alias| {
        testing.expectError(error.InvalidAlias, validate.validateAlias(alias)) catch |err| {
            std.debug.print("accepted alias: \"{f}\"\n", .{std.zig.fmtString(alias)});
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Resolver: lockfile pinning, integrity, error propagation
// ---------------------------------------------------------------------------

const ResolverFixture = struct {
    base: CafsFixture,
    store: Store,
    manifest: Manifest,
    lockfile: Lockfile,

    fn init(self: *ResolverFixture) !void {
        try self.base.init();
        errdefer self.base.deinit();
        self.store = try Store.init(testing.io, ":memory:");
        self.manifest = Manifest.init(testing.allocator, "app");
        self.lockfile = Lockfile.init(testing.allocator);
    }

    fn deinit(self: *ResolverFixture) void {
        self.lockfile.deinit();
        self.manifest.deinit();
        self.store.deinit();
        self.base.deinit();
    }

    /// Writes a tar.gz into the tmp dir, adds it as dependency `alias` and returns
    /// its package id (caller frees).
    fn addLocalDep(self: *ResolverFixture, alias: []const u8, entries: []const TarEntry) ![]const u8 {
        const gz = try buildTarGz(testing.allocator, entries);
        defer testing.allocator.free(gz);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.tar.gz", .{ self.base.root, alias });
        defer testing.allocator.free(path);
        try writeAbs(path, gz);

        const spec = try std.fmt.allocPrint(testing.allocator, "file:{s}", .{path});
        errdefer testing.allocator.free(spec);
        const pkg_id = try (try ParsedPackage.parse(spec)).pkgId(testing.allocator);
        errdefer testing.allocator.free(pkg_id);
        const alias_dup = try testing.allocator.dupe(u8, alias);
        errdefer testing.allocator.free(alias_dup);
        try self.manifest.dependencies.put(alias_dup, spec);
        return pkg_id;
    }

    fn resolve(self: *ResolverFixture) !void {
        var resolver = Resolver.init(testing.allocator, testing.io, &self.base.cafs, &self.store, &self.manifest, &self.lockfile);
        defer resolver.deinit();
        try resolver.resolve();
    }

    /// Forgets every cached package so the next resolve takes the download path.
    fn clearStore(self: *ResolverFixture) !void {
        self.store.deinit();
        self.store = try Store.init(testing.io, ":memory:");
    }

    fn entry(self: *ResolverFixture, pkg_id: []const u8) !*LockedPackage {
        return self.lockfile.packages.getPtr(pkg_id) orelse error.TestExpectedLockEntry;
    }
};

const SAMPLE_PKG = [_]TarEntry{.{ .name = "main.kup", .data = "def f() 1 end" }};
const BOGUS_INTEGRITY = "sha256-0000000000000000000000000000000000000000000000000000000000000000";

test "pkg security: install errors propagate instead of reporting success" {
    var fx: ResolverFixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.manifest.dependencies.put(try testing.allocator.dupe(u8, "missing"), try testing.allocator.dupe(u8, "file:/nonexistent-kupcad-audit/pkg.tar.gz"));
    try testing.expectError(error.FileNotFound, fx.resolve());
}

test "pkg security: cached content is verified against the locked integrity" {
    var fx: ResolverFixture = undefined;
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

test "pkg security: downloads honor the locked commit and integrity" {
    var fx: ResolverFixture = undefined;
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

test "pkg security: lock entries without integrity are refused" {
    var fx: ResolverFixture = undefined;
    try fx.init();
    defer fx.deinit();
    const pkg_id = try fx.addLocalDep("dep", &SAMPLE_PKG);
    defer testing.allocator.free(pkg_id);
    try fx.resolve();

    try setOwned(&(try fx.entry(pkg_id)).integrity, "");
    try testing.expectError(error.LockfileMissingIntegrity, fx.resolve());
}

test "pkg security: a pin for a different ref is re-resolved, stale entries dropped" {
    var fx: ResolverFixture = undefined;
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

test "pkg security: 1.x lockfiles verify with the legacy hash and are rewritten as current" {
    var fx: ResolverFixture = undefined;
    try fx.init();
    defer fx.deinit();
    const pkg_id = try fx.addLocalDep("dep", &SAMPLE_PKG);
    defer testing.allocator.free(pkg_id);
    try fx.resolve();

    const current = try testing.allocator.dupe(u8, (try fx.entry(pkg_id)).integrity);
    defer testing.allocator.free(current);
    const legacy = blk: {
        var files = (try fx.store.getPackageFiles(testing.allocator, pkg_id, (try fx.entry(pkg_id)).resolved)).?;
        defer freeMap(&files);
        break :blk try Store.computeIntegrityAlgo(testing.allocator, &files, .legacy);
    };
    defer testing.allocator.free(legacy);
    try testing.expect(!std.mem.eql(u8, current, legacy));

    try setOwned(&fx.lockfile.version, "1.0.0");
    try testing.expect(try fx.lockfile.usesLegacyIntegrity());

    // A 1.x lockfile is checked with the 1.x algorithm, not the current one.
    try testing.expectError(error.IntegrityMismatch, fx.resolve());

    try setOwned(&(try fx.entry(pkg_id)).integrity, legacy);
    try fx.resolve();
    try testing.expectEqualStrings(current, (try fx.entry(pkg_id)).integrity);

    // Saving upgrades the format so the next install uses the current algorithm.
    const fs = fx.base.mem_vfs.vfs();
    try fx.lockfile.save(fs);
    var reloaded = try Lockfile.load(testing.allocator, fs);
    defer reloaded.deinit();
    try testing.expectEqualStrings(lockfile_mod.LOCKFILE_VERSION, reloaded.version);
    try testing.expect(!try reloaded.usesLegacyIntegrity());
    try testing.expectEqualStrings(current, reloaded.packages.get(pkg_id).?.integrity);

    // The in-memory lockfile now holds current hashes, so reusing it (without reloading)
    // must verify with the current algorithm too; it used to stay 1.0.0 and mismatch.
    try testing.expectEqualStrings(lockfile_mod.LOCKFILE_VERSION, fx.lockfile.version);
    try fx.resolve();
}

test "pkg security: forbidden or malformed transitive deps fail the install" {
    const cases = [_]struct { manifest: []const u8, err: anyerror }{
        .{ .manifest =
        \\{"dependencies":{"x":"file:/etc/passwd"}}
        , .err = error.ForbiddenTransitiveDependency },
        .{ .manifest =
        \\{"dependencies":{"x":"127.0.0.1/u/r"}}
        , .err = error.ForbiddenTransitiveDependency },
        // Alias from an untrusted kupcad.json is used as a symlink name
        .{ .manifest =
        \\{"dependencies":{"../../../../evil":"github.com/a/b"}}
        , .err = error.InvalidAlias },
        // Malformed manifests used to be skipped silently (install "succeeded")
        .{ .manifest =
        \\{"dependencies":["github.com/a/b"]}
        , .err = error.InvalidPackageManifest },
        .{ .manifest =
        \\{"dependencies":{"x":1}}
        , .err = error.InvalidPackageManifest },
        .{ .manifest = "not json", .err = error.InvalidPackageManifest },
    };
    for (cases) |c| {
        var fx: ResolverFixture = undefined;
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

// ---------------------------------------------------------------------------
// Lockfile / manifest JSON escaping
// ---------------------------------------------------------------------------

test "pkg security: lockfile strings are JSON-escaped" {
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

test "pkg security: manifest strings are JSON-escaped" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    const fs = mem_vfs.vfs();
    {
        var m = Manifest.init(testing.allocator, "n\"ame");
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

// ---------------------------------------------------------------------------
// GC / doctor consistency and bound SQL params
// ---------------------------------------------------------------------------

test "pkg security: prune evicts packages whose blobs were deleted" {
    var fx: CafsFixture = undefined;
    try fx.init();
    defer fx.deinit();
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    try fx.writeBlob("deadbeef", "content");
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", "deadbeef");
    try store.registerPackage("pkg", "c1", "github", "sha256-x", &files);

    // A package that doesn't reference the pruned blob must survive.
    var other = std.StringHashMap([]const u8).init(testing.allocator);
    defer other.deinit();
    try other.put("lib.kup", "keepme");
    try store.registerPackage("other", "c9", "github", "sha256-y", &other);

    var gc = GC.init(testing.allocator, testing.io, &fx.cafs, &store);
    try gc.prune(true);

    try testing.expect(!try store.hasPackage("pkg", "c1"));
    try testing.expectEqual(@as(i64, 0), try countRows(&store, "SELECT COUNT(*) FROM package_files WHERE package_id = 'pkg'"));
    try testing.expect(try store.hasPackage("other", "c9"));
    try testing.expectEqual(@as(i64, 1), try countRows(&store, "SELECT COUNT(*) FROM package_files WHERE package_id = 'other'"));
}

test "pkg security: prune and doctor use bound SQL parameters" {
    var fx: CafsFixture = undefined;
    try fx.init();
    defer fx.deinit();
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    // A CAFS file name crafted as SQL. With string formatting, the doctor's lookup
    // matched any row (so the orphan was never indexed) and prune deleted every row.
    const evil_name = "zz' OR '1'='1";
    {
        try store.db.exec("INSERT INTO files (hash, size, created_at) VALUES ('keep', 0, 0)", .{}, .{});
        try fx.writeBlob("keep", "k");
        try fx.writeBlob(evil_name, "x");

        var doc = Doctor.init(testing.allocator, testing.io, &fx.cafs, &store);
        try doc.run();

        const stmt = try store.db.prepare("SELECT 1 FROM files WHERE hash = ?");
        defer stmt.deinit();
        try testing.expect((try stmt.one(struct { v: i32 }, .{evil_name}, .{})) != null);
    }
    {
        // Only the evil blob is physically present and unreferenced; 'keep' is just a row.
        const keep_path = try fx.cafs.blobPath("keep");
        defer testing.allocator.free(keep_path);
        try std.Io.Dir.cwd().deleteFile(testing.io, keep_path);
        try store.db.exec("DELETE FROM files WHERE hash = ?", .{evil_name}, .{});

        var gc = GC.init(testing.allocator, testing.io, &fx.cafs, &store);
        try gc.prune(true);

        try testing.expectEqual(@as(i64, 1), try countRows(&store, "SELECT COUNT(*) FROM files WHERE hash = 'keep'"));
    }
}

// ---------------------------------------------------------------------------
// Store schema and integrity encoding
// ---------------------------------------------------------------------------

test "pkg security: v2 store databases migrate to the composite package key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpAbsPath(&tmp);
    defer testing.allocator.free(root);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/index.db", .{root}, 0);
    defer testing.allocator.free(db_path);

    {
        // A database exactly as the v2 code left it (id-only primary key), with data.
        var handle: ?*sqlite.sqlite3 = null;
        try testing.expectEqual(sqlite.SQLITE_OK, sqlite.sqlite3_open(db_path, &handle));
        var db = store_mod.Db{ .handle = handle };
        defer db.deinit();
        const v2_schema = [_][]const u8{
            "CREATE TABLE packages (id TEXT PRIMARY KEY, commit_sha TEXT NOT NULL, provider TEXT NOT NULL, created_at INTEGER NOT NULL, integrity TEXT NOT NULL DEFAULT '')",
            "CREATE TABLE files (hash TEXT PRIMARY KEY, size INTEGER NOT NULL, created_at INTEGER NOT NULL)",
            "CREATE TABLE package_files (package_id TEXT NOT NULL, commit_sha TEXT NOT NULL, file_path TEXT NOT NULL, file_hash TEXT NOT NULL, PRIMARY KEY (package_id, commit_sha, file_path), FOREIGN KEY (file_hash) REFERENCES files(hash))",
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "INSERT INTO packages VALUES ('pkg', 'old', 'github', 7, 'sha256-old')",
            "INSERT INTO files VALUES ('h1', 3, 7)",
            "INSERT INTO package_files VALUES ('pkg', 'old', 'main.kup', 'h1')",
            // Mapping of a commit the v2 schema silently dropped from `packages`
            "INSERT INTO package_files VALUES ('pkg', 'lost', 'main.kup', 'h1')",
            "INSERT INTO meta VALUES ('last_prune_time', '42')",
            "PRAGMA user_version = 2",
        };
        for (v2_schema) |sql| try db.exec(sql, .{}, .{});
    }

    var store = try Store.init(testing.io, db_path);
    defer store.deinit();
    try testing.expectEqual(@as(i64, 3), try countRows(&store, "SELECT user_version AS n FROM pragma_user_version"));

    // Existing rows survive the table rebuild with all columns intact.
    {
        const stmt = try store.db.prepare("SELECT provider, integrity, created_at FROM packages WHERE id = 'pkg' AND commit_sha = 'old'");
        defer stmt.deinit();
        const row = (try stmt.one(struct { provider: []const u8, integrity: []const u8, created_at: i64 }, .{}, .{})) orelse return error.TestMissingRow;
        try testing.expectEqualStrings("github", row.provider);
        try testing.expectEqualStrings("sha256-old", row.integrity);
        try testing.expectEqual(@as(i64, 7), row.created_at);
    }
    var files = (try store.getPackageFiles(testing.allocator, "pkg", "old")).?;
    defer freeMap(&files);
    try testing.expectEqualStrings("h1", files.get("main.kup").?);
    try testing.expectEqual(@as(i64, 1), try countRows(&store, "SELECT COUNT(*) FROM files"));
    try testing.expectEqual(@as(i64, 1), try countRows(&store, "SELECT COUNT(*) FROM meta"));
    // Unreachable mappings are cleaned up.
    try testing.expectEqual(@as(i64, 0), try countRows(&store, "SELECT COUNT(*) FROM package_files WHERE commit_sha = 'lost'"));

    // A second commit of the same package can now be recorded alongside the first.
    var new_files = std.StringHashMap([]const u8).init(testing.allocator);
    defer new_files.deinit();
    try store.registerPackage("pkg", "new", "github", "sha256-new", &new_files);
    try testing.expect(try store.hasPackage("pkg", "new"));
    try testing.expect(try store.hasPackage("pkg", "old"));
}

test "pkg security: integrity input is unambiguous" {
    var m1 = std.StringHashMap([]const u8).init(testing.allocator);
    defer m1.deinit();
    try m1.put("ab", "c");
    var m2 = std.StringHashMap([]const u8).init(testing.allocator);
    defer m2.deinit();
    try m2.put("a", "bc");

    const h1 = try Store.computeIntegrity(testing.allocator, &m1);
    defer testing.allocator.free(h1);
    const h2 = try Store.computeIntegrity(testing.allocator, &m2);
    defer testing.allocator.free(h2);
    try testing.expect(!std.mem.eql(u8, h1, h2));
    try Store.verifyIntegrity(testing.allocator, &m1, h1, .current);
    try testing.expectError(error.IntegrityMismatch, Store.verifyIntegrity(testing.allocator, &m2, h1, .current));

    // The legacy (lockfile 1.x) algorithm is kept, ambiguity included, to verify old lockfiles.
    const legacy = try Store.computeIntegrityAlgo(testing.allocator, &m1, .legacy);
    defer testing.allocator.free(legacy);
    try Store.verifyIntegrity(testing.allocator, &m2, legacy, .legacy);
}

// ---------------------------------------------------------------------------
// CAFS blobs linked into a NativeVfs sandbox
// ---------------------------------------------------------------------------

test "pkg security: CAFS blobs hard-link into a NativeVfs sandbox" {
    var proj = testing.tmpDir(.{});
    defer proj.cleanup();
    var global = testing.tmpDir(.{});
    defer global.cleanup();
    const global_path = try tmpAbsPath(&global);
    defer testing.allocator.free(global_path);

    var native = NativeVfs.init(testing.io, proj.dir);
    const fs = native.vfs();
    var cafs = try Cafs.init(testing.allocator, testing.io, global_path, fs);
    defer cafs.deinit();

    const blob = try cafs.blobPath("cafe");
    defer testing.allocator.free(blob);
    try writeAbs(blob, "shared");

    // Real installs failed here with AccessDenied (absolute source rejected by the sandbox).
    try fs.makePath("store/pkg");
    try cafs.linkBlob("cafe", "store/pkg/main.kup");
    try cafs.linkBlob("cafe", "store/pkg/main.kup"); // re-install replaces

    const stat = try proj.dir.statFile(testing.io, "store/pkg/main.kup", .{});
    try testing.expect(stat.nlink >= 2);

    // The trusted API refuses relative sources, and destinations stay sandboxed.
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted("../outside", "x"));
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted(blob, "../../escape"));
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted(blob, "/tmp/escape"));
    // linkBlob must not fall back to copying when the sandbox rejects the destination.
    try testing.expectError(error.AccessDenied, cafs.linkBlob("cafe", "../escape"));
}
