//! Regression tests for issues found in the Oct 2026 audit.
//! Package manager: archive extraction, lockfile pinning/integrity, provider
//! dispatch, input validation, store/GC consistency. No network access.

const std = @import("std");
const testing = std.testing;

const cafs_mod = @import("cafs.zig");
const Cafs = cafs_mod.Cafs;
const Store = @import("store.zig").Store;
const GC = @import("gc.zig").GarbageCollector;
const Doctor = @import("health.zig").Doctor;
const Manifest = @import("manifest.zig").Manifest;
const lockfile_mod = @import("lockfile.zig");
const Lockfile = lockfile_mod.Lockfile;
const LockedPackage = lockfile_mod.LockedPackage;
const StringMap = lockfile_mod.StringMap;
const Resolver = @import("resolver.zig").Resolver;
const ParsedPackage = @import("providers/provider.zig").ParsedPackage;
const Fetcher = @import("providers/fetcher.zig").Fetcher;
const validate = @import("validate.zig");
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

// ---------------------------------------------------------------------------
// Finding 1 + 7: archive extraction
// ---------------------------------------------------------------------------

test "pkg security: tarball symlink entry cannot plant files outside the package" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpAbsPath(&tmp);
    defer testing.allocator.free(root);

    try tmp.dir.createDirPath(testing.io, "victim");
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{root});
    defer testing.allocator.free(victim);
    const cafs_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cafs", .{root});
    defer testing.allocator.free(cafs_dir);

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    var cafs = try Cafs.init(testing.allocator, testing.io, cafs_dir, mem_vfs.vfs());
    defer cafs.deinit();

    const gz = try buildTarGz(testing.allocator, &.{
        .{ .name = "pkg/link", .kind = .symlink, .link = victim },
        .{ .name = "pkg/link/planted.txt", .data = "pwned!" },
    });
    defer testing.allocator.free(gz);

    var reader: std.Io.Reader = .fixed(gz);
    var map = try cafs.extractTarball(&reader);
    defer freeMap(&map);

    const planted = try std.fmt.allocPrint(testing.allocator, "{s}/planted.txt", .{victim});
    defer testing.allocator.free(planted);
    try testing.expect(!existsAbs(planted));
    try testing.expect(map.get("pkg/link") == null);
}

test "pkg security: tarball entries escaping the root are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpAbsPath(&tmp);
    defer testing.allocator.free(root);

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    var cafs = try Cafs.init(testing.allocator, testing.io, root, mem_vfs.vfs());
    defer cafs.deinit();

    const gz = try buildTarGz(testing.allocator, &.{.{ .name = "../escape.txt", .data = "x" }});
    defer testing.allocator.free(gz);
    var reader: std.Io.Reader = .fixed(gz);
    try testing.expectError(error.UnsafeArchivePath, cafs.extractTarball(&reader));

    var buf: [256]u8 = undefined;
    try testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&buf, "/etc/passwd"));
    try testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&buf, "a/../../b"));
    try testing.expectError(error.UnsafeArchivePath, cafs_mod.sanitizeEntryPath(&buf, "a\\..\\b"));
    try testing.expectEqualStrings("a/b", try cafs_mod.sanitizeEntryPath(&buf, "./a//b"));
}

test "pkg security: extraction enforces decompressed size and file count limits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpAbsPath(&tmp);
    defer testing.allocator.free(root);

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    var cafs = try Cafs.init(testing.allocator, testing.io, root, mem_vfs.vfs());
    defer cafs.deinit();

    const big: [4096]u8 = @splat('A');
    {
        cafs.extract_limits = .{ .max_total_bytes = 1024 };
        const gz = try buildTarGz(testing.allocator, &.{.{ .name = "bomb.bin", .data = &big }});
        defer testing.allocator.free(gz);
        var reader: std.Io.Reader = .fixed(gz);
        try testing.expectError(error.ArchiveTooLarge, cafs.extractTarball(&reader));
    }
    {
        cafs.extract_limits = .{ .max_file_count = 2 };
        const gz = try buildTarGz(testing.allocator, &.{
            .{ .name = "a", .data = "1" },
            .{ .name = "b", .data = "2" },
            .{ .name = "c", .data = "3" },
        });
        defer testing.allocator.free(gz);
        var reader: std.Io.Reader = .fixed(gz);
        try testing.expectError(error.ArchiveTooManyFiles, cafs.extractTarball(&reader));
    }
}

test "pkg security: commit API response shape is validated, not trusted" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidApiResponse, Fetcher.parseCommitShaResponse(a, "[]"));
    try testing.expectError(error.InvalidApiResponse, Fetcher.parseCommitShaResponse(a, "\"str\""));
    try testing.expectError(error.InvalidApiResponse, Fetcher.parseCommitShaResponse(a, "{\"sha\": 5}"));
    try testing.expectError(error.InvalidApiResponse, Fetcher.parseCommitShaResponse(a, "{\"sha\": \"../../etc\"}"));
    try testing.expectError(error.InvalidApiResponse, Fetcher.parseCommitShaResponse(a, "not json"));

    const sha = "0123456789abcdef0123456789abcdef01234567";
    const got = try Fetcher.parseCommitShaResponse(a, "{\"sha\": \"" ++ sha ++ "\"}");
    defer a.free(got);
    try testing.expectEqualStrings(sha, got);
    // GitLab uses `id`; Gitea list endpoints return an array
    const got2 = try Fetcher.parseCommitShaResponse(a, "[{\"id\": \"" ++ sha ++ "\"}]");
    defer a.free(got2);
    try testing.expectEqualStrings(sha, got2);
}

// ---------------------------------------------------------------------------
// Finding 4: provider dispatch / ref validation / SSRF
// ---------------------------------------------------------------------------

test "pkg security: non-GitHub refs are never used as request URLs" {
    const a = testing.allocator;
    const gitea = try ParsedPackage.parse("git.example.org/u/r@main");
    const url = try Fetcher.commitApiUrl(a, gitea);
    defer a.free(url);
    try testing.expectEqualStrings("https://git.example.org/api/v1/repos/u/r/commits/main", url);

    const http_pkg = try ParsedPackage.parse("https://example.org/pkg.tar.gz");
    try testing.expectError(error.NotApplicable, Fetcher.commitApiUrl(a, http_pkg));

    // A ref that is itself a URL (the SSRF vector) is rejected at parse time.
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("host.example/u/r@http://127.0.0.1:8080/x"));
    try testing.expectError(error.InvalidRef, ParsedPackage.parse("github.com/u/r@../../x"));
    try testing.expectError(error.InvalidHost, ParsedPackage.parse("127.0.0.1:8080/u/r"));
}

test "pkg security: transitive deps may only reference public git hosts" {
    try testing.expect((try ParsedPackage.parse("codeberg.org/u/r")).isAllowedTransitive());
    try testing.expect(!(try ParsedPackage.parse("127.0.0.1/u/r")).isAllowedTransitive());
    try testing.expect(!(try ParsedPackage.parse("localhost/u/r")).isAllowedTransitive());
    try testing.expect(!(try ParsedPackage.parse("2130706433/u/r")).isAllowedTransitive());
    try testing.expect(!(try ParsedPackage.parse("file:/etc/passwd")).isAllowedTransitive());
    try testing.expect(!(try ParsedPackage.parse("https://evil.example/p.tar.gz")).isAllowedTransitive());
}

// ---------------------------------------------------------------------------
// Findings 2 + 4: resolver uses the lockfile, verifies integrity, surfaces errors
// ---------------------------------------------------------------------------

const ResolverFixture = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    mem_vfs: MemoryVfs,
    cafs: Cafs,
    store: Store,
    manifest: Manifest,
    lockfile: Lockfile,

    fn init(self: *ResolverFixture) !void {
        self.tmp = testing.tmpDir(.{});
        self.root = try tmpAbsPath(&self.tmp);
        const cafs_dir = try std.fmt.allocPrint(testing.allocator, "{s}/cafs", .{self.root});
        defer testing.allocator.free(cafs_dir);
        self.mem_vfs = MemoryVfs.init(testing.allocator);
        self.cafs = try Cafs.init(testing.allocator, testing.io, cafs_dir, self.mem_vfs.vfs());
        self.store = try Store.init(testing.io, ":memory:");
        self.manifest = Manifest.init(testing.allocator, "app");
        self.lockfile = Lockfile.init(testing.allocator);
    }

    fn deinit(self: *ResolverFixture) void {
        self.lockfile.deinit();
        self.manifest.deinit();
        self.store.deinit();
        self.cafs.deinit();
        self.mem_vfs.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// Writes a tar.gz into the tmp dir and returns its `file:` specifier.
    fn localPackage(self: *ResolverFixture, name: []const u8, entries: []const TarEntry) ![]u8 {
        const gz = try buildTarGz(testing.allocator, entries);
        defer testing.allocator.free(gz);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.root, name });
        defer testing.allocator.free(path);
        try writeAbs(path, gz);
        return std.fmt.allocPrint(testing.allocator, "file:{s}", .{path});
    }

    fn addDep(self: *ResolverFixture, alias: []const u8, spec: []const u8) !void {
        try self.manifest.dependencies.put(try testing.allocator.dupe(u8, alias), try testing.allocator.dupe(u8, spec));
    }

    fn resolve(self: *ResolverFixture) !void {
        var resolver = Resolver.init(testing.allocator, testing.io, &self.cafs, &self.store, &self.manifest, &self.lockfile);
        defer resolver.deinit();
        try resolver.resolve();
    }
};

test "pkg security: install errors propagate instead of reporting success" {
    var fx: ResolverFixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.addDep("missing", "file:/nonexistent-kupcad-audit/pkg.tar.gz");
    try testing.expectError(error.FileNotFound, fx.resolve());
}

test "pkg security: lockfile pins are honored and integrity mismatches fail loudly" {
    var fx: ResolverFixture = undefined;
    try fx.init();
    defer fx.deinit();

    const spec = try fx.localPackage("dep.tar.gz", &.{.{ .name = "main.kup", .data = "def f() 1 end" }});
    defer testing.allocator.free(spec);
    try fx.addDep("dep", spec);

    // 1. Fresh install records an entry with integrity
    try fx.resolve();
    const parsed = try ParsedPackage.parse(spec);
    const pkg_id = try parsed.pkgId(testing.allocator);
    defer testing.allocator.free(pkg_id);
    const entry = fx.lockfile.packages.getPtr(pkg_id) orelse return error.TestExpectedLockEntry;
    try testing.expect(std.mem.startsWith(u8, entry.integrity, "sha256-"));

    // 2. Re-install against the same lockfile verifies and succeeds
    try fx.resolve();

    // 3. Tampered lockfile integrity (or tampered content) must abort the install
    const evil = try testing.allocator.dupe(u8, "sha256-0000000000000000000000000000000000000000000000000000000000000000");
    const entry2 = fx.lockfile.packages.getPtr(pkg_id).?;
    testing.allocator.free(entry2.integrity);
    entry2.integrity = evil;
    try testing.expectError(error.IntegrityMismatch, fx.resolve());
}

test "pkg security: forbidden or malformed transitive deps fail the install" {
    {
        var fx: ResolverFixture = undefined;
        try fx.init();
        defer fx.deinit();
        const spec = try fx.localPackage("p.tar.gz", &.{.{ .name = "kupcad.json", .data =
            \\{"name":"p","version":"1.0.0","dependencies":{"x":"file:/etc/passwd"}}
        }});
        defer testing.allocator.free(spec);
        try fx.addDep("p", spec);
        try testing.expectError(error.ForbiddenTransitiveDependency, fx.resolve());
    }
    {
        var fx: ResolverFixture = undefined;
        try fx.init();
        defer fx.deinit();
        const spec = try fx.localPackage("p.tar.gz", &.{.{ .name = "kupcad.json", .data =
            \\{"name":"p","version":"1.0.0","dependencies":{"x":"127.0.0.1/u/r"}}
        }});
        defer testing.allocator.free(spec);
        try fx.addDep("p", spec);
        try testing.expectError(error.ForbiddenTransitiveDependency, fx.resolve());
    }
    {
        // Finding 6: alias from an untrusted kupcad.json used as a symlink name
        var fx: ResolverFixture = undefined;
        try fx.init();
        defer fx.deinit();
        const spec = try fx.localPackage("p.tar.gz", &.{.{ .name = "kupcad.json", .data =
            \\{"name":"p","version":"1.0.0","dependencies":{"../../../../evil":"github.com/a/b"}}
        }});
        defer testing.allocator.free(spec);
        try fx.addDep("p", spec);
        try testing.expectError(error.InvalidAlias, fx.resolve());
    }
}

test "pkg security: dependency aliases are restricted to a safe charset" {
    try validate.validateAlias("good_name-1.0");
    try testing.expectError(error.InvalidAlias, validate.validateAlias("../../etc"));
    try testing.expectError(error.InvalidAlias, validate.validateAlias(".store"));
    try testing.expectError(error.InvalidAlias, validate.validateAlias("a/b"));
    try testing.expectError(error.InvalidAlias, validate.validateAlias("a\"b"));
    try testing.expectError(error.InvalidAlias, validate.validateAlias(""));
    const too_long: [65]u8 = @splat('x');
    try testing.expectError(error.InvalidAlias, validate.validateAlias(&too_long));
}

// ---------------------------------------------------------------------------
// Finding 5: lockfile / manifest JSON escaping
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
    try testing.expectEqualStrings("github.com/a/b@v\"1", m2.dependencies.get("dep").?);
}

// ---------------------------------------------------------------------------
// Finding 8: GC / doctor consistency and bound SQL params
// ---------------------------------------------------------------------------

test "pkg security: prune invalidates packages whose blobs were deleted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpAbsPath(&tmp);
    defer testing.allocator.free(root);
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    var cafs = try Cafs.init(testing.allocator, testing.io, root, mem_vfs.vfs());
    defer cafs.deinit();
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    const blob = try cafs.blobPath("deadbeef");
    defer testing.allocator.free(blob);
    try writeAbs(blob, "content");

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", "deadbeef");
    try store.registerPackage("pkg", "c1", "github", "sha256-x", &files);

    var gc = GC.init(testing.allocator, testing.io, &cafs, &store);
    try gc.prune(true);

    try testing.expect(!try store.hasPackage("pkg", "c1"));
    var cached = try store.getPackageFiles(testing.allocator, "pkg", "c1");
    if (cached) |*m| freeMap(m);
    try testing.expect(cached == null);
    const stmt = try store.db.prepare("SELECT COUNT(*) FROM package_files");
    defer stmt.deinit();
    try testing.expectEqual(@as(i64, 0), (try stmt.one(struct { n: i64 }, .{}, .{})).?.n);
}

test "pkg security: prune and doctor use bound SQL parameters" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpAbsPath(&tmp);
    defer testing.allocator.free(root);
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    var cafs = try Cafs.init(testing.allocator, testing.io, root, mem_vfs.vfs());
    defer cafs.deinit();
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    // A CAFS file name crafted as SQL. With string formatting, the doctor's lookup
    // matched any row (so the orphan was never indexed) and prune deleted every row.
    const evil_name = "zz' OR '1'='1";
    const evil_path = try cafs.blobPath(evil_name);
    defer testing.allocator.free(evil_path);
    const keep_path = try cafs.blobPath("keep");
    defer testing.allocator.free(keep_path);

    {
        try store.db.exec("INSERT INTO files (hash, size, created_at) VALUES ('keep', 0, 0)", .{}, .{});
        try writeAbs(keep_path, "k");
        try writeAbs(evil_path, "x");

        var doc = Doctor.init(testing.allocator, testing.io, &cafs, &store);
        try doc.run();

        const stmt = try store.db.prepare("SELECT 1 FROM files WHERE hash = ?");
        defer stmt.deinit();
        try testing.expect((try stmt.one(struct { v: i32 }, .{evil_name}, .{})) != null);
    }
    {
        // Only the evil blob is physically present and unreferenced; 'keep' is just a row.
        try std.Io.Dir.cwd().deleteFile(testing.io, keep_path);
        try store.db.exec("DELETE FROM files WHERE hash = ?", .{evil_name}, .{});

        var gc = GC.init(testing.allocator, testing.io, &cafs, &store);
        try gc.prune(true);

        const stmt = try store.db.prepare("SELECT 1 FROM files WHERE hash = 'keep'");
        defer stmt.deinit();
        try testing.expect((try stmt.one(struct { v: i32 }, .{}, .{})) != null);
    }
}

// ---------------------------------------------------------------------------
// Finding 9: store schema and integrity encoding
// ---------------------------------------------------------------------------

test "pkg security: store keeps multiple commits of the same package" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("a", "h1");

    try store.registerPackage("pkg", "c1", "github", "sha256-1", &files);
    try store.registerPackage("pkg", "c2", "github", "sha256-2", &files);
    try testing.expect(try store.hasPackage("pkg", "c1"));
    try testing.expect(try store.hasPackage("pkg", "c2"));
}

test "pkg security: v2 store databases migrate to composite package key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpAbsPath(&tmp);
    defer testing.allocator.free(root);
    const db_path = try std.fmt.allocPrint(testing.allocator, "{s}/index.db", .{root});
    defer testing.allocator.free(db_path);

    {
        // Recreate the pre-fix v2 layout with existing data
        var store = try Store.init(testing.io, db_path);
        defer store.deinit();
        try store.db.exec("DROP TABLE packages", .{}, .{});
        try store.db.exec("CREATE TABLE packages (id TEXT PRIMARY KEY, commit_sha TEXT NOT NULL, provider TEXT NOT NULL, created_at INTEGER NOT NULL, integrity TEXT NOT NULL DEFAULT '')", .{}, .{});
        try store.db.exec("INSERT INTO packages VALUES ('pkg', 'old', 'github', 0, 'sha256-old')", .{}, .{});
        try store.db.exec("PRAGMA user_version = 2", .{}, .{});
    }

    var store = try Store.init(testing.io, db_path);
    defer store.deinit();
    try testing.expect(try store.hasPackage("pkg", "old"));
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try store.registerPackage("pkg", "new", "github", "sha256-new", &files);
    try testing.expect(try store.hasPackage("pkg", "new"));
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

    // Legacy (lockfile 1.x) values still verify through the legacy algorithm.
    const legacy = try Store.computeIntegrityAlgo(testing.allocator, &m1, .legacy);
    defer testing.allocator.free(legacy);
    try Store.verifyIntegrity(testing.allocator, &m2, legacy, .legacy);
}

// ---------------------------------------------------------------------------
// Finding 3: NativeVfs trusted CAFS links and relative symlink targets
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

    try fs.makePath("store/pkg");
    try cafs.linkBlob("cafe", "store/pkg/main.kup");
    try cafs.linkBlob("cafe", "store/pkg/main.kup"); // re-install replaces

    const stat = try proj.dir.statFile(testing.io, "store/pkg/main.kup", .{});
    try testing.expect(stat.nlink >= 2);

    // The trusted API refuses relative sources, and destinations stay sandboxed.
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted("../outside", "x"));
    try testing.expectError(error.AccessDenied, fs.hardLinkTrusted(blob, "../../escape"));
}

test "pkg security: NativeVfs resolves symlink targets relative to the link" {
    var proj = testing.tmpDir(.{});
    defer proj.cleanup();
    var native = NativeVfs.init(testing.io, proj.dir);
    const fs = native.vfs();

    try fs.makePath(".kupcad/pkg/.store/a-1/.kupcad/pkg");
    try fs.makePath(".kupcad/pkg/.store/b-2/pkg");
    try fs.symLink("../../../b-2/pkg", ".kupcad/pkg/.store/a-1/.kupcad/pkg/b");
    // Idempotent re-link
    try fs.symLink("../../../b-2/pkg", ".kupcad/pkg/.store/a-1/.kupcad/pkg/b");

    try testing.expectError(error.AccessDenied, fs.symLink("../../../../../../../etc", ".kupcad/pkg/.store/a-1/.kupcad/pkg/c"));
    try testing.expectError(error.AccessDenied, fs.symLink("/etc", ".kupcad/pkg/d"));
}
