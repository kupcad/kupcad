const std = @import("std");
const testing = std.testing;
const owned_keys = @import("owned_keys.zig");

test "owned keys: a new key is copied, an existing one kept, a failed copy undone" {
    var unmanaged: std.StringHashMapUnmanaged(u32) = .empty;
    defer owned_keys.deinit(&unmanaged, testing.allocator, .borrowed);
    var key_buf = "part".*;
    const first = try owned_keys.getOrPutOwned(&unmanaged, testing.allocator, &key_buf);
    first.value_ptr.* = 1;
    key_buf[0] = 'P'; // the caller's slice changes; the map's copy doesn't
    try testing.expectEqual(@as(?u32, 1), unmanaged.get("part"));
    try testing.expect((try owned_keys.getOrPutOwned(&unmanaged, testing.allocator, "part")).found_existing);

    // The copy fails after the entry was made: the entry goes with it.
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var managed = std.StringHashMap(u32).init(fba.allocator());
    try managed.ensureTotalCapacity(4);
    var failing = std.testing.FailingAllocator.init(fba.allocator(), .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, owned_keys.getOrPutOwned(&managed, failing.allocator(), "lost"));
    try testing.expectEqual(@as(u32, 0), managed.count());
}

/// A value that owns what it holds, as ParamValues does.
const Owner = struct {
    text: []u8,

    pub fn deinit(self: *Owner, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

test "owned keys: a map's keys and values are freed with it, and with an entry taken out" {
    // The testing allocator fails the test on anything left unfreed
    var texts: std.StringHashMapUnmanaged([]u8) = .empty;
    defer owned_keys.deinit(&texts, testing.allocator, .owned);
    var owners: std.array_hash_map.String(Owner) = .empty;
    defer owned_keys.deinit(&owners, testing.allocator, .owned);
    var managed = std.StringHashMap([]const u8).init(testing.allocator);
    defer owned_keys.deinit(&managed, testing.allocator, .owned);
    for ([_][]const u8{ "a.kup", "b.kup" }) |key| {
        (try owned_keys.getOrPutOwned(&texts, testing.allocator, key)).value_ptr.* = try testing.allocator.dupe(u8, "cube(1)");
        try owners.put(testing.allocator, try testing.allocator.dupe(u8, key), .{ .text = try testing.allocator.dupe(u8, "{}") });
        (try owned_keys.getOrPutOwned(&managed, testing.allocator, key)).value_ptr.* = try testing.allocator.dupe(u8, "x");
    }
    owned_keys.freeEntry(testing.allocator, texts.fetchRemove("a.kup").?, .owned);
    owned_keys.freeEntry(testing.allocator, owners.fetchSwapRemove("a.kup").?, .owned);
    try testing.expectEqual(@as(usize, 1), texts.count());
    try testing.expectEqual(@as(usize, 1), owners.count());
}
