const std = @import("std");
const testing = std.testing;
const bspline = @import("bspline.zig");
const path = @import("path.zig");
const bezier = @import("bezier.zig");

fn expectPoint(expected: [2]f64, actual: [2]f64, tolerance: f64) !void {
    try testing.expectApproxEqAbs(expected[0], actual[0], tolerance);
    try testing.expectApproxEqAbs(expected[1], actual[1], tolerance);
}

fn free(spline: bspline.Spline) void {
    testing.allocator.free(spline.knots);
    testing.allocator.free(spline.controls);
}

/// The parameter of each of `points` along them: its chord length over the whole.
fn chordParams(comptime n: usize, points: [n][2]f64) [n]f64 {
    var params: [n]f64 = undefined;
    var total: f64 = 0;
    params[0] = 0;
    for (1..n) |k| {
        total += std.math.hypot(points[k][0] - points[k - 1][0], points[k][1] - points[k - 1][1]);
        params[k] = total;
    }
    for (&params) |*u| u.* /= total;
    return params;
}

test "bspline: a cubic through four points is one Bézier, through each at its chord share" {
    const points = [_][2]f64{ .{ 0, 0 }, .{ 3, 4 }, .{ 9, 4 }, .{ 12, 0 } };
    const spline = try bspline.through(testing.allocator, &points, null, null);
    defer free(spline);
    try testing.expectEqual(@as(usize, 3), spline.degree);
    try testing.expectEqual(@as(usize, 4), spline.controls.len);
    var segments: std.ArrayList(path.Segment) = .empty;
    defer segments.deinit(testing.allocator);
    const start = (try bspline.Spline.appendSegments(spline, testing.allocator, &segments, 1e-9)).?;
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    const piece = segments.items[0];
    for (points, chordParams(4, points)) |q, u| try expectPoint(q, bezier.pointOn(start, piece.cubic.?, piece.to, u), 1e-12);
}

test "bspline: through many points, along end tangents, a line and a quadratic for fewer" {
    // A sine's half wave of 200 points: through each, the banded system solved as it is
    var wave: [200][2]f64 = undefined;
    for (&wave, 0..) |*q, k| {
        const x = @as(f64, @floatFromInt(k)) / 199 * std.math.pi;
        q.* = .{ x * 10, @sin(x) * 10 };
    }
    const spline = try bspline.through(testing.allocator, &wave, null, null);
    defer free(spline);
    for (wave, chordParams(200, wave)) |q, u| try expectPoint(q, spline.pointAt(u), 1e-9);

    // Leaving straight up and arriving straight down, through the middle point
    const arch = [_][2]f64{ .{ 0, 0 }, .{ 5, 5 }, .{ 10, 0 } };
    const along = try bspline.through(testing.allocator, &arch, .{ 0, 2 }, .{ 0, -1 });
    defer free(along);
    try testing.expectEqual(@as(usize, 5), along.controls.len);
    try testing.expectApproxEqAbs(@as(f64, 0), along.controls[1][0], 1e-12);
    try testing.expect(along.controls[1][1] > 0);
    try testing.expectApproxEqAbs(@as(f64, 10), along.controls[3][0], 1e-12);
    try testing.expect(along.controls[3][1] > 0);
    try expectPoint(.{ 5, 5 }, along.pointAt(0.5), 1e-12);

    const two = try bspline.through(testing.allocator, &.{ .{ 0, 0 }, .{ 4, 3 } }, null, null);
    defer free(two);
    try testing.expectEqual(@as(usize, 1), two.degree);
    const three = try bspline.through(testing.allocator, &arch, null, null);
    defer free(three);
    try testing.expectEqual(@as(usize, 2), three.degree);
    try expectPoint(.{ 5, 5 }, three.pointAt(0.5), 1e-12);
}

test "bspline: a loop through eight points of a circle, one tangent where it closes, is near the circle" {
    var ring: [9][2]f64 = undefined;
    for (&ring, 0..) |*q, k| {
        const a = @as(f64, @floatFromInt(k)) * std.math.pi / 4;
        q.* = .{ 10 * @cos(a), 10 * @sin(a) };
    }
    ring[8] = ring[0];
    const seam = [2]f64{ ring[1][0] - ring[7][0], ring[1][1] - ring[7][1] };
    const spline = try bspline.through(testing.allocator, &ring, seam, seam);
    defer free(spline);
    var segments: std.ArrayList(path.Segment) = .empty;
    defer segments.deinit(testing.allocator);
    const start = (try bspline.Spline.appendSegments(spline, testing.allocator, &segments, 1e-9)).?;
    try expectPoint(start, segments.items[segments.items.len - 1].to, 1e-12);
    try testing.expectApproxEqRel(100 * std.math.pi, path.signedArea(start, segments.items), 3e-3);
    for (0..64) |k| {
        const p = spline.pointAt(@as(f64, @floatFromInt(k)) / 64);
        try testing.expectApproxEqAbs(@as(f64, 10), std.math.hypot(p[0], p[1]), 0.05);
    }
}
