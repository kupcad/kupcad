const std = @import("std");
const testing = std.testing;
const trig = @import("trig.zig");

test "trig: the barrier changes no value, zeros and tiny arguments included" {
    const samples = [_]f64{ 0, -0.0, 1e-300, -1e-300, 1e-9, 0.5, 1, 3, -2.5, 1e9 };
    for (samples) |y| {
        try testing.expectEqual(std.math.atan(y), trig.atan(y));
        for (samples) |x| try testing.expectEqual(std.math.atan2(y, x), trig.atan2(y, x));
    }
}
