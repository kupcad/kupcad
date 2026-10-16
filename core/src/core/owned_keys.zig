//! String-keyed maps that own their keys: an entry outlives the slice it was looked up by
//! (a path in a constant that the GC may sweep, an alias in a parsed document).

const std = @import("std");

/// `map.getOrPut(key)`, the key copied into `allocator` when the entry is new. A copy that
/// fails takes the new entry out again, so the map never holds a borrowed key. `map` is a
/// managed or unmanaged string hash map.
pub fn getOrPutOwned(map: anytype, allocator: std.mem.Allocator, key: []const u8) !@TypeOf(map.*).GetOrPutResult {
    const managed = @hasField(@TypeOf(map.*), "unmanaged");
    const gop = if (managed) try map.getOrPut(key) else try map.getOrPut(allocator, key);
    if (!gop.found_existing) {
        gop.key_ptr.* = allocator.dupe(u8, key) catch |err| {
            map.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    return gop;
}
