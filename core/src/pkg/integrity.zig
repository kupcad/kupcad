//! A package's integrity: a SHA-256 over its `path -> blob hash` map, in sorted order and
//! length-prefixed so two different maps never hash alike, as `kupcad.lock` pins it
//! (`compute`, `verify`). Pure hashing; the store only records the result.

const std = @import("std");
const string_map = @import("string_map.zig");

/// Computes a deterministic Merkle-style checksum of extracted package files.
/// Each path and hash is length-prefixed (u64 LE) so distinct file maps can
/// never produce the same hash input.
pub fn compute(allocator: std.mem.Allocator, files_map: *const std.StringHashMap([]const u8)) ![]const u8 {
    var paths = std.ArrayListUnmanaged([]const u8).empty;
    defer paths.deinit(allocator);

    var it = files_map.keyIterator();
    while (it.next()) |k| try paths.append(allocator, k.*);

    // Deterministic sorting ensures the hash is identical across environments
    string_map.sortKeys(paths.items);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths.items) |path| {
        hashLenPrefixed(&hasher, path);
        hashLenPrefixed(&hasher, files_map.get(path).?);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.print("sha256-{s}", .{hex});
}

/// Hashes `bytes` after its length.
fn hashLenPrefixed(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .little);
    hasher.update(&len_buf);
    hasher.update(bytes);
}

/// Fails with error.IntegrityMismatch unless `files_map` hashes to `expected`.
pub fn verify(
    allocator: std.mem.Allocator,
    files_map: *const std.StringHashMap([]const u8),
    expected: []const u8,
) !void {
    const actual = try compute(allocator, files_map);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, expected)) return error.IntegrityMismatch;
}
