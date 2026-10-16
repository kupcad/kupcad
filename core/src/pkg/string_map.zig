//! The string-to-string maps the package manager keeps (dependencies, path -> blob hash),
//! whose keys and values are owned copies.

const std = @import("std");

pub const StringMap = std.StringHashMap([]const u8);

/// Frees every key and value of `map`, then the map.
pub fn deinitOwned(allocator: std.mem.Allocator, map: *StringMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}
