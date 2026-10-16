const std = @import("std");
const testing = std.testing;
const owned_keys = @import("owned_keys.zig");

test "owned keys: a new key is copied, an existing one kept, a failed copy undone" {
    var unmanaged: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var it = unmanaged.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        unmanaged.deinit(testing.allocator);
    }
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
