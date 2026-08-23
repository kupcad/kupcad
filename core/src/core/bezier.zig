const std = @import("std");

inline fn midpoint(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ (a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0 };
}

/// Calculates the squared distance from point `p` to the line segment `v-w`
fn distToSegmentSq(p: [2]f64, v: [2]f64, w: [2]f64) f64 {
    const l2 = std.math.pow(f64, v[0] - w[0], 2) + std.math.pow(f64, v[1] - w[1], 2);
    if (l2 == 0) return std.math.pow(f64, p[0] - v[0], 2) + std.math.pow(f64, p[1] - v[1], 2);

    var t = ((p[0] - v[0]) * (w[0] - v[0]) + (p[1] - v[1]) * (w[1] - v[1])) / l2;
    t = std.math.clamp(t, 0.0, 1.0);

    const proj = [2]f64{ v[0] + t * (w[0] - v[0]), v[1] + t * (w[1] - v[1]) };
    return std.math.pow(f64, p[0] - proj[0], 2) + std.math.pow(f64, p[1] - proj[1], 2);
}

/// Recursively flattens a Quadratic Bézier curve.
/// We do NOT append p0, because the previous curve/line/moveTo will have already appended it.
pub fn flattenQuadratic(
    allocator: std.mem.Allocator,
    points: *std.ArrayListUnmanaged([2]f64),
    p0: [2]f64,
    p1: [2]f64,
    p2: [2]f64,
    toleranceSq: f64,
) !void {
    const d = distToSegmentSq(p1, p0, p2);

    // If the control point is close enough to the straight line p0-p2, it's flat!
    if (d <= toleranceSq) {
        try points.append(allocator, p2);
        return;
    }

    // De Casteljau subdivision
    const p01 = midpoint(p0, p1);
    const p12 = midpoint(p1, p2);
    const p012 = midpoint(p01, p12); // Point on the curve at t=0.5

    try flattenQuadratic(allocator, points, p0, p01, p012, toleranceSq);
    try flattenQuadratic(allocator, points, p012, p12, p2, toleranceSq);
}

/// Recursively flattens a Cubic Bézier curve.
pub fn flattenCubic(
    allocator: std.mem.Allocator,
    points: *std.ArrayListUnmanaged([2]f64),
    p0: [2]f64,
    p1: [2]f64,
    p2: [2]f64,
    p3: [2]f64,
    toleranceSq: f64,
) !void {
    const d1 = distToSegmentSq(p1, p0, p3);
    const d2 = distToSegmentSq(p2, p0, p3);

    // If both control points are close to the straight line p0-p3, it's flat!
    if (d1 <= toleranceSq and d2 <= toleranceSq) {
        try points.append(allocator, p3);
        return;
    }

    // De Casteljau subdivision
    const p01 = midpoint(p0, p1);
    const p12 = midpoint(p1, p2);
    const p23 = midpoint(p2, p3);

    const p012 = midpoint(p01, p12);
    const p123 = midpoint(p12, p23);

    const p0123 = midpoint(p012, p123); // Point on the curve at t=0.5

    try flattenCubic(allocator, points, p0, p01, p012, p0123, toleranceSq);
    try flattenCubic(allocator, points, p0123, p123, p23, p3, toleranceSq);
}
