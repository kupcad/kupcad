//! A package's integrity: a SHA-256 over its `path -> blob hash` map, in sorted order and
//! length-prefixed so two different maps never hash alike, as `kupcad.lock` pins it
//! (`compute`, `verify`). Pure hashing; the store only records the result.

const std = @import("std");
const string_map = @import("string_map.zig");

pub const Algo = enum {
    /// v2 (lockfile >= 2.0.0): length-prefixed fields, unambiguous.
    current,
    /// v1 (lockfile 1.x): plain `path || hash` concatenation. Ambiguous
    /// (("ab","c") == ("a","bc")); only used to verify old lockfiles before upgrading them.
    legacy,
};

/// How an integrity was taken, so an old lockfile's can still be checked.
pub const Scheme = struct {
    algo: Algo = .current,
    /// The folder every path was hashed under: before lockfile 3.0.0, a git host
    /// archive's files kept its top folder (`repo-<sha>/main.kup`). Empty: none.
    root: []const u8 = "",
};

/// Computes a deterministic Merkle-style checksum of extracted package files.
/// Each path and hash is length-prefixed (u64 LE) so distinct file maps can
/// never produce the same hash input.
pub fn compute(allocator: std.mem.Allocator, files_map: *const std.StringHashMap([]const u8)) ![]const u8 {
    return computeWith(allocator, files_map, .{});
}

pub fn computeWith(allocator: std.mem.Allocator, files_map: *const std.StringHashMap([]const u8), scheme: Scheme) ![]const u8 {
    var paths = std.ArrayListUnmanaged([]const u8).empty;
    defer paths.deinit(allocator);

    var it = files_map.keyIterator();
    while (it.next()) |k| try paths.append(allocator, k.*);

    // Deterministic sorting ensures the hash is identical across environments
    string_map.sortKeys(paths.items);

    // A common folder doesn't change the order, so it is only added while hashing.
    const folder: []const []const u8 = if (scheme.root.len > 0) &.{ scheme.root, "/" } else &.{};
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths.items) |path| {
        const hash = files_map.get(path).?;
        switch (scheme.algo) {
            .current => {
                hashLenPrefixed(&hasher, folder, path);
                hashLenPrefixed(&hasher, &.{}, hash);
            },
            .legacy => {
                for (folder) |part| hasher.update(part);
                hasher.update(path);
                hasher.update(hash);
            },
        }
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.print("sha256-{s}", .{hex});
}

/// Hashes `prefix ++ bytes` after its length.
fn hashLenPrefixed(hasher: *std.crypto.hash.sha2.Sha256, prefix: []const []const u8, bytes: []const u8) void {
    var len: u64 = bytes.len;
    for (prefix) |part| len += part.len;
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, len, .little);
    hasher.update(&len_buf);
    for (prefix) |part| hasher.update(part);
    hasher.update(bytes);
}

/// Fails with error.IntegrityMismatch unless `files_map` hashes to `expected`.
pub fn verify(
    allocator: std.mem.Allocator,
    files_map: *const std.StringHashMap([]const u8),
    expected: []const u8,
    scheme: Scheme,
) !void {
    const actual = try computeWith(allocator, files_map, scheme);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, expected)) return error.IntegrityMismatch;
}
