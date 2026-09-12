const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;

test "Store: initializes and runs SQLite migrations in-memory" {
    // ":memory:" forces SQLite to use a volatile RAM database, bypassing the disk entirely
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    const stmt = try store.db.prepare("PRAGMA user_version");
    defer stmt.deinit();
    const row = try stmt.one(struct { user_version: i32 }, .{}, .{});

    try testing.expect(row != null);
    try testing.expectEqual(@as(i32, 1), row.?.user_version);
}

test "Store: registers package and maps associated file hashes" {
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("math.kup", "aabbccddeeff");

    try store.registerPackage("test-pkg", "commit123", "github", &files);

    const pkg_stmt = try store.db.prepare("SELECT provider, created_at FROM packages WHERE id = 'test-pkg'");
    defer pkg_stmt.deinit();
    const pkg_row = try pkg_stmt.one(struct { provider: []const u8, created_at: i64 }, .{}, .{});

    try testing.expect(pkg_row != null);
    try testing.expectEqualStrings("github", pkg_row.?.provider);

    const file_stmt = try store.db.prepare("SELECT file_hash FROM package_files WHERE file_path = 'math.kup'");
    defer file_stmt.deinit();
    const file_row = try file_stmt.one(struct { file_hash: []const u8 }, .{}, .{});

    try testing.expect(file_row != null);
    try testing.expectEqualStrings("aabbccddeeff", file_row.?.file_hash);
}
