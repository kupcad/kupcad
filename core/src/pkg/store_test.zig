const std = @import("std");
const testing = std.testing;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const sqlite = @import("sqlite");
const helpers = @import("test_helpers.zig");
const freeMap = helpers.freeMap;
const countRows = helpers.countRows;

test "Store: initializes and runs SQLite migrations in-memory" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    const stmt = try store.db.prepare("PRAGMA user_version");
    defer stmt.deinit();
    const row = try stmt.one(struct { user_version: i32 }, .{}, .{});

    try testing.expect(row != null);
    try testing.expectEqual(@as(i32, 3), row.?.user_version); // Expect V3 (composite packages key)
}

test "Store: registerPackage records metadata and file hashes for lookup" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    try testing.expect(!try store.hasPackage("github.com-kupcad-std", "commit-abc"));
    try testing.expect((try store.getPackageFiles(testing.allocator, "github.com-kupcad-std", "commit-abc")) == null);

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("lib/main.kup", "hash_main_123");
    try files.put("kupcad.json", "hash_json_456");
    try store.registerPackage("github.com-kupcad-std", "commit-abc", "github", "sha256-mockhash", &files);

    try testing.expect(try store.hasPackage("github.com-kupcad-std", "commit-abc"));
    try testing.expect(!try store.hasPackage("github.com-kupcad-std", "commit-other"));

    const pkg_stmt = try store.db.prepare("SELECT provider, integrity FROM packages WHERE id = 'github.com-kupcad-std'");
    defer pkg_stmt.deinit();
    const pkg_row = (try pkg_stmt.one(struct { provider: []const u8, integrity: []const u8 }, .{}, .{})) orelse return error.MissingRow;
    try testing.expectEqualStrings("github", pkg_row.provider);
    try testing.expectEqualStrings("sha256-mockhash", pkg_row.integrity);

    var cached = (try store.getPackageFiles(testing.allocator, "github.com-kupcad-std", "commit-abc")).?;
    defer freeMap(&cached);
    try testing.expectEqual(@as(usize, 2), cached.count());
    try testing.expectEqualStrings("hash_main_123", cached.get("lib/main.kup").?);
    try testing.expectEqualStrings("hash_json_456", cached.get("kupcad.json").?);
}

// Audit fix: re-registering used INSERT OR IGNORE (stale integrity kept) and
// merged file mappings instead of replacing them with the verified content.
test "Store: re-registering a commit refreshes metadata and replaces the file mapping" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var old_files = std.StringHashMap([]const u8).init(testing.allocator);
    defer old_files.deinit();
    try old_files.put("main.kup", "hash-old");
    try old_files.put("removed.kup", "hash-removed");
    try store.registerPackage("pkg-a", "commit-a", "git", "sha256-old", &old_files);

    var new_files = std.StringHashMap([]const u8).init(testing.allocator);
    defer new_files.deinit();
    try new_files.put("main.kup", "hash-new");
    try store.registerPackage("pkg-a", "commit-a", "git", "sha256-new", &new_files);

    const stmt = try store.db.prepare("SELECT COUNT(*) AS count, MAX(integrity) AS integrity FROM packages WHERE id = 'pkg-a'");
    defer stmt.deinit();
    const row = (try stmt.one(struct { count: i64, integrity: []const u8 }, .{}, .{})) orelse return error.MissingRow;
    try testing.expectEqual(@as(i64, 1), row.count);
    try testing.expectEqualStrings("sha256-new", row.integrity);

    var cached = (try store.getPackageFiles(testing.allocator, "pkg-a", "commit-a")).?;
    defer freeMap(&cached);
    try testing.expectEqual(@as(usize, 1), cached.count());
    try testing.expectEqualStrings("hash-new", cached.get("main.kup").?);
}

test "Store: gracefully handles packages with zero files" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var empty_files = std.StringHashMap([]const u8).init(testing.allocator);
    defer empty_files.deinit();

    try store.registerPackage("meta-pkg", "commit-b", "git", "sha256-mock", &empty_files);

    const stmt = try store.db.prepare("SELECT id FROM packages WHERE id = 'meta-pkg'");
    defer stmt.deinit();
    const row = try stmt.one(struct { id: []const u8 }, .{}, .{});

    try testing.expect(row != null);
    try testing.expectEqualStrings("meta-pkg", row.?.id);
}

test "Store: computeIntegrity generates deterministic hashes regardless of map iteration order" {
    var files1 = std.StringHashMap([]const u8).init(testing.allocator);
    defer files1.deinit();
    try files1.put("file_b.kup", "hash-b");
    try files1.put("file_a.kup", "hash-a");
    try files1.put("file_c.kup", "hash-c");

    var files2 = std.StringHashMap([]const u8).init(testing.allocator);
    defer files2.deinit();
    // Insert in a completely different order to scramble the internal bucket layout
    try files2.put("file_c.kup", "hash-c");
    try files2.put("file_b.kup", "hash-b");
    try files2.put("file_a.kup", "hash-a");

    const hash1 = try Store.computeIntegrity(testing.allocator, &files1);
    defer testing.allocator.free(hash1);

    const hash2 = try Store.computeIntegrity(testing.allocator, &files2);
    defer testing.allocator.free(hash2);

    // The Merkle-style hash must perfectly match across both instances
    try testing.expectEqualStrings(hash1, hash2);
    try testing.expect(std.mem.startsWith(u8, hash1, "sha256-"));
}

test "Store: computeIntegrity detects file tampering" {
    var files1 = std.StringHashMap([]const u8).init(testing.allocator);
    defer files1.deinit();
    try files1.put("main.kup", "hash-clean");

    var files2 = std.StringHashMap([]const u8).init(testing.allocator);
    defer files2.deinit();
    try files2.put("main.kup", "hash-tampered");

    const hash1 = try Store.computeIntegrity(testing.allocator, &files1);
    defer testing.allocator.free(hash1);

    const hash2 = try Store.computeIntegrity(testing.allocator, &files2);
    defer testing.allocator.free(hash2);

    // Hashes must deviate if the underlying file contents (represented by their hashes) change
    try testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "Store: computeIntegrity handles empty packages" {
    var empty_files = std.StringHashMap([]const u8).init(testing.allocator);
    defer empty_files.deinit();

    const hash = try Store.computeIntegrity(testing.allocator, &empty_files);
    defer testing.allocator.free(hash);

    // Empty packages should still generate a valid, reproducible sha256 checksum (the hash of nothing)
    try testing.expect(std.mem.startsWith(u8, hash, "sha256-"));
    // e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 is the sha256 of an empty string
    try testing.expectEqualStrings("sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hash);
}

// Audit fix: the v1 schema keyed `packages` by id, silently dropping every
// commit of a package after the first.
test "Store: keeps several commits of one package with separate file maps" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var files_a = std.StringHashMap([]const u8).init(testing.allocator);
    defer files_a.deinit();
    try files_a.put("main.kup", "hashA");

    var files_b = std.StringHashMap([]const u8).init(testing.allocator);
    defer files_b.deinit();
    try files_b.put("utils.kup", "hashB");

    try store.registerPackage("pkg-test", "commit1", "git", "sha256-1", &files_a);
    try store.registerPackage("pkg-test", "commit2", "git", "sha256-2", &files_b);

    try testing.expect(try store.hasPackage("pkg-test", "commit1"));
    try testing.expect(try store.hasPackage("pkg-test", "commit2"));

    var cached = (try store.getPackageFiles(testing.allocator, "pkg-test", "commit2")).?;
    defer freeMap(&cached);
    try testing.expectEqual(@as(usize, 1), cached.count());
    try testing.expectEqualStrings("hashB", cached.get("utils.kup").?);
}

// Audit fix: databases left by the v2 schema (id-only packages key) must be
// migrated in place, keeping their rows.
test "Store: migrates v2 databases to the composite package key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
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

// Audit fix: path and hash were concatenated without separators, so different
// file maps ("ab"->"c" vs "a"->"bc") produced the same integrity.
test "Store: computeIntegrity input is unambiguous" {
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

test "Store: a write waits for another connection's lock instead of failing" {
    // Two processes share the global index (two installs, or an install during `pkg
    // prune`); without a busy timeout the second failed at once with SQLITE_BUSY.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const db_path = try std.fs.path.join(testing.allocator, &.{ dir, "index.db" });
    defer testing.allocator.free(db_path);

    var holder = try Store.init(testing.io, db_path);
    defer holder.deinit();
    var writer = try Store.init(testing.io, db_path);
    defer writer.deinit();

    try holder.db.exec("BEGIN IMMEDIATE", .{}, .{});
    const Release = struct {
        fn run(store: *Store) void {
            testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
            store.db.exec("COMMIT", .{}, .{}) catch @panic("COMMIT failed");
        }
    };
    const releaser = try std.Thread.spawn(.{}, Release.run, .{&holder});
    defer releaser.join();

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("kupcad.json", "hash_json");
    try writer.registerPackage("github.com-u-r", "commit-a", "github", "sha256-x", &files);
    try testing.expect(try writer.hasPackage("github.com-u-r", "commit-a"));
}
