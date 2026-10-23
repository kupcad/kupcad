const std = @import("std");
const testing = std.testing;
const Span = @import("sequence.zig").Span;

test "sequence: a span counts every value it walks, float steps and either way round" {
    const cases = [_]struct { span: Span, count: f64 }{
        .{ .span = .{ .start = 0, .end = 1, .step = 0.1, .is_exclusive = false }, .count = 11 },
        .{ .span = .{ .start = 0, .end = 1, .step = 0.1, .is_exclusive = true }, .count = 10 },
        // 0.3 / 0.1 is 2.9999999999999996: still four values, as in Ruby
        .{ .span = .{ .start = 0, .end = 0.3, .step = 0.1, .is_exclusive = false }, .count = 4 },
        .{ .span = .{ .start = 5, .end = 1, .step = -1, .is_exclusive = false }, .count = 5 },
        .{ .span = .{ .start = 5, .end = 1, .step = -1, .is_exclusive = true }, .count = 4 },
        .{ .span = .{ .start = 1, .end = 0, .step = 1, .is_exclusive = false }, .count = 0 }, // the wrong way
        .{ .span = .{ .start = 1, .end = 1, .step = 1, .is_exclusive = true }, .count = 0 },
        .{ .span = .{ .start = 1, .end = 1, .step = 1, .is_exclusive = false }, .count = 1 },
        .{ .span = .{ .start = 0, .end = 10, .step = 3, .is_exclusive = false }, .count = 4 }, // 0, 3, 6, 9
    };
    for (cases) |case| {
        errdefer std.debug.print("span: {any}\n", .{case.span});
        try testing.expectEqual(case.count, case.span.count());
    }
}

test "sequence: each value is computed from the start, and the last never overshoots the end" {
    const span = Span{ .start = 0, .end = 1, .step = 0.1, .is_exclusive = false };
    // From the start, not by adding: the 7th is 0.7 to the bit (0.1 added seven times isn't)
    try testing.expectEqual(@as(f64, 7) * 0.1, span.at(7));
    try testing.expectEqual(@as(f64, 1), span.at(10));
    try testing.expectEqual(@as(f64, 1), span.at(11)); // clamped
    const down = Span{ .start = 5, .end = 1, .step = -2, .is_exclusive = false };
    try testing.expectEqual(@as(f64, 3), down.at(1));
    try testing.expectEqual(@as(f64, 1), down.at(2));
    try testing.expectEqual(@as(f64, 1), down.at(3)); // clamped going down
}
