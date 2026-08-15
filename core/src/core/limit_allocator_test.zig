const std = @import("std");
const testing = std.testing;
const LimitAllocator = @import("limit_allocator.zig").LimitAllocator;

test "LimitAllocator: successfully allocates within limits and tracks memory" {
    var limit_alloc = LimitAllocator.init(testing.allocator, 100);
    const alloc = limit_alloc.allocator();

    const slice = try alloc.alloc(u8, 50);
    try testing.expectEqual(@as(usize, 50), limit_alloc.bytes_allocated);

    alloc.free(slice);
    try testing.expectEqual(@as(usize, 0), limit_alloc.bytes_allocated);
}

test "LimitAllocator: strictly prevents allocations beyond max_bytes" {
    var limit_alloc = LimitAllocator.init(testing.allocator, 100);
    const alloc = limit_alloc.allocator();

    // Attempting to allocate 150 bytes in a 100-byte sandbox should fail
    const result = alloc.alloc(u8, 150);
    try testing.expectError(error.OutOfMemory, result);

    // Ensure bytes_allocated didn't falsely increment
    try testing.expectEqual(@as(usize, 0), limit_alloc.bytes_allocated);
}

test "LimitAllocator: correctly tracks memory during dynamic resizing/remapping" {
    // Increased to 150 to accommodate the out-of-place realloc fallback spike (40 + 80 = 120)
    var limit_alloc = LimitAllocator.init(testing.allocator, 150);
    const alloc = limit_alloc.allocator();

    // Initial allocation
    var slice = try alloc.alloc(u8, 40);
    try testing.expectEqual(@as(usize, 40), limit_alloc.bytes_allocated);

    // Grow the allocation within limits (tests resize/remap/fallback)
    // Peak memory required: 120 bytes. Net memory after free: 80 bytes.
    slice = try alloc.realloc(slice, 80);
    try testing.expectEqual(@as(usize, 80), limit_alloc.bytes_allocated);

    // Attempt to grow beyond the limit
    const failed_grow = alloc.realloc(slice, 160);
    try testing.expectError(error.OutOfMemory, failed_grow);

    // The previous bytes_allocated should remain untouched after a failed resize
    try testing.expectEqual(@as(usize, 80), limit_alloc.bytes_allocated);

    // Shrink the allocation
    slice = try alloc.realloc(slice, 30);
    try testing.expectEqual(@as(usize, 30), limit_alloc.bytes_allocated);

    // Free everything and verify zero leaks
    alloc.free(slice);
    try testing.expectEqual(@as(usize, 0), limit_alloc.bytes_allocated);
}

test "LimitAllocator: handles multiple disjoint allocations securely" {
    var limit_alloc = LimitAllocator.init(testing.allocator, 100);
    const alloc = limit_alloc.allocator();

    const chunk1 = try alloc.alloc(u8, 40);
    const chunk2 = try alloc.alloc(u8, 40);

    try testing.expectEqual(@as(usize, 80), limit_alloc.bytes_allocated);

    // The remaining 20 bytes should not accommodate a 30-byte request
    const chunk3_err = alloc.alloc(u8, 30);
    try testing.expectError(error.OutOfMemory, chunk3_err);

    alloc.free(chunk1);
    // After freeing chunk1, bytes_allocated drops to 40, so the 30-byte request should now succeed
    try testing.expectEqual(@as(usize, 40), limit_alloc.bytes_allocated);

    const chunk3 = try alloc.alloc(u8, 30);
    try testing.expectEqual(@as(usize, 70), limit_alloc.bytes_allocated);

    alloc.free(chunk2);
    alloc.free(chunk3);
    try testing.expectEqual(@as(usize, 0), limit_alloc.bytes_allocated);
}
