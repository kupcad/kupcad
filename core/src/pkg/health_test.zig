const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const Doctor = @import("health.zig").Doctor;
const writeAbs = @import("test_helpers.zig").writeAbs;

/// `data`'s blob name: its SHA-256, in lower-case hex.
fn blobName(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "Doctor: healMissingBlobs evicts blob and package records when physical files vanish" {
    const warnings = @import("../test_support.zig").expectWarnings();
    defer warnings.restore();

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var doc = Doctor.init(testing.allocator, testing.io, &cafs, &store, .{ .io = testing.io, .capture = &out.writer });

    // 1. Register a package whose blob is not on disk
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("path", "missing_hash");
    try store.registerPackage("pkg", "sha", "github", "sha256-x", &files);

    // 2. Heal
    try doc.run(); // Executes all healing routines
    // The report is printed, not logged (release builds hide info logging).
    try testing.expect(std.mem.find(u8, out.written(), "System health check complete.") != null);

    // 3. Verify DB eviction for missing physical files
    const stmt1 = try store.db.prepare("SELECT 1 FROM files WHERE hash = 'missing_hash'");
    defer stmt1.deinit();
    const row1 = try stmt1.one(struct { val: i32 }, .{});
    try testing.expect(row1 == null);

    const stmt2 = try store.db.prepare("SELECT 1 FROM package_files WHERE file_hash = 'missing_hash'");
    defer stmt2.deinit();
    const row2 = try stmt2.one(struct { val: i32 }, .{});
    try testing.expect(row2 == null);

    // The package itself is evicted too, otherwise it still looks cached and
    // linking fails on the missing blob (audit fix).
    try testing.expect(!try store.hasPackage("pkg", "sha"));
}

test "Doctor: healOrphanedBlobs indexes physical files missing from DB" {
    const warnings = @import("../test_support.zig").expectWarnings();
    defer warnings.restore();

    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var doc = Doctor.init(testing.allocator, testing.io, &cafs, &store, .{ .io = testing.io, .capture = &out.writer });

    // 1. Seed physical files WITHOUT creating DB records: a blob, one that doesn't hold
    // what its name says, and a file that is no blob
    const orphan = blobName("orphan data");
    const corrupt = blobName("what it held");
    for ([_][]const u8{ &orphan, &corrupt, ".DS_Store" }, [_][]const u8{ "orphan data", "changed", "x" }) |name, data| {
        const path = try cafs.blobPath(name);
        defer testing.allocator.free(path);
        try writeAbs(path, data);
    }

    // 2. Heal
    try doc.run();

    // 3. The blob indexed, the corrupt one removed (it used to be indexed by its name alone),
    // the stray file left as it is
    const stmt = try store.db.prepare("SELECT size FROM files WHERE hash = ?");
    defer stmt.deinit();
    const row = try stmt.one(struct { size: i64 }, .{&orphan});
    try testing.expect(row != null);
    try testing.expectEqual(@as(i64, 11), row.?.size); // "orphan data".len == 11
    try testing.expect(!try store.hasBlob(&corrupt));
    const corrupt_path = try cafs.blobPath(&corrupt);
    defer testing.allocator.free(corrupt_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, corrupt_path, .{}));
    try testing.expect(!try store.hasBlob(".DS_Store"));
}

test "Doctor: a listed blob that doesn't hold what its name says is evicted and removed" {
    const warnings = @import("../test_support.zig").expectWarnings();
    defer warnings.restore();
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();
    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    // Listed, there, and changed since: it was taken for whole because it was there
    const name = blobName("main.kup's text");
    var files = std.StringHashMap([]const u8).init(testing.allocator);
    defer files.deinit();
    try files.put("main.kup", &name);
    try store.registerPackage("pkg", "sha", "github", "sha256-x", &files);
    const path = try cafs.blobPath(&name);
    defer testing.allocator.free(path);
    try writeAbs(path, "changed in the store");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var doc = Doctor.init(testing.allocator, testing.io, &cafs, &store, .{ .io = testing.io, .capture = &out.writer });
    try doc.run();
    try testing.expect(!try store.hasBlob(&name));
    try testing.expect(!try store.hasPackage("pkg", "sha"));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));
}

// Audit fix: a CAFS file name crafted as SQL was formatted into the lookup, which
// then matched any row, so the orphan was never indexed. (Prune half: gc_test.zig.)
test "Doctor: healOrphanedBlobs binds blob names as SQL parameters" {
    const warnings = @import("../test_support.zig").expectWarnings(); // the re-indexed blob
    defer warnings.restore();
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    var cafs = try Cafs.init(testing.allocator, testing.io, tmp_path, mem_vfs.vfs());
    defer cafs.deinit();

    var store = try Store.init(testing.io, ":memory:");
    defer store.deinit();

    const evil_name = "zz' OR '1'='1";
    // Bound, it matches no row; formatted into the query, it matched any (the orphan was
    // then never indexed)
    try store.db.exec("INSERT INTO files (hash, size, created_at) VALUES ('keep', 0, 0)", .{});
    try testing.expect(!try store.hasBlob(evil_name));
    // A file of that name is none of the store's: left as it is, and unindexed
    const path = try cafs.blobPath(evil_name);
    defer testing.allocator.free(path);
    try writeAbs(path, "x");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var doc = Doctor.init(testing.allocator, testing.io, &cafs, &store, .{ .io = testing.io, .capture = &out.writer });
    try doc.run();
    try testing.expect(!try store.hasBlob(evil_name));
    try std.Io.Dir.cwd().access(testing.io, path, .{});
}
