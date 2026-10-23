const std = @import("std");
const testing = std.testing;
const loft = @import("loft.zig");

const ELL = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 5 }, .{ 5, 5 }, .{ 5, 20 }, .{ 0, 20 } };
const ELL_AREA: f64 = 175;

/// The mesh's volume by the divergence theorem: positive when its triangles turn outward.
fn volume(mesh: loft.Mesh) f64 {
    var total: f64 = 0;
    for (mesh.triangles) |t| {
        const a = mesh.points[t[0]];
        const b = mesh.points[t[1]];
        const c = mesh.points[t[2]];
        total += a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]);
    }
    return total / 6;
}

fn scaled(comptime points: []const [2]f64, comptime k: f64) [points.len][2]f64 {
    var out: [points.len][2]f64 = undefined;
    for (points, &out) |p, *q| q.* = .{ p[0] * k, p[1] * k };
    return out;
}

test "loft: an outline lofted to itself is its prism, to a smaller copy a frustum" {
    const prism = try loft.ruled(testing.allocator, &ELL, &ELL, 10);
    defer prism.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, ELL_AREA * 10), volume(prism), 1e-9);
    // Each point once on either ring: the sides two triangles a point, the ends the rest
    try testing.expectEqual(@as(usize, 2 * ELL.len), prism.points.len);
    try testing.expectEqual(@as(usize, 2 * ELL.len + 2 * (ELL.len - 2)), prism.triangles.len);
    // Similar outlines, a half the size: h/3 (A + a + √(A a))
    const half = scaled(&ELL, 0.5);
    const frustum = try loft.ruled(testing.allocator, &ELL, &half, 10);
    defer frustum.deinit(testing.allocator);
    const top_area = ELL_AREA / 4.0;
    try testing.expectApproxEqAbs(10.0 / 3.0 * (ELL_AREA + top_area + @sqrt(ELL_AREA * top_area)), volume(frustum), 1e-9);
}

test "loft: the top starts where it twists least, whichever way and from wherever it is drawn" {
    // The same square drawn clockwise and from another corner: still a prism, untwisted
    const base = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    const top = [_][2]f64{ .{ 4, 4 }, .{ 4, 0 }, .{ 0, 0 }, .{ 0, 4 } };
    const mesh = try loft.ruled(testing.allocator, &base, &top, 5);
    defer mesh.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 80), volume(mesh), 1e-9);
    for (mesh.points[0..4], mesh.points[4..]) |p, q| {
        try testing.expectEqual(p[0], q[0]);
        try testing.expectEqual(p[1], q[1]);
    }
    // A square to a triangle: the square's corners and the triangle's are each kept
    const triangle = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 2, 4 } };
    const mixed = try loft.ruled(testing.allocator, &base, &triangle, 5);
    defer mixed.deinit(testing.allocator);
    try testing.expect(mixed.points.len >= 2 * base.len);
    try testing.expect(volume(mixed) > 0);
}

test "loft: below the base for a negative height, and none for an outline of no area" {
    const below = try loft.ruled(testing.allocator, &ELL, &ELL, -10);
    defer below.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, ELL_AREA * 10), volume(below), 1e-9);
    try testing.expectEqual(@as(f64, -10), below.points[below.points.len - 1][2]);
    try testing.expectError(error.Degenerate, loft.ruled(testing.allocator, &ELL, &ELL, 0));
    try testing.expectError(error.Degenerate, loft.ruled(testing.allocator, &.{ .{ 0, 0 }, .{ 1, 0 } }, &ELL, 1));
}

test "loft: contours matched by depth and by their place in the profile's box, the nearest first" {
    const square = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const left = [_][2]f64{ .{ 1, 4 }, .{ 3, 4 }, .{ 3, 6 }, .{ 1, 6 } };
    const right = [_][2]f64{ .{ 7, 4 }, .{ 9, 4 }, .{ 9, 6 }, .{ 7, 6 } };
    // The top half the size, its holes listed the other way round
    const small = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 5 }, .{ 0, 5 } };
    const small_right = [_][2]f64{ .{ 3.5, 2 }, .{ 4.5, 2 }, .{ 4.5, 3 }, .{ 3.5, 3 } };
    const small_left = [_][2]f64{ .{ 0.5, 2 }, .{ 1.5, 2 }, .{ 1.5, 3 }, .{ 0.5, 3 } };
    var mismatch: loft.Mismatch = undefined;
    const pairs = try loft.match(testing.allocator, &.{ &square, &left, &right }, &.{ &small_right, &small, &small_left }, &mismatch);
    defer testing.allocator.free(pairs);
    try testing.expectEqualSlices(loft.Pair, &.{
        .{ .base = 0, .top = 1, .depth = 0 },
        .{ .base = 1, .top = 2, .depth = 1 },
        .{ .base = 2, .top = 0, .depth = 1 },
    }, pairs);
    // A hole the top hasn't
    try testing.expectError(error.Mismatch, loft.match(testing.allocator, &.{ &square, &left }, &.{&small}, &mismatch));
    try testing.expectEqual(loft.Mismatch{ .depth = 1, .base = 1, .top = 0 }, mismatch);
}
