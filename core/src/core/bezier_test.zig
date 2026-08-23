const std = @import("std");
const testing = std.testing;
const bezier = @import("bezier.zig");

test "Bezier: Flattens a perfectly straight quadratic line to a single segment" {
    var points: std.ArrayListUnmanaged([2]f64) = .empty;
    defer points.deinit(testing.allocator);

    // p0, p1 (midpoint on the line), p2
    try bezier.flattenQuadratic(testing.allocator, &points, .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 }, 0.001 // Tight tolerance
    );

    // Because it's perfectly straight, the algorithm shouldn't subdivide.
    // It should just append the end point (p2).
    try testing.expectEqual(@as(usize, 1), points.items.len);
    try testing.expectEqual(10.0, points.items[0][0]);
}

test "Bezier: Adaptively subdivides sharp cubic curve" {
    var points: std.ArrayListUnmanaged([2]f64) = .empty;
    defer points.deinit(testing.allocator);

    // A sharp "U" shaped cubic curve
    try bezier.flattenCubic(testing.allocator, &points, .{ 0, 0 }, .{ 0, 10 }, .{ 10, 10 }, .{ 10, 0 }, 0.1 // Standard CAD tolerance squared
    );

    // A U-shape cannot be represented by a straight line, so it must have subdivided
    // into a high-resolution array of points.
    try testing.expect(points.items.len > 5);

    // The final point emitted MUST be exactly the mathematical end point p3
    const last_point = points.items[points.items.len - 1];
    try testing.expectEqual(10.0, last_point[0]);
    try testing.expectEqual(0.0, last_point[1]);
}
