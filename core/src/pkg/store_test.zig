const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;

test "Store: initializes and runs SQLite migrations in-memory" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    const stmt = try store.db.prepare("PRAGMA user_version");
    defer stmt.deinit();
    const row = try stmt.one(struct { user_version: i32 }, .{}, .{});

    try testing.expect(row != null);
    try testing.expectEqual(@as(i32, 2), row.?.user_version); // Expect V2
}

test "Store: registers package and maps associated file hashes" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("math.kup", "aabbccddeeff");

    try store.registerPackage("test-pkg", "commit123", "github", "sha256-mockhash", &files);

    const pkg_stmt = try store.db.prepare("SELECT provider, integrity, created_at FROM packages WHERE id = 'test-pkg'");
    defer pkg_stmt.deinit();
    const pkg_row = try pkg_stmt.one(struct { provider: []const u8, integrity: []const u8, created_at: i64 }, .{}, .{});

    try testing.expect(pkg_row != null);
    try testing.expectEqualStrings("github", pkg_row.?.provider);
    try testing.expectEqualStrings("sha256-mockhash", pkg_row.?.integrity);

    const file_stmt = try store.db.prepare("SELECT file_hash FROM package_files WHERE file_path = 'math.kup'");
    defer file_stmt.deinit();
    const file_row = try file_stmt.one(struct { file_hash: []const u8 }, .{}, .{});

    try testing.expect(file_row != null);
    try testing.expectEqualStrings("aabbccddeeff", file_row.?.file_hash);
}

test "Store: registerPackage is idempotent and safely ignores duplicates" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", "hash123");

    try store.registerPackage("pkg-a", "commit-a", "git", "sha256-mock", &files);
    try store.registerPackage("pkg-a", "commit-a", "git", "sha256-mock", &files);

    const stmt = try store.db.prepare("SELECT COUNT(*) as count FROM packages WHERE id = 'pkg-a'");
    defer stmt.deinit();

    const row = try stmt.one(struct { count: i32 }, .{}, .{});
    try testing.expect(row != null);
    try testing.expectEqual(@as(i32, 1), row.?.count);
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

test "Store: statement tuple bindings correctly filter query results" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var files_a = std.StringHashMap([]const u8).init(testing.allocator);
    defer files_a.deinit();
    try files_a.put("main.kup", "hashA");

    var files_b = std.StringHashMap([]const u8).init(testing.allocator);
    defer files_b.deinit();
    try files_b.put("utils.kup", "hashB");

    // Register two different commits for the same package
    try store.registerPackage("pkg-test", "commit1", "git", "sha256-1", &files_a);
    try store.registerPackage("pkg-test", "commit2", "git", "sha256-2", &files_b);

    const query =
        \\SELECT file_path, file_hash FROM package_files
        \\WHERE package_id = ? AND commit_sha = ?
    ;
    var stmt = try store.db.prepare(query);
    defer stmt.deinit();

    // Query specifically for commit2
    var rows = try stmt.iterator(struct { file_path: []const u8, file_hash: []const u8 }, .{ "pkg-test", "commit2" });

    const row = (try rows.next()) orelse return error.MissingRow;
    try testing.expectEqualStrings("utils.kup", row.file_path);
    try testing.expectEqualStrings("hashB", row.file_hash);

    // Ensure it strictly bound the arguments and didn't bleed into commit1
    try testing.expect((try rows.next()) == null);
}
