//! The overlay on the corpus the plan names: squares overlapping, touching, nested, sharing
//! part of an edge, three edges through one point, a bow tie, circles with squares and
//! with each other, tangent circles; each case checked by its faces' windings and areas.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const overlay = @import("overlay.zig");
const Overlay = overlay.Overlay;
const Vec2 = vec.Vec2;

const tol = Tolerance.fromZone(1e-5);
const PI = std.math.pi;

/// A closed polygon as one input's edges, in the order given (counter-clockwise for a
/// region, clockwise for a hole).
fn polygon(o: *Overlay, points: []const Vec2) !void {
    for (points, 0..) |p, i| try o.addEdge(.{ .a = p, .b = points[(i + 1) % points.len] });
}

/// A circle as two counter-clockwise half arcs.
fn circle(o: *Overlay, c: Vec2, r: f64) !void {
    const east = Vec2{ c[0] + r, c[1] };
    const west = Vec2{ c[0] - r, c[1] };
    try o.addEdge(.{ .a = east, .b = west, .arc = .{ .c = c, .r = r, .ccw = true } });
    try o.addEdge(.{ .a = west, .b = east, .arc = .{ .c = c, .r = r, .ccw = true } });
}

/// The faces with the given windings for inputs 0 and 1, and their total area.
fn areaWhere(o: *const Overlay, w0: i32, w1: ?i32) struct { faces: usize, area: f64 } {
    var faces: usize = 0;
    var area: f64 = 0;
    for (o.faces.items, 0..) |f, i| {
        if (o.windingOf(@intCast(i), 0) != w0) continue;
        if (w1) |w| if (o.windingOf(@intCast(i), 1) != w) continue;
        faces += 1;
        area += o.cycles.items[f.outer].area;
        for (o.holesOf(@intCast(i))) |h| area += o.cycles.items[h].area;
    }
    return .{ .faces = faces, .area = area };
}

test "overlay: two squares overlapping at a corner: four faces, the right windings and areas" {
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try polygon(&o, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } });
    _ = try o.addInput();
    try polygon(&o, &.{ .{ 1, 1 }, .{ 3, 1 }, .{ 3, 3 }, .{ 1, 3 } });
    try o.run();
    try testing.expectEqual(@as(usize, 3), o.faces.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1), areaWhere(&o, 1, 1).area, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3), areaWhere(&o, 1, 0).area, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3), areaWhere(&o, 0, 1).area, 1e-12);
    // The crossing points are vertices: 8 corners + 2
    try testing.expectEqual(@as(usize, 10), o.points.items.len);
}

test "overlay: squares touching along an edge, sharing part of an edge, and one inside another" {
    // Touching: the shared edge carries both inputs, against each other
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } });
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 2, 0 }, .{ 4, 0 }, .{ 4, 2 }, .{ 2, 2 } });
        try o.run();
        try testing.expectEqual(@as(usize, 2), o.faces.items.len);
        try testing.expectEqual(@as(usize, 7), o.edges.items.len);
        try testing.expectApproxEqAbs(@as(f64, 4), areaWhere(&o, 1, 0).area, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 4), areaWhere(&o, 0, 1).area, 1e-12);
    }
    // Part of an edge shared: the overlap is cut at the ends inside the other
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } });
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 2, 1 }, .{ 4, 1 }, .{ 4, 3 }, .{ 2, 3 } });
        try o.run();
        try testing.expectEqual(@as(usize, 2), o.faces.items.len);
        try testing.expectApproxEqAbs(@as(f64, 4), areaWhere(&o, 1, 0).area, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 4), areaWhere(&o, 0, 1).area, 1e-12);
        // The cuts at (2, 1) and (2, 2) are corners already: 8 vertices, and the shared
        // piece (2,1)–(2,2) is one edge of two contributions
        try testing.expectEqual(@as(usize, 8), o.points.items.len);
        var shared: usize = 0;
        for (o.edges.items) |e| shared += @intFromBool(e.contributions == 2);
        try testing.expectEqual(@as(usize, 1), shared);
    }
    // Nested: the inner square is a hole of the outer's face in input 0 and a face in 1
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } });
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 1, 1 }, .{ 3, 1 }, .{ 3, 3 }, .{ 1, 3 } });
        try o.run();
        try testing.expectEqual(@as(usize, 2), o.faces.items.len);
        const ring = areaWhere(&o, 1, 0);
        try testing.expectEqual(@as(usize, 1), ring.faces);
        try testing.expectApproxEqAbs(@as(f64, 12), ring.area, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 4), areaWhere(&o, 1, 1).area, 1e-12);
        // A clockwise inner outline is a hole of input 0's region: winding 0 there
        var h = Overlay.init(testing.allocator, tol);
        defer h.deinit();
        _ = try h.addInput();
        try polygon(&h, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } });
        try polygon(&h, &.{ .{ 1, 1 }, .{ 1, 3 }, .{ 3, 3 }, .{ 3, 1 } });
        try h.run();
        try testing.expectApproxEqAbs(@as(f64, 12), areaWhere(&h, 1, null).area, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 4), areaWhere(&h, 0, null).area, 1e-12);
    }
}

test "overlay: three edges through one point, a corner on an edge, and a bow tie by even-odd" {
    // A diamond whose corner lies on a square's edge: the corner is one vertex of degree 3
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } });
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 4, 2 }, .{ 6, 0 }, .{ 8, 2 }, .{ 6, 4 } });
        try o.run();
        try testing.expectEqual(@as(usize, 2), o.faces.items.len);
        try testing.expectApproxEqAbs(@as(f64, 16), areaWhere(&o, 1, 0).area, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 8), areaWhere(&o, 0, 1).area, 1e-12);
        try testing.expectEqual(@as(usize, 8), o.points.items.len);
        // Two squares crossing at a point on both outlines: three edges meet there
        var x = Overlay.init(testing.allocator, tol);
        defer x.deinit();
        _ = try x.addInput();
        try polygon(&x, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } });
        _ = try x.addInput();
        try polygon(&x, &.{ .{ 1, 2 }, .{ 3, 0 }, .{ 5, 2 }, .{ 3, 4 } });
        try x.run();
        try testing.expectApproxEqAbs(@as(f64, 0.5), areaWhere(&x, 1, 1).area, 1e-12);
    }
    // A bow tie: one outline crossing itself; even-odd and non-zero agree here (windings
    // 1 and −1), and the crossing is a vertex
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 0, 0 }, .{ 2, 2 }, .{ 2, 0 }, .{ 0, 2 } });
        try o.run();
        try testing.expectEqual(@as(usize, 2), o.faces.items.len);
        try testing.expectApproxEqAbs(@as(f64, 1), areaWhere(&o, 1, null).area, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 1), areaWhere(&o, -1, null).area, 1e-12);
        try testing.expectEqual(@as(usize, 5), o.points.items.len);
    }
}

test "overlay: a circle through a square, two circles overlapping, and two tangent" {
    // A circle of radius 1 about the square's corner: a quarter inside
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try polygon(&o, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } });
        _ = try o.addInput();
        try circle(&o, .{ 0, 0 }, 1);
        try o.run();
        try testing.expectApproxEqAbs(PI / 4.0, areaWhere(&o, 1, 1).area, 1e-12);
        try testing.expectApproxEqAbs(4 - PI / 4.0, areaWhere(&o, 1, 0).area, 1e-12);
        try testing.expectApproxEqAbs(3 * PI / 4.0, areaWhere(&o, 0, 1).area, 1e-12);
    }
    // Two unit circles a unit apart: the lens is 2π/3 − √3/2
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try circle(&o, .{ 0, 0 }, 1);
        _ = try o.addInput();
        try circle(&o, .{ 1, 0 }, 1);
        try o.run();
        const lens = 2 * PI / 3.0 - @sqrt(3.0) / 2.0;
        try testing.expectApproxEqAbs(lens, areaWhere(&o, 1, 1).area, 1e-12);
        try testing.expectApproxEqAbs(PI - lens, areaWhere(&o, 1, 0).area, 1e-12);
        try testing.expectEqual(@as(usize, 3), o.faces.items.len);
    }
    // Tangent circles: one vertex shared, no overlap, each a face of its own
    {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        try circle(&o, .{ 0, 0 }, 1);
        _ = try o.addInput();
        try circle(&o, .{ 2, 0 }, 1);
        try o.run();
        try testing.expectEqual(@as(usize, 2), o.faces.items.len);
        try testing.expectApproxEqAbs(PI, areaWhere(&o, 1, 0).area, 1e-12);
        try testing.expectApproxEqAbs(PI, areaWhere(&o, 0, 1).area, 1e-12);
        try testing.expectEqual(@as(usize, 3), o.points.items.len);
    }
}

test "overlay: the boundary of a union, a difference and an intersection as cycles" {
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try polygon(&o, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } });
    _ = try o.addInput();
    try polygon(&o, &.{ .{ 1, 1 }, .{ 3, 1 }, .{ 3, 3 }, .{ 1, 3 } });
    try o.run();
    var halves = std.ArrayList(u32).empty;
    defer halves.deinit(testing.allocator);
    var starts = std.ArrayList(u32).empty;
    defer starts.deinit(testing.allocator);
    const keep = try testing.allocator.alloc(bool, o.faces.items.len);
    defer testing.allocator.free(keep);
    // Union: one cycle of eight half-edges
    for (keep, 0..) |*k, i| k.* = o.windingOf(@intCast(i), 0) != 0 or o.windingOf(@intCast(i), 1) != 0;
    try o.boundary(keep, &halves, &starts);
    try testing.expectEqual(@as(usize, 2), starts.items.len);
    try testing.expectEqual(@as(usize, 8), halves.items.len);
    // Difference: six half-edges; intersection: four
    for (keep, 0..) |*k, i| k.* = o.windingOf(@intCast(i), 0) != 0 and o.windingOf(@intCast(i), 1) == 0;
    try o.boundary(keep, &halves, &starts);
    try testing.expectEqual(@as(usize, 6), halves.items.len);
    for (keep, 0..) |*k, i| k.* = o.windingOf(@intCast(i), 0) != 0 and o.windingOf(@intCast(i), 1) != 0;
    try o.boundary(keep, &halves, &starts);
    try testing.expectEqual(@as(usize, 4), halves.items.len);
    // Every cycle closes: each half-edge's target is the next one's origin
    for (halves.items, 0..) |h, i| {
        const next = if (i + 1 < halves.items.len) halves.items[i + 1] else halves.items[0];
        try testing.expectEqual(o.target(h), o.origin(next));
    }
}

test "overlay: a ray at a vertex's height where a line meets an arc counts the vertex as the line does" {
    // The fuzzer's find (2026-11-08): the arc about (4, 2) ends at (3, 2), whose height
    // from its angle is 2 − 1.2e-16, rounded to the double below 2; a ray at that very
    // height (a probe point computed the same way) saw the line above it and the arc not,
    // so a cycle of no area "contained" the point and the outer boundary nested in it
    const a = Vec2{ 3.006310156317969, 1.8878371961692268 };
    const b = Vec2{ 3, 2 };
    const arc: overlay.Arc = .{ .c = .{ 4, 2 }, .r = 1, .ccw = false };
    const p = Vec2{ -1.00004, 1.9999999999999998 };
    try testing.expect(overlay.arcCrossings(a, b, arc, p));
    try testing.expect(!overlay.arcCrossings(a, b, arc, .{ -1.00004, 2 }));
    try testing.expect(!overlay.arcCrossings(a, b, arc, .{ 3.5, 1.9999999999999998 }));
}

test "overlay: a hole is nested by the ray from its leftmost vertex, through a vertex on the ray" {
    // A square with a vertex on its left side at the ray's height, a diamond hole whose
    // bottom vertex lies on the ray with two edges up from it, and a triangle hole to
    // the right: the ray from the triangle's leftmost vertex meets the diamond's bottom
    // vertex first, where the more clockwise of the two edges up bounds the region east
    // of it, the square's; the diamond's inside is a face of its own with no holes
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try polygon(&o, &.{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 6 }, .{ 0, 6 }, .{ 0, 2 } });
    try polygon(&o, &.{ .{ 1, 2 }, .{ 0.5, 3 }, .{ 1, 4 }, .{ 1.5, 3 } });
    try polygon(&o, &.{ .{ 3, 2 }, .{ 3, 4 }, .{ 5, 3 } });
    try o.run();
    try testing.expectEqual(@as(usize, 3), o.faces.items.len);
    for (o.faces.items, 0..) |f, i| {
        const area = o.cycles.items[f.outer].area;
        const holes = o.holesOf(@intCast(i)).len;
        if (area > 30) try testing.expectEqual(@as(usize, 2), holes) else try testing.expectEqual(@as(usize, 0), holes);
    }
}
