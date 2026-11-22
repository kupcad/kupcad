//! The exact ray crossings of lines and arcs (`ray_crossing.zig`) against the crossings
//! counted the plain way where that is safe, and whole loops asked at their own vertices'
//! heights and on their own circles, where only the symbolic nudge answers alike for every
//! edge.

const std = @import("std");
const testing = std.testing;
const ray_crossing = @import("ray_crossing.zig");

const Vec2 = [2]f64;
const PI = std.math.pi;

/// The arcs of the family: where they start, in turns, and how far they sweep, in turns
/// (under a quarter, over a half, nearly whole), each way round; and their circles.
const ARC_STARTS = [_]f64{ 0, 0.11, 0.25, 0.4, 0.5, 0.73, 0.75, 0.97 };
const ARC_SWEEPS = [_]f64{ 0.01, 0.2, 0.25, 0.5, 0.6, 0.75, 0.99 };
const CIRCLES = [_]struct { c: Vec2, r: f64 }{ .{ .c = .{ 0, 0 }, .r = 1 }, .{ .c = .{ 2.5, -1.5 }, .r = 3 }, .{ .c = .{ -1e3, 2e3 }, .r = 0.25 } };
/// The points asked: a grid this many a side over twice the circle's box.
const GRID = 23;
/// A point this near a crossing's end of the plain count, as a share of the radius, is
/// left out: there the plain count is rounding's.
const CLEAR: f64 = 1e-9;

fn on(c: Vec2, r: f64, turns: f64) Vec2 {
    return .{ c[0] + r * @cos(2 * PI * turns), c[1] + r * @sin(2 * PI * turns) };
}

/// The crossings of the ray from `p` to +x with the arc, counted from the circle's two
/// points at `p`'s height; null when one of them is too near `p`, an end of the arc or
/// the circle's top or bottom to count by rounding.
fn plainCount(c: Vec2, r: f64, start: f64, sweep: f64, ccw: bool, p: Vec2) ?usize {
    const dy = p[1] - c[1];
    if (@abs(@abs(dy) - r) < CLEAR * r) return null;
    if (@abs(dy) > r) return 0;
    const dx = @sqrt(r * r - dy * dy);
    var count: usize = 0;
    for ([_]f64{ -dx, dx }) |x| {
        if (@abs(c[0] + x - p[0]) < CLEAR * r) return null;
        const turns = std.math.atan2(dy, x) / (2 * PI);
        const along = @mod(if (ccw) turns - start else start - turns, 1.0);
        if (@abs(along - sweep) < CLEAR or along < CLEAR or 1 - along < CLEAR) return null;
        if (along < sweep and c[0] + x > p[0]) count += 1;
    }
    return count;
}

test "ray crossing: an arc's parity is its plain crossing count's, any start, sweep and sense" {
    for (CIRCLES) |circle| for (ARC_STARTS) |start| for (ARC_SWEEPS) |sweep| for ([_]bool{ true, false }) |ccw| {
        const a = on(circle.c, circle.r, start);
        const b = on(circle.c, circle.r, if (ccw) start + sweep else start - sweep);
        for (0..GRID) |i| for (0..GRID) |j| {
            const p: Vec2 = .{
                circle.c[0] + circle.r * (4 * (@as(f64, @floatFromInt(i)) + 0.37) / GRID - 2),
                circle.c[1] + circle.r * (4 * (@as(f64, @floatFromInt(j)) + 0.61) / GRID - 2),
            };
            const plain = plainCount(circle.c, circle.r, start, sweep, ccw, p) orelse continue;
            errdefer std.debug.print("circle {any} r {d}, from {d} turns over {d}, ccw {}: the point {any}, {d} crossings\n", .{ circle.c, circle.r, start, sweep, ccw, p, plain });
            try testing.expectEqual(plain % 2 == 1, ray_crossing.arc(a, b, circle.c, circle.r, ccw, p));
        };
    };
}

test "ray crossing: a full circle of one edge, and of two, holds its inside, asked on its own levels too" {
    const c: Vec2 = .{ 1, 2 };
    const r: f64 = 2;
    const east: Vec2 = .{ 3, 2 };
    const west: Vec2 = .{ -1, 2 };
    // At the centre's height, the ends' own; at the top's and the bottom's; and between
    const asked = [_]struct { p: Vec2, inside: bool }{
        .{ .p = .{ 1, 2 }, .inside = true },       .{ .p = .{ -0.5, 2 }, .inside = true }, .{ .p = .{ 2.5, 2 }, .inside = true },
        .{ .p = .{ -4, 2 }, .inside = false },     .{ .p = .{ 5, 2 }, .inside = false },   .{ .p = .{ -4, 4 }, .inside = false },
        .{ .p = .{ 5, 4 }, .inside = false },      .{ .p = .{ -4, 0 }, .inside = false },  .{ .p = .{ 5, 0 }, .inside = false },
        .{ .p = .{ 1, 3.5 }, .inside = true },     .{ .p = .{ 1, 0.5 }, .inside = true },  .{ .p = .{ 2.9, 2.5 }, .inside = true },
        .{ .p = .{ 2.99, 2.5 }, .inside = false },
    };
    for (asked) |q| for ([_]bool{ true, false }) |ccw| {
        errdefer std.debug.print("the point {any}, ccw {}\n", .{ q.p, ccw });
        try testing.expectEqual(q.inside, ray_crossing.arc(east, east, c, r, ccw, q.p));
        try testing.expectEqual(q.inside, ray_crossing.arc(east, west, c, r, ccw, q.p) != ray_crossing.arc(west, east, c, r, ccw, q.p));
    };
}

test "ray crossing: a point level with a loop's vertices or on its circle is in or out for every edge alike; on its line, on the line's right" {
    // A D: a half disc about the origin to the east, closed by the line down its west
    // side. Points on the circle and level with the corners are answered as the point a
    // hair east of them (on the circle, outside)
    const top: Vec2 = .{ 0, 1 };
    const bottom: Vec2 = .{ 0, -1 };
    const c: Vec2 = .{ 0, 0 };
    const asked = [_]struct { p: Vec2, inside: bool }{
        .{ .p = .{ 0.5, 0 }, .inside = true },  .{ .p = .{ 1, 0 }, .inside = false },     .{ .p = .{ -1, 1 }, .inside = false },
        .{ .p = .{ -1, -1 }, .inside = false }, .{ .p = .{ 0.5, 1 }, .inside = false },   .{ .p = .{ 0.5, -1 }, .inside = false },
        .{ .p = .{ -1, 0 }, .inside = false },  .{ .p = .{ 0.6, 0.8 }, .inside = false },
    };
    for (asked) |q| {
        errdefer std.debug.print("the point {any}\n", .{q.p});
        // Counter-clockwise: up the arc from the bottom, down the line; and the other way
        const one = ray_crossing.arc(bottom, top, c, 1, true, q.p) != ray_crossing.line(top, bottom, q.p);
        const other = ray_crossing.arc(top, bottom, c, 1, false, q.p) != ray_crossing.line(bottom, top, q.p);
        try testing.expectEqual(q.inside, one);
        try testing.expectEqual(q.inside, other);
    }
    // On the line: on its right, which is outside the D whose line runs down (the D on
    // the line's left) and inside the one whose line runs up
    for ([_]Vec2{ .{ 0, 0 }, .{ 0, 0.5 } }) |p| {
        try testing.expect(!(ray_crossing.arc(bottom, top, c, 1, true, p) != ray_crossing.line(top, bottom, p)));
        try testing.expect(ray_crossing.arc(top, bottom, c, 1, false, p) != ray_crossing.line(bottom, top, p));
    }
}

test "ray crossing: an arc whose ends lie off its circle, as a vertex may, still closes its loop at the ends' own heights" {
    // A quarter disc whose arc's start is 5e-6 outside the circle and its end 5e-6 inside:
    // the radii close the loop through the ends as given, so at an end's height the arc
    // and the radius beside it read one point
    const c: Vec2 = .{ 0, 0 };
    const a: Vec2 = .{ 1 + 5e-6, 0 };
    const b: Vec2 = .{ 0, 1 - 5e-6 };
    for ([_]f64{ -3, -0.5, 0.5, 0.9, 3 }) |x| for ([_]f64{ 0, 1 - 5e-6, 0.5, -1 }) |y| {
        const p: Vec2 = .{ x, y };
        const inside = ray_crossing.arc(a, b, c, 1, true, p) != (ray_crossing.line(b, c, p) != ray_crossing.line(c, a, p));
        // The quarter's own inside, by its closed form away from its boundary
        const want = x > 0 and y >= 0 and y < 1 - 5e-6 and x * x + y * y < 1;
        errdefer std.debug.print("the point {any}\n", .{p});
        try testing.expectEqual(want, inside);
    };
}
