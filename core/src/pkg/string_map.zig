//! The string-to-string maps the package manager keeps (dependencies, path -> blob hash),
//! whose keys and values are owned copies.

const std = @import("std");
const owned_keys = @import("../core/owned_keys.zig");

pub const StringMap = std.StringHashMap([]const u8);

/// Sorts `keys` byte-wise, the order the manifest, the lockfile and the integrity hash
/// write them in, so their output is the same on every machine.
pub fn sortKeys(keys: [][]const u8) void {
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

/// Sets `key` to a copy of `val` in `map`, copying the key if it is new and freeing the
/// value it replaces. The value is copied first: copied after the old one was freed, a
/// failed copy left the map holding the freed value (or a new key with none).
pub fn putOwned(allocator: std.mem.Allocator, map: *StringMap, key: []const u8, val: []const u8) !void {
    const val_copy = try allocator.dupe(u8, val);
    errdefer allocator.free(val_copy);
    const gop = try owned_keys.getOrPutOwned(map, allocator, key);
    if (gop.found_existing) allocator.free(gop.value_ptr.*);
    gop.value_ptr.* = val_copy;
}

/// Frees every key and value of `map`, then the map.
pub fn deinitOwned(allocator: std.mem.Allocator, map: *StringMap) void {
    owned_keys.deinit(map, allocator, .owned);
}
