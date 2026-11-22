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
/// A cap of the 2D chain fuzzer's extrusion (2026-11-21, bw), its chorded outline as the
/// tessellator gave it: two arcs leave (2, 0) (the seventh point) 7.1° apart, curving the
/// same way, the flatter one's single chord to (1.109, 0.164) crossing the other's chord
/// from (1.80, 0.035) 0.2 from the vertex; the region between the chords is wound twice.
const CROSSED_CAP = [_]Vec2{ .{ 6, 0 }, .{ 4, 3 }, .{ 3.75, 3.1666666666666665 }, .{ 2.6, 2.4000000000000004 }, .{ 1.1903200733589268, 0.2854801100383906 }, .{ 1.8014947190130184, 0.03496997149489123 }, .{ 2, 0 }, .{ 1.1093541668271576, 0.16403125024073617 }, .{ 1, 0 }, .{ 1, 0.20871215252208009 }, .{ 0.23223304703363068, 0.7322330470336313 }, .{ -0.5, 2.5000000000000004 }, .{ 0.23223304703363135, 4.267766952966369 }, .{ 1, 4.7912878474779195 }, .{ 1, 5 }, .{ 0.8483011093985733, 4.945976220173328 }, .{ -0.7087485216717395, 3.8712224601329233 }, .{ -1.5879845232121115, 2.195978223631126 }, .{ -1.5879845232121124, 0.30402177636887695 }, .{ -0.7087485216717413, -1.371222460132921 }, .{ 0.8483011093985715, -2.4459762201733284 }, .{ 2.726463064002831, -2.674026369513976 }, .{ 4.495473072646427, -2.0031293672431496 }, .{ 5.75007226123078, -0.5869796313957469 } };
/// One ring round a square whose closing edges dip through its first edge and come back
/// up, crossing it twice far from any vertex.
const BOW_TIE = [_]Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 }, .{ 2, -1 }, .{ 2, 1 } };
/// A square's loop bridged to a hole (find cp's face): round the square from (0, 0), along
/// the bridge from (0, 4) to the hole's corner (1, 3), clockwise round the hole and back
/// along the bridge; vertex 3 and vertex 4 each passed twice.
const KEYHOLE_POINTS = [_]Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 }, .{ 1, 3 }, .{ 2, 3 }, .{ 2, 1 }, .{ 1, 1 } };
const KEYHOLE_LOOP = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 4, 3 };
/// The keyhole's region: the square less the hole.
const KEYHOLE_AREA: f64 = 16 - 2;
/// A square 10 a side with a notch from its top whose tip stands `TOUCH_LIFTS` over the
/// middle of its bottom edge (find cw's touch: a point of the rings inside another of
/// their edges, a few ulps to the region's side of it), and a hole whose lowest corner
/// stands so over that edge. The band a point that near is refused within is D27's at
/// the rings' coordinates: 64 ulps of 10, 1.4e-13.
const TOUCH_SQUARE: f64 = 10;
/// Within the band, the touch refused (one exactly on the edge, and below it, through it).
const TOUCH_LIFTS_REFUSED = [_]f64{ 0, 1e-15, 1e-14, 1e-13, -1e-15 };
/// Past it, the polygon triangulated.
const TOUCH_LIFTS_MESHED = [_]f64{ 1e-12, 1e-9, 1e-6 };

/// About the ring's first point: about the origin, a ring far from it sums terms far
/// larger than its area.
fn signedArea(ring: []const Vec2) f64 {
    var twice: f64 = 0;
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        twice += vec.cross2(vec.sub2(p, ring[0]), vec.sub2(q, ring[0]));
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
    // A notch from the top whose tip lies on the ring's own edge, below or beside it: no
    // passage through one point, so nothing to reweave; the triangles crossed the edge,
    // their count and signed area the polygon's all the same (the fuzzer, 2026-11-16: a
    // face's notch reaching an arc's chord)
    try expectRefused(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 6, 10 }, .{ 5, 0 }, .{ 4, 10 }, .{ 0, 10 } }, &.{ 0, 7 }, .not_simple);
    try expectRefused(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 4, 10 }, .{ 10, 5 }, .{ 2, 10 }, .{ 0, 10 } }, &.{ 0, 7 }, .not_simple);
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

test "triangulate: the area refusal reports areas of any size or sign" {
    // The fuzzer's find (2026-11-12): the refusal scaled both areas by 10⁶ into integers,
    // which panicked for an area past 2⁶⁴ / 10⁶ or below zero. A polygon pinched at a
    // point (so the triangles are not counted) with a hole outside its outer ring is
    // refused by its area: once at a scale of 10¹¹, once with a hole larger than the
    // ring, so the polygon's area is negative
    const huge = [_]Vec2{ .{ 0, 0 }, .{ 1e12, 0 }, .{ 5e11, 5e11 }, .{ 1e12, 1e12 }, .{ 0, 1e12 }, .{ 5e11, 5e11 }, .{ 2e12, 2e11 }, .{ 2e12, 8e11 }, .{ 2.8e12, 8e11 }, .{ 2.8e12, 2e11 } };
    const negative = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 5 }, .{ 10, 10 }, .{ 0, 10 }, .{ 5, 5 }, .{ 20, 2 }, .{ 20, 8 }, .{ 40, 8 }, .{ 40, 2 } };
    const expected = [_]f64{ 5e23 - 4.8e23, 50 - 120 };
    for ([_][]const Vec2{ &huge, &negative }, expected) |points, area| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.InvalidInput, triangulate.triangulate(testing.allocator, .{ .points = points, .starts = &.{ 0, 6, 10 } }, &diag));
        const finding = diag.first().?;
        try testing.expectEqual(.not_simple, finding.code);
        try testing.expectApproxEqRel(area, finding.threshold, 1e-9);
        try testing.expect(finding.measured != finding.threshold);
    }
}

test "triangulate: a polygon far from the origin is triangulated as near it" {
    // The polygon's area, which the triangles' must match, summed about the origin: a
    // sliver 1e7 out summed terms of 1e14 to an area of 0, and the polygon was refused as
    // not simple. About each ring's first point; a square with a hole there too
    const at = Vec2{ 1e7, 1e7 };
    const sliver = [_]Vec2{ at, vec.add2(at, .{ 1, 0 }), vec.add2(at, .{ 0.5, 0.01 }) };
    try expectPolygon(&sliver, &.{ 0, 3 });
    var holed: [8]Vec2 = undefined;
    for ([_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 4, 4 }, .{ 4, 6 }, .{ 6, 6 }, .{ 6, 4 } }, &holed) |p, *q| q.* = vec.add2(at, p);
    try expectPolygon(&holed, &.{ 0, 4, 8 });
}

/// Point `p` turned `quarter` quarter turns about the origin, then mirrored in the y axis
/// when `mirrored`: exact.
fn moved(p: Vec2, quarter: usize, mirrored: bool) Vec2 {
    var q = p;
    for (0..quarter) |_| {
        const turned: Vec2 = .{ -q[1], q[0] };
        q = turned;
    }
    return if (mirrored) .{ -q[0], q[1] } else q;
}

test "triangulate: rings whose edges cross, the region between them wound twice, are refused in every quarter turn, mirrored or not" {
    // The 2D chain fuzzer's find (2026-11-21, bw): the sweep ran through the crossing and
    // covered the twice-wound region twice, the triangles' count, signed area and ring
    // sides all the polygon's (once with a triangle of no area across three points left
    // out and counted: a diagonal through a vertex), and the tessellator never refined
    // the arcs; the extrusion's mesh had a side used once
    var points: [CROSSED_CAP.len]Vec2 = undefined;
    for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("quarter turns {d}, mirrored {}\n", .{ quarter, mirrored });
        // A mirror turns the ring clockwise: it is read backwards, the region kept on its left
        for (CROSSED_CAP, 0..) |p, k| points[if (mirrored) CROSSED_CAP.len - 1 - k else k] = moved(p, quarter, mirrored);
        try expectRefused(&points, &.{ 0, CROSSED_CAP.len }, .not_simple);
    };
    // Two edges crossing far from any vertex, as a bow tie: refused as well
    try expectRefused(&BOW_TIE, &.{ 0, BOW_TIE.len }, .not_simple);
}

/// `splitSlits` of the loop `ids` (and `steps`), as the rings of vertices it makes.
fn expectSplit(ids: []const u32, steps: ?[]const u32, rings: []const []const u32) !void {
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(testing.allocator);
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(testing.allocator);
    try triangulate.splitSlits(testing.allocator, ids, steps, &order, &starts);
    try testing.expectEqual(rings.len, starts.items.len);
    for (rings, 0..) |ring, r| {
        const to = if (r + 1 < starts.items.len) starts.items[r + 1] else order.items.len;
        const got = order.items[starts.items[r]..to];
        try testing.expectEqual(ring.len, got.len);
        for (ring, got) |v, k| try testing.expectEqual(v, ids[k]);
    }
}

test "triangulate: a loop's slits taken out split it into the rings either side, a spur's tip left out" {
    // A bridge to a hole: the square and the hole, the loop's continuation first
    try expectSplit(&KEYHOLE_LOOP, null, &.{ &.{ 3, 0, 1, 2 }, &.{ 4, 5, 6, 7 } });
    // A spur out to a point and back, of one step and of two: its tip goes, the rest is one
    // ring
    try expectSplit(&.{ 0, 1, 2, 3, 4, 3 }, null, &.{&.{ 3, 0, 1, 2 }});
    try expectSplit(&.{ 0, 1, 2, 3, 4, 5, 4, 3 }, null, &.{&.{ 3, 0, 1, 2 }});
    // A slit across the face from one side (vertex 0) to the other (3): the face whole
    try expectSplit(&.{ 0, 1, 2, 3, 0, 3, 4, 5 }, null, &.{&.{ 3, 4, 5, 0, 1, 2 }});
    // A loop through a point twice with no step run both ways (a pinch) is one ring
    try expectSplit(&.{ 0, 1, 2, 0, 3, 4 }, null, &.{&.{ 0, 1, 2, 0, 3, 4 }});
    // Along two edges between the same two vertices (a lens), and a pole's step from a
    // vertex to itself: no slit
    try expectSplit(&.{ 0, 1, 2, 3, 2, 1 }, &.{ 7, 8, 9, 10, 11, 12 }, &.{&.{ 0, 1, 2, 3, 2, 1 }});
    try expectSplit(&.{ 0, 0, 1, 2 }, null, &.{&.{ 0, 0, 1, 2 }});
    // A lens of two edges each one chord is a ring of two points, left to the caller (the
    // tessellator refines such a face's arcs)
    try expectSplit(&.{ 0, 1 }, &.{ 7, 8 }, &.{&.{ 0, 1 }});
    // A cylinder's loop: the bottom circle, up the seam, the top circle back, down the seam.
    // The seam run both ways is its two sides, apart in the face's parameters: marked, the
    // loop is whole; taken for a slit, it would fall apart into the two circles
    const seam = triangulate.NOT_A_SLIT;
    const cylinder = [_]u32{ 0, 10, 11, 0, 1, 20, 21, 1 };
    try expectSplit(&cylinder, &.{ 1, 1, 1, seam, 2, 2, 2, seam }, &.{&cylinder});
    try expectSplit(&cylinder, &.{ 1, 1, 1, 5, 2, 2, 2, 5 }, &.{ &.{ 0, 10, 11 }, &.{ 1, 20, 21 } });
}

test "triangulate: a face's loop bridged to a hole triangulates once its bridge is taken out, refused as it was" {
    // Find cp: the triangulator rightly refuses a bridge's two passages along one segment,
    // which leave no wedge to reweave; split, the square and its hole triangulate to the
    // region's area
    var points: [KEYHOLE_LOOP.len]Vec2 = undefined;
    for (KEYHOLE_LOOP, &points) |v, *p| p.* = KEYHOLE_POINTS[v];
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.InvalidInput, triangulate.triangulate(testing.allocator, .{ .points = &points, .starts = &.{ 0, points.len } }, &diag));
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(testing.allocator);
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(testing.allocator);
    try triangulate.splitSlits(testing.allocator, &KEYHOLE_LOOP, null, &order, &starts);
    var rings: [KEYHOLE_LOOP.len]Vec2 = undefined;
    for (order.items, 0..) |k, i| rings[i] = KEYHOLE_POINTS[KEYHOLE_LOOP[k]];
    try starts.append(testing.allocator, @intCast(order.items.len));
    const polygon: Polygon = .{ .points = rings[0..order.items.len], .starts = starts.items };
    try testing.expectApproxEqAbs(KEYHOLE_AREA, polygonArea(polygon), CLOSE);
    const triangles = try triangulate.triangulate(testing.allocator, polygon, &diag);
    defer testing.allocator.free(triangles);
    var area: f64 = 0;
    for (triangles) |t| area += vec.cross2(vec.sub2(polygon.points[t[1]], polygon.points[t[0]]), vec.sub2(polygon.points[t[2]], polygon.points[t[0]])) / 2;
    try testing.expectApproxEqAbs(KEYHOLE_AREA, area, CLOSE * KEYHOLE_AREA);
}

/// The notched square (or, `as_hole`, the square with a triangular hole) of the touch
/// tests, the tip `lift` over the bottom edge's middle, turned `quarter` quarter turns and
/// mirrored when `mirrored`, each ring read backwards when mirrored so that the region
/// stays on its left; `points` and `starts` filled, the counts returned.
fn touchPolygon(lift: f64, as_hole: bool, quarter: usize, mirrored: bool, points: *[7]Vec2, starts: *[3]u32) struct { points: usize, starts: usize } {
    const t = TOUCH_SQUARE;
    const notched = [_]Vec2{ .{ 0, 0 }, .{ t, 0 }, .{ t, t }, .{ 0.6 * t, t }, .{ 0.5 * t, lift }, .{ 0.4 * t, t }, .{ 0, t } };
    const square = [_]Vec2{ .{ 0, 0 }, .{ t, 0 }, .{ t, t }, .{ 0, t } };
    const hole = [_]Vec2{ .{ 0.5 * t, lift }, .{ 0.4 * t, 0.5 * t }, .{ 0.6 * t, 0.5 * t } };
    const rings: []const []const Vec2 = if (as_hole) &.{ &square, &hole } else &.{&notched};
    var at: usize = 0;
    for (rings, 0..) |ring, r| {
        starts[r] = @intCast(at);
        for (ring, 0..) |p, k| points[at + (if (mirrored) ring.len - 1 - k else k)] = moved(p, quarter, mirrored);
        at += ring.len;
    }
    starts[rings.len] = @intCast(at);
    return .{ .points = at, .starts = rings.len + 1 };
}

test "triangulate: a point of the rings inside another of their edges, to within rounding of it, is refused, past it triangulated, in every quarter turn, mirrored or not (fuzz find cw)" {
    // The 2D chain fuzzer's find (2026-11-22, cw): a crescent between two nested arcs, the
    // outer arc's one chord passing through the inner arc's top to 2.5e-17. Exactly on the
    // chord the ring sides refuse the polygon; a few ulps to the region's side of it the
    // polygon is simple to the exact turns, and was meshed with a triangle across the
    // touch of no area in 3D. Within D27's band of an edge a point touches it, and the
    // polygon is refused so that the tessellator refines the arcs; a notch's tip and a
    // hole's corner alike
    var points: [7]Vec2 = undefined;
    var starts: [3]u32 = undefined;
    for ([_]bool{ false, true }) |as_hole| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        for (TOUCH_LIFTS_REFUSED) |lift| {
            errdefer std.debug.print("refused: lift {e}, as a hole {}, quarter turns {d}, mirrored {}\n", .{ lift, as_hole, quarter, mirrored });
            const n = touchPolygon(lift, as_hole, quarter, mirrored, &points, &starts);
            try expectRefused(points[0..n.points], starts[0..n.starts], .not_simple);
        }
        for (TOUCH_LIFTS_MESHED) |lift| {
            errdefer std.debug.print("meshed: lift {e}, as a hole {}, quarter turns {d}, mirrored {}\n", .{ lift, as_hole, quarter, mirrored });
            const n = touchPolygon(lift, as_hole, quarter, mirrored, &points, &starts);
            try expectPolygon(points[0..n.points], starts[0..n.starts]);
        }
    };
}

test "triangulateWith: points on the sides of triangles turned any way round, the sides beyond them kept paired" {
    // A point on a side splits the two triangles the side lies between. Each keeps a side
    // beyond the point, and the triangle across that side must be told its new place in
    // the split one's corners. It was not: with the side the point lies on not the first
    // of its triangle, the neighbour kept the old place, and a later point on a side
    // there read a wrong corner across: the triangle (0, 7, 0), a corner twice (found
    // writing the audit's tests, 2026-11-22). A square's centre, then a point on each
    // spoke from it, in every order of the four
    const square = [_]Vec2{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    const spokes = [_]Vec2{ .{ 0.25, 0.75 }, .{ 0.75, 0.25 }, .{ 0.25, 0.25 }, .{ 0.75, 0.75 } };
    for (0..4) |first| for (0..4) |second| for (0..4) |third| for (0..4) |fourth| {
        if (first == second or first == third or first == fourth or second == third or second == fourth or third == fourth) continue;
        errdefer std.debug.print("order {d} {d} {d} {d}\n", .{ first, second, third, fourth });
        try expectInserted(&square, &.{ 0, 4 }, &.{ .{ 0.5, 0.5 }, spokes[first], spokes[second], spokes[third], spokes[fourth] }, 5);
    };
}

test "triangulateWith: a corner the least double off the origin, its flips decided exactly and ended" {
    // The audit of 2026-11-22 (kind 9, B3): the Delaunay flips end because `incircle` is
    // exact, and it was exact only for coordinates the least double is far below; a
    // corner that far off the origin squares to nothing in the lift. The square with its
    // first corner so, either side, and points inside: triangulated, Delaunay
    const hair = std.math.floatTrueMin(f64);
    for ([_]Vec2{ .{ hair, hair }, .{ -hair, hair }, .{ hair, -hair }, .{ -hair, -hair }, .{ 0, hair } }) |corner| {
        errdefer std.debug.print("corner {any}\n", .{corner});
        const square = [_]Vec2{ corner, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        try expectInserted(&square, &.{ 0, 4 }, &.{ .{ 0.5, 0.5 }, .{ 0.25, 0.75 }, .{ 0.75, 0.25 }, .{ 0.25, 0.25 } }, 4);
    }
}
