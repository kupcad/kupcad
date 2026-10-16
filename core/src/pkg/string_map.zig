//! The string-to-string maps the package manager keeps (dependencies, path -> blob hash),
//! whose keys and values are owned copies.

const std = @import("std");

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

/// Frees every key and value of `map`, then the map.
pub fn deinitOwned(allocator: std.mem.Allocator, map: *StringMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}
