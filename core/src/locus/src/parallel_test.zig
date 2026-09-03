const std = @import("std");
const parallel = @import("parallel.zig");

test "Parallel: Safely executes parallelFor over an array" {
    const alloc = std.testing.allocator;
    const count: usize = 1000;

    const data = try alloc.alloc(f64, count);
    defer alloc.free(data);

    // Initialize with zeros
    @memset(data, 0.0);

    const Ctx = struct {
        slice: []f64,
    };
    var ctx = Ctx{ .slice = data };

    // Run parallel job to set each element to its index
    parallel.parallelFor(0, count, Ctx, &ctx, struct {
        fn doWork(i: usize, c: *Ctx) void {
            c.slice[i] = @as(f64, @floatFromInt(i));
        }
    }.doWork);

    // Verify all 1000 items were processed successfully
    var sum: f64 = 0.0;
    for (data, 0..) |val, i| {
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)), val);
        sum += val;
    }

    // Gauss sum formula: n(n-1)/2 = 1000 * 999 / 2 = 499500
    try std.testing.expectEqual(@as(f64, 499500.0), sum);
}
