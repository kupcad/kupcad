//! The triangulator on squares, convex and concave polygons, holes, collinear and level
//! vertices, stars, and what it refuses; every result checked for the triangle count, the
//! area, the winding, the constraint edges and the Delaunay condition.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const predicates = @import("../math/predicates.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const triangulate = @import("triangulate.zig");
const Vec2 = vec.Vec2;
const Polygon = triangulate.Polygon;

/// How close the triangles' area is to the polygon's, relative.
const CLOSE = 1e-12;

fn signedArea(ring: []const Vec2) f64 {
    var twice: f64 = 0;
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        twice += p[0] * q[1] - q[0] * p[1];
    }
    return twice / 2;
}

fn polygonArea(polygon: Polygon) f64 {
    var area: f64 = 0;
    for (0..polygon.rings()) |r| area += signedArea(polygon.ring(r));
    return area;
}

/// The winding of the rings about `p`: non-zero inside the region.
fn winding(polygon: Polygon, p: Vec2) i32 {
    var w: i32 = 0;
    for (0..polygon.rings()) |r| {
        const ring = polygon.ring(r);
        for (ring, 0..) |a, i| {
            const b = ring[(i + 1) % ring.len];
            if (a[1] <= p[1]) {
                if (b[1] > p[1] and predicates.orient2d(a, b, p) > 0) w += 1;
            } else if (b[1] <= p[1] and predicates.orient2d(a, b, p) < 0) w -= 1;
        }
    }
    return w;
}

/// Every triangle counter-clockwise, of positive area, its centroid inside the region, the
/// triangles together as large as the polygon and as many as n + 2h − 2; every ring edge
/// among the triangles' edges; and no point strictly inside any triangle's circumcircle
/// that the triangle can see across an unconstrained edge (the constrained Delaunay
/// condition, checked the slow way).
fn expectTriangulation(polygon: Polygon, triangles: []const [3]u32) !void {
    const points = polygon.points;
    // n + 2h − 2 triangles for a simple polygon; a weakly simple one (a point repeated)
    // has fewer or more by two per touching point
    var repeated = false;
    for (points, 0..) |p, i| for (points[0..i]) |q| if (p[0] == q[0] and p[1] == q[1]) {
        repeated = true;
    };
    if (!repeated) try testing.expectEqual(points.len + 2 * (polygon.rings() - 1) - 2, triangles.len);
    var area: f64 = 0;
    var edges: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer edges.deinit(testing.allocator);
    for (triangles) |t| {
        const a = points[t[0]];
        const b = points[t[1]];
        const c = points[t[2]];
        const turn = predicates.orient2d(a, b, c);
        try testing.expect(turn > 0);
        area += turn / 2;
        const centroid = vec.scale2(vec.add2(vec.add2(a, b), c), 1.0 / 3.0);
        try testing.expect(winding(polygon, centroid) != 0);
        for (0..3) |i| {
            // A touching point may be named by any of its passages
            const key = edgeKey(firstAt(points, t[i]), firstAt(points, t[(i + 1) % 3]));
            const entry = try edges.getOrPut(testing.allocator, key);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
    try testing.expectApproxEqRel(polygonArea(polygon), area, CLOSE);
    for (0..polygon.rings()) |r| {
        const first = polygon.starts[r];
        const last = polygon.starts[r + 1] - 1;
        for (first..last + 1) |i| {
            const j: u32 = if (i == last) first else @intCast(i + 1);
            try testing.expectEqual(@as(?u32, 1), edges.get(edgeKey(firstAt(points, @intCast(i)), firstAt(points, j))));
        }
    }
    // Delaunay: for every pair of triangles across an unconstrained edge, the fourth
    // point is not strictly inside the circumcircle of the other three
    for (triangles, 0..) |t, ti| {
        for (triangles[ti + 1 ..]) |s| {
            for (0..3) |i| for (0..3) |j| {
                const p = t[i];
                const q = t[(i + 1) % 3];
                if (s[j] != q or s[(j + 1) % 3] != p) continue;
                if (isRingEdge(polygon, p, q)) continue;
                const r = t[(i + 2) % 3];
                const d = s[(j + 2) % 3];
                try testing.expect(predicates.incircle(points[p], points[q], points[r], points[d]) <= 0);
            };
        }
    }
}

/// The first point at the place of point `i`: what the triangles name a touching point by.
fn firstAt(points: []const Vec2, i: u32) u32 {
    for (points[0..i], 0..) |p, k| if (p[0] == points[i][0] and p[1] == points[i][1]) return @intCast(k);
    return i;
}

fn edgeKey(a: u32, b: u32) u64 {
    return (@as(u64, @min(a, b)) << 32) | @max(a, b);
}

fn isRingEdge(polygon: Polygon, a: u32, b: u32) bool {
    for (0..polygon.rings()) |r| {
        const first = polygon.starts[r];
        const last = polygon.starts[r + 1] - 1;
        for (first..last + 1) |i| {
            const j: u32 = if (i == last) first else @intCast(i + 1);
            const fi = firstAt(polygon.points, @intCast(i));
            const fj = firstAt(polygon.points, j);
            if ((fi == a and fj == b) or (fi == b and fj == a)) return true;
        }
    }
    return false;
}

fn expectPolygon(points: []const Vec2, starts: []const u32) !void {
    const polygon: Polygon = .{ .points = points, .starts = starts };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    errdefer std.debug.print("polygon of {d} points in {d} rings: {f}\n", .{ points.len, starts.len - 1, &diag });
    const triangles = try triangulate.triangulate(testing.allocator, polygon, &diag);
    defer testing.allocator.free(triangles);
    try expectTriangulation(polygon, triangles);
}

fn expectRefused(points: []const Vec2, starts: []const u32, code: @import("../diagnostics.zig").Code) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.InvalidInput, triangulate.triangulate(testing.allocator, .{ .points = points, .starts = starts }, &diag));
    try testing.expectEqual(code, diag.first().?.code);
}

test "triangulate: a square is two triangles, a triangle one" {
    try expectPolygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, &.{ 0, 4 });
    try expectPolygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 7 } }, &.{ 0, 3 });
}

test "triangulate: a regular polygon's triangulation is Delaunay, whichever diagonals the sweep drew" {
    var points: [16]Vec2 = undefined;
    for (&points, 0..) |*p, i| {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 16;
        p.* = .{ 5 * @cos(a), 5 * @sin(a) };
    }
    try expectPolygon(&points, &.{ 0, 16 });
}

test "triangulate: an L, a comb and a star, their reflex corners split and merged" {
    try expectPolygon(&.{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 5 }, .{ 5, 5 }, .{ 5, 20 }, .{ 0, 20 } }, &.{ 0, 6 });
    // A comb: teeth up, every tooth's gap a merge vertex below two split vertices
    try expectPolygon(&.{ .{ 0, 0 }, .{ 14, 0 }, .{ 14, 10 }, .{ 12, 10 }, .{ 12, 3 }, .{ 10, 3 }, .{ 10, 10 }, .{ 8, 10 }, .{ 8, 3 }, .{ 6, 3 }, .{ 6, 10 }, .{ 4, 10 }, .{ 4, 3 }, .{ 2, 3 }, .{ 2, 10 }, .{ 0, 10 } }, &.{ 0, 16 });
    var star: [20]Vec2 = undefined;
    for (&star, 0..) |*p, i| {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / 20;
        const r: f64 = if (i % 2 == 0) 10 else 4;
        p.* = .{ r * @cos(a), r * @sin(a) };
    }
    try expectPolygon(&star, &.{ 0, 20 });
}

test "triangulate: a hole, and a hole with a hole's worth of islands around it" {
    // A square with a square hole: 8 points, 1 hole, 8 triangles
    try expectPolygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 3, 3 }, .{ 3, 7 }, .{ 7, 7 }, .{ 7, 3 } }, &.{ 0, 4, 8 });
    // Three holes in a row, one a triangle
    try expectPolygon(&.{
        .{ 0, 0 },  .{ 30, 0 }, .{ 30, 10 }, .{ 0, 10 },
        .{ 2, 2 },  .{ 2, 8 },  .{ 8, 8 },   .{ 8, 2 },
        .{ 12, 2 }, .{ 15, 8 }, .{ 18, 2 },  .{ 22, 3 },
        .{ 22, 7 }, .{ 28, 7 }, .{ 28, 3 },
    }, &.{ 0, 4, 8, 11, 15 });
}

test "triangulate: collinear and level vertices, horizontal edges, a flat vertex on each side" {
    // A square with the midpoint of each side a vertex: flat vertices, three collinear points
    try expectPolygon(&.{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 10, 10 }, .{ 5, 10 }, .{ 0, 10 }, .{ 0, 5 } }, &.{ 0, 8 });
    // A staircase: every edge horizontal or vertical, many vertices level with each other
    try expectPolygon(&.{ .{ 0, 0 }, .{ 30, 0 }, .{ 30, 10 }, .{ 20, 10 }, .{ 20, 20 }, .{ 10, 20 }, .{ 10, 30 }, .{ 0, 30 } }, &.{ 0, 8 });
    // A hole whose top is level with a notch of the outer ring
    try expectPolygon(&.{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 15, 10 }, .{ 15, 8 }, .{ 12, 8 }, .{ 12, 10 }, .{ 0, 10 }, .{ 3, 3 }, .{ 3, 8 }, .{ 8, 8 }, .{ 8, 3 } }, &.{ 0, 8, 12 });
}

test "triangulate: weakly simple polygons: an hourglass pinched at a point, a hole touching the outer ring, a slit as one loop" {
    // An hourglass: one ring through its waist twice, two lobes of one triangle each
    try expectPolygon(&.{ .{ 0, 10 }, .{ 5, 5 }, .{ 0, 0 }, .{ 10, 0 }, .{ 5, 5 }, .{ 10, 10 } }, &.{ 0, 6 });
    // A square with a triangular hole whose corner is the square's corner
    try expectPolygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 }, .{ 3, 6 }, .{ 6, 3 } }, &.{ 0, 4, 7 });
    // The same hole as one loop through the corner twice, as the overlay's boundary walk
    // writes a hole that touches the outer loop
    try expectPolygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 }, .{ 3, 6 }, .{ 6, 3 } }, &.{ 0, 7 });
    // A square split by a slit from the left side to a point of the right side: two
    // lobes touching at that point, as one loop
    try expectPolygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 5 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 6 }, .{ 10, 5 }, .{ 0, 4 } }, &.{ 0, 8 });
    // Two squares touching at a corner, as two rings
    try expectPolygon(&.{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 5 }, .{ 0, 5 }, .{ 5, 5 }, .{ 10, 5 }, .{ 10, 10 }, .{ 5, 10 } }, &.{ 0, 4, 8 });
}

test "triangulate: a thin quadrilateral gets the Delaunay diagonal, the other being illegal" {
    // The sweep draws no diagonal in a convex quadrilateral; the stack walk joins the top
    // and the bottom, which is the illegal diagonal here: the flip must happen
    const points = [_]Vec2{ .{ 0, 0 }, .{ 10, -1 }, .{ 20, 0 }, .{ 10, 1 } };
    const polygon: Polygon = .{ .points = &points, .starts = &.{ 0, 4 } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const triangles = try triangulate.triangulate(testing.allocator, polygon, &diag);
    defer testing.allocator.free(triangles);
    try expectTriangulation(polygon, triangles);
    // Both triangles hold the short diagonal (1, 3)
    for (triangles) |t| {
        var has_1 = false;
        var has_3 = false;
        for (t) |v| {
            if (v == 1) has_1 = true;
            if (v == 3) has_3 = true;
        }
        try testing.expect(has_1 and has_3);
    }
}

test "triangulate: the same polygon twice gives the same triangles" {
    const points = [_]Vec2{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 15, 10 }, .{ 15, 8 }, .{ 12, 8 }, .{ 12, 10 }, .{ 0, 10 }, .{ 3, 3 }, .{ 3, 8 }, .{ 8, 8 }, .{ 8, 3 } };
    const polygon: Polygon = .{ .points = &points, .starts = &.{ 0, 8, 12 } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const first = try triangulate.triangulate(testing.allocator, polygon, &diag);
    defer testing.allocator.free(first);
    const second = try triangulate.triangulate(testing.allocator, polygon, &diag);
    defer testing.allocator.free(second);
    try testing.expectEqualSlices([3]u32, first, second);
}

test "triangulate: what is not a simple polygon is refused, saying what" {
    const square = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    try expectRefused(&square, &.{ 0, 3, 4 }, .ring_too_small);
    try expectRefused(&square, &.{ 1, 4 }, .ring_starts);
    try expectRefused(&square, &.{ 0, 3 }, .ring_starts);
    try expectRefused(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 0 }, .{ 0, 10 } }, &.{ 0, 4 }, .not_simple);
    try expectRefused(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, std.math.nan(f64) }, .{ 0, 10 } }, &.{ 0, 4 }, .not_finite);
    // A bow tie: its rings cross
    try expectRefused(&.{ .{ 0, 0 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 10 } }, &.{ 0, 4 }, .not_simple);
    // A hole outside its outer ring
    try expectRefused(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 20, 2 }, .{ 20, 8 }, .{ 28, 8 }, .{ 28, 2 } }, &.{ 0, 4, 8 }, .not_simple);
}

test "triangulate: allocation failure anywhere leaves nothing allocated" {
    const points = [_]Vec2{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 15, 10 }, .{ 15, 8 }, .{ 12, 8 }, .{ 12, 10 }, .{ 0, 10 }, .{ 3, 3 }, .{ 3, 8 }, .{ 8, 8 }, .{ 8, 3 } };
    const polygon: Polygon = .{ .points = &points, .starts = &.{ 0, 8, 12 } };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, p: Polygon) !void {
            var diag = Diagnostics.init(allocator);
            defer diag.deinit();
            const triangles = try triangulate.triangulate(allocator, p, &diag);
            allocator.free(triangles);
        }
    }.run, .{polygon});
}

/// `triangulateWith(polygon, extra)`: `used` of the extra points are inserted (each at
/// three triangles at least, adding two), the rest left out; the triangles are
/// counter-clockwise, cover the polygon exactly, hold each ring edge once and are
/// Delaunay across every other edge.
fn expectInserted(points: []const Vec2, starts: []const u32, extra: []const Vec2, used: usize) !void {
    const polygon: Polygon = .{ .points = points, .starts = starts };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const triangles = try triangulate.triangulateWith(testing.allocator, polygon, extra, &diag);
    defer testing.allocator.free(triangles);
    const all = try testing.allocator.alloc(Vec2, points.len + extra.len);
    defer testing.allocator.free(all);
    @memcpy(all[0..points.len], points);
    @memcpy(all[points.len..], extra);
    try testing.expectEqual(points.len + 2 * (polygon.rings() - 1) - 2 + 2 * used, triangles.len);
    const degree = try testing.allocator.alloc(usize, all.len);
    defer testing.allocator.free(degree);
    @memset(degree, 0);
    var area: f64 = 0;
    var edges: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer edges.deinit(testing.allocator);
    for (triangles) |t| {
        const turn = predicates.orient2d(all[t[0]], all[t[1]], all[t[2]]);
        try testing.expect(turn > 0);
        area += turn / 2;
        for (0..3) |i| {
            degree[t[i]] += 1;
            const entry = try edges.getOrPut(testing.allocator, edgeKey(t[i], t[(i + 1) % 3]));
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
    try testing.expectApproxEqRel(polygonArea(polygon), area, CLOSE);
    var inserted: usize = 0;
    for (degree[points.len..]) |d| {
        if (d > 0) inserted += 1;
        try testing.expect(d == 0 or d >= 3);
    }
    try testing.expectEqual(used, inserted);
    for (0..polygon.rings()) |r| {
        const first = polygon.starts[r];
        const last = polygon.starts[r + 1] - 1;
        for (first..last + 1) |i| {
            const j: u32 = if (i == last) first else @intCast(i + 1);
            try testing.expectEqual(@as(?u32, 1), edges.get(edgeKey(@intCast(i), j)));
        }
    }
    for (triangles, 0..) |t, ti| {
        for (triangles[ti + 1 ..]) |s| {
            for (0..3) |i| for (0..3) |j| {
                const p = t[i];
                const q = t[(i + 1) % 3];
                if (s[j] != q or s[(j + 1) % 3] != p) continue;
                if (p < points.len and q < points.len and isRingEdge(polygon, p, q)) continue;
                try testing.expect(predicates.incircle(all[p], all[q], all[t[(i + 2) % 3]], all[s[(j + 2) % 3]]) <= 0);
            };
        }
    }
}

test "triangulateWith: a point inside a triangle splits it in three, one on a diagonal splits both sides, the rest are left out" {
    const square = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    try expectInserted(&square, &.{ 0, 4 }, &.{.{ 3, 6 }}, 1);
    // The base triangulation's diagonal runs from (0, 0) to (10, 10) or the other way:
    // the centre is on either
    try expectInserted(&square, &.{ 0, 4 }, &.{.{ 5, 5 }}, 1);
    try expectInserted(&square, &.{ 0, 4 }, &.{ .{ 5, 5 }, .{ 2, 2 }, .{ 8, 2 } }, 3);
    // Outside, on a ring's edge, at a vertex, not finite
    try expectInserted(&square, &.{ 0, 4 }, &.{ .{ 15, 5 }, .{ 5, 0 }, .{ 0, 0 }, .{ 10, 10 } }, 0);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.InvalidInput, triangulate.triangulateWith(testing.allocator, .{ .points = &square, .starts = &.{ 0, 4 } }, &.{.{ std.math.nan(f64), 1 }}, &diag));
}

test "triangulateWith: a grid of points in a square is a Delaunay grid; points in a hole are left out" {
    const square = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var grid: [25]Vec2 = undefined;
    for (0..5) |i| for (0..5) |j| {
        grid[i * 5 + j] = .{ 1.5 + 1.75 * @as(f64, @floatFromInt(i)), 1.5 + 1.75 * @as(f64, @floatFromInt(j)) };
    };
    try expectInserted(&square, &.{ 0, 4 }, &grid, 25);
    const pierced = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 4, 4 }, .{ 4, 6 }, .{ 6, 6 }, .{ 6, 4 } };
    try expectInserted(&pierced, &.{ 0, 4, 8 }, &.{ .{ 5, 5 }, .{ 4.5, 5.5 }, .{ 2, 2 }, .{ 8, 8 } }, 2);
}

test "triangulateWith: random points in a square are inserted in any order and the result is Delaunay" {
    const square = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var prng = std.Random.DefaultPrng.init(0x7e55);
    const random = prng.random();
    for (0..20) |_| {
        var extra: [40]Vec2 = undefined;
        for (&extra) |*p| p.* = .{ random.float(f64) * 10, random.float(f64) * 10 };
        try expectInserted(&square, &.{ 0, 4 }, &extra, extra.len);
    }
}
