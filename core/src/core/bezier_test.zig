const std = @import("std");
const testing = std.testing;
const bezier = @import("bezier.zig");

test "Bezier: a quadratic raised to a cubic is the same curve, run back by swapping its controls" {
    const cubic = bezier.quadraticAsCubic(.{ 0, 0 }, .{ 1, 2 }, .{ 2, 0 });
    try testing.expectApproxEqAbs(2.0 / 3.0, cubic.c1[0], 1e-12);
    try testing.expectApproxEqAbs(4.0 / 3.0, cubic.c1[1], 1e-12);
    try testing.expectApproxEqAbs(4.0 / 3.0, cubic.c2[0], 1e-12);
    try testing.expectApproxEqAbs(4.0 / 3.0, cubic.c2[1], 1e-12);
    // The quadratic's midpoint: a quarter of each end and half the control
    const mid = bezier.pointOn(.{ 0, 0 }, cubic, .{ 2, 0 }, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 1), mid[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), mid[1], 1e-12);
    try testing.expectEqual([2]f64{ 0, 0 }, bezier.pointOn(.{ 0, 0 }, cubic, .{ 2, 0 }, 0));
    try testing.expectEqual([2]f64{ 2, 0 }, bezier.pointOn(.{ 0, 0 }, cubic, .{ 2, 0 }, 1));
    const back = cubic.reversed();
    try testing.expectEqual(cubic.c1, back.c2);
    try testing.expectEqual(cubic.c2, back.c1);
}

test "Bezier: Flattens a perfectly straight quadratic line to a single segment" {
    var points: std.ArrayList([2]f64) = .empty;
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
    var points: std.ArrayList([2]f64) = .empty;
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
