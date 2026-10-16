const std = @import("std");
const testing = std.testing;
const clock = @import("clock.zig");

test "Clock: seconds since the epoch round down, before the epoch too" {
    try testing.expectEqual(@as(i64, 1), clock.unixSeconds(.{ .nanoseconds = 1_500_000_000 }));
    try testing.expectEqual(@as(i64, 0), clock.unixSeconds(.{ .nanoseconds = 0 }));
    // Truncation, as the store used, made this 0, while the pruner's floor made it -1.
    try testing.expectEqual(@as(i64, -1), clock.unixSeconds(.{ .nanoseconds = -1 }));
    try testing.expect(clock.nowSeconds(testing.io) > 1_700_000_000);
}
