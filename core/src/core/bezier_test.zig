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

test "bezier: an ellipse's arc as a cubic, its controls along its tangents" {
    // A quarter of the unit circle: the controls the well-known 0.5523 out along the tangents
    const circle = bezier.Ellipse.circle(.{ 0, 0 }, 1);
    const quarter = circle.cubic(0, std.math.pi / 2.0, circle.at(0), circle.at(std.math.pi / 2.0));
    const kappa = 4.0 / 3.0 * (std.math.sqrt2 - 1);
    try testing.expectApproxEqAbs(@as(f64, 1), quarter.c1[0], 1e-12);
    try testing.expectApproxEqAbs(kappa, quarter.c1[1], 1e-12);
    try testing.expectApproxEqAbs(kappa, quarter.c2[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), quarter.c2[1], 1e-12);
    // Clockwise, the controls lead the other way
    const back = circle.cubic(0, -std.math.pi / 2.0, circle.at(0), circle.at(-std.math.pi / 2.0));
    try testing.expectApproxEqAbs(-kappa, back.c1[1], 1e-12);
    // An ellipse turned a quarter: its x axis along y, so its point at 0 is up, at 2 out
    const turned = bezier.Ellipse{ .center = .{ 5, 0 }, .rx = 2, .ry = 1, .axis = .{ 0, 1 } };
    const p = turned.at(0);
    try testing.expectApproxEqAbs(@as(f64, 5), p[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2), p[1], 1e-12);
    const d = turned.tangentAt(0);
    try testing.expectApproxEqAbs(@as(f64, -1), d[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), d[1], 1e-12);
}
