const std = @import("std");
const testing = std.testing;
const rounded_rect = @import("rounded_rect.zig");

test "rounded rect: every corner's points lie on its circle, a quarter turn each, counter-clockwise" {
    const rect = rounded_rect.RoundedRect{ .x = 20, .y = 10, .center = true, .radius = 3, .segments = 16 };
    var pts: std.ArrayList([2]f64) = .empty;
    defer pts.deinit(testing.allocator);
    try rect.appendPoints(testing.allocator, &pts);
    const corners = rect.corners();
    // 16 a turn is 4 chords a quarter, 5 points each
    try testing.expectEqual(@as(usize, 20), pts.items.len);
    for (corners) |corner| {
        try testing.expectEqual(@as(usize, 5), corner.count);
        for (pts.items[corner.first..][0..corner.count]) |p| {
            try testing.expectApproxEqAbs(@as(f64, 3), std.math.hypot(p[0] - corner.center[0], p[1] - corner.center[1]), 1e-12);
        }
    }
    try testing.expectEqual([2]f64{ 7, -2 }, corners[0].center);
    try testing.expectEqual([2]f64{ -7, -2 }, corners[3].center);
    // Counter-clockwise: the shoelace area is positive, the full rectangle's less the corners
    var twice: f64 = 0;
    for (pts.items, 0..) |p, i| {
        const q = pts.items[(i + 1) % pts.items.len];
        twice += p[0] * q[1] - q[0] * p[1];
    }
    try testing.expect(twice / 2 > 200 - 4 * 9 and twice / 2 < 200);
}

test "rounded rect: the radius keeps to half the shorter side, and a corner is never one chord" {
    const rect = rounded_rect.RoundedRect{ .x = 10, .y = 4, .center = false, .radius = 5, .segments = 5 };
    try testing.expectEqual(@as(f64, 2), rect.safeRadius());
    try testing.expectEqual(@as(usize, 2), rounded_rect.quarterArcSegments(5));
    try testing.expectEqual(@as(usize, 1), rounded_rect.quarterArcSegments(4));
    try testing.expectEqual(@as(usize, 16), rounded_rect.quarterArcSegments(64));
    try testing.expectEqual(@as(usize, 3), rect.corners()[0].count);
}
