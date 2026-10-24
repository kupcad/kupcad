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

/// What a map owns besides its keys.
pub const Values = enum {
    /// Nothing: numbers, Values the GC keeps.
    borrowed,
    /// Each value: a slice is freed, a struct deinited with the allocator.
    owned,
};

/// Frees what `map` owns, its keys and, as `values` says, its values, and the map: a
/// managed or unmanaged string hash map, or a string array hash map.
pub fn deinit(map: anytype, allocator: std.mem.Allocator, comptime values: Values) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (values == .owned) freeValue(allocator, entry.value_ptr);
    }
    if (@hasField(@TypeOf(map.*), "unmanaged")) map.deinit() else map.deinit(allocator);
}

/// Frees what the entry `kv`, taken out of such a map (`fetchRemove`, `fetchSwapRemove`),
/// owned: its key and, as `values` says, its value.
pub fn freeEntry(allocator: std.mem.Allocator, kv: anytype, comptime values: Values) void {
    allocator.free(kv.key);
    var v = kv.value;
    if (values == .owned) freeValue(allocator, &v);
}

fn freeValue(allocator: std.mem.Allocator, v: anytype) void {
    const V = @TypeOf(v.*);
    switch (@typeInfo(V)) {
        .pointer => |p| if (p.size == .slice) return allocator.free(v.*),
        .@"struct" => if (@hasDecl(V, "deinit")) return v.deinit(allocator),
        else => {},
    }
    @compileError("an owned value is a slice or has a pub deinit(allocator), not " ++ @typeName(V));
}
