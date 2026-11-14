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

/// The arrangement is a planar map whose labels are consistent: Euler's formula over its
/// vertices, edges, bounded faces and connected components (`V − E + F = C`), and across
/// every edge the windings differ by what the inputs contributed to it.
pub fn expectPlanar(o: *const Overlay) !void {
    const n = o.points.items.len;
    var used = try testing.allocator.alloc(bool, n);
    defer testing.allocator.free(used);
    @memset(used, false);
    // The components by union-find over the edges
    var parent = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (o.edges.items) |e| {
        used[e.a] = true;
        used[e.b] = true;
        parent[root(parent, e.a)] = root(parent, e.b);
    }
    var vertices: i64 = 0;
    var components: i64 = 0;
    for (used, 0..) |u, i| {
        vertices += @intFromBool(u);
        components += @intFromBool(u and root(parent, @intCast(i)) == i);
    }
    try testing.expectEqual(components, vertices - @as(i64, @intCast(o.edges.items.len)) + @as(i64, @intCast(o.faces.items.len)));
    for (o.edges.items, 0..) |e, ei| {
        const left = o.leftOf(@intCast(2 * ei));
        const right = o.leftOf(@intCast(2 * ei + 1));
        for (0..o.inputs) |input| {
            var want: i32 = 0;
            for (o.contributions.items[e.first_contribution..][0..e.contributions]) |c| {
                if (c.input == input) want += if (c.along) 1 else -1;
            }
            const wl: i32 = if (left == overlay.UNBOUNDED) 0 else o.windingOf(left, @intCast(input));
            const wr: i32 = if (right == overlay.UNBOUNDED) 0 else o.windingOf(right, @intCast(input));
            errdefer std.debug.print("edge {d}: ({d}, {d}) -> ({d}, {d}){s}, input {d}: faces {d} | {d}, windings {d} | {d}\n", .{ ei, o.point(e.a)[0], o.point(e.a)[1], o.point(e.b)[0], o.point(e.b)[1], if (e.arc == null) "" else " (an arc)", input, left, right, wl, wr });
            try testing.expectEqual(want, wl - wr);
        }
    }
}

fn root(parent: []u32, v: u32) u32 {
    var r = v;
    while (parent[r] != r) r = parent[r];
    return r;
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

test "overlay: a line just missing an arc's circle, within the zone of the arc's end, is cut again on its pieces" {
    // The fuzzer's find of 2026-11-10: a band line of an offset was tangent to a join's
    // circle, floating point said it missed, and the arc's end lay within the zone of the
    // line. Cut at that end, the line's piece ran through it and so crossed the arc a few
    // hundred zones on, with no vertex there: the map was not planar and nothing was
    // labelled right. Here a sector of the unit circle up to 89.75°, and a quad whose
    // near side is the line at distance 1 + 1e-9 along 89.6°: the sector's end is 3.4e-6
    // from that line, the line misses the circle by 1e-9
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    const end_angle = 89.75 * PI / 180.0;
    const tangent_angle = 89.6 * PI / 180.0;
    const end = Vec2{ @cos(end_angle), @sin(end_angle) };
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 1, 0 }, .b = end, .arc = .{ .c = .{ 0, 0 }, .r = 1, .ccw = true } });
    try o.addEdge(.{ .a = end, .b = .{ 0, 0 } });
    try o.addEdge(.{ .a = .{ 0, 0 }, .b = .{ 1, 0 } });
    const n = Vec2{ @cos(tangent_angle), @sin(tangent_angle) };
    const u = Vec2{ -n[1], n[0] };
    const foot = vec.scale2(n, 1 + 1e-9);
    const a = vec.addScaled2(foot, u, 0.5);
    const b = vec.addScaled2(foot, u, -0.5);
    _ = try o.addInput();
    try polygon(&o, &.{ a, b, vec.addScaled2(b, n, 0.5), vec.addScaled2(a, n, 0.5) });
    try o.run();
    try expectPlanar(&o);
    // The sector and the quad do not overlap; the line through the welded end takes a
    // sliver's worth of area from the sector, within the zone along its length
    const sector = areaWhere(&o, 1, 0);
    const quad = areaWhere(&o, 0, 1);
    try testing.expectApproxEqAbs(end_angle / 2.0, sector.area, 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 0.5), quad.area, 1e-5);
    try testing.expectEqual(@as(usize, 0), areaWhere(&o, 1, 1).faces);
}

test "overlay: a line tangent to a circle meets it at one vertex, which cuts the line and the arc" {
    // A unit disc and a square whose bottom side y = 1 touches it at (0, 1), between the
    // arc's ends: the touch is a vertex (the exact discriminant says tangent, never a miss
    // or two crossings a rounding apart) shared by the side and the upper arc, so the
    // square's four sides become five edges and the circle's two halves three
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try circle(&o, .{ 0, 0 }, 1);
    _ = try o.addInput();
    try polygon(&o, &.{ .{ -1, 1 }, .{ 1, 1 }, .{ 1, 3 }, .{ -1, 3 } });
    try o.run();
    try expectPlanar(&o);
    try testing.expectEqual(@as(usize, 8), o.edges.items.len);
    var touch: usize = 0;
    for (o.points.items) |p| touch += @intFromBool(vec.distance2(.{ p[0], p[1] }, .{ 0, 1 }) <= tol.zone);
    try testing.expectEqual(@as(usize, 1), touch);
    try testing.expectEqual(@as(usize, 0), areaWhere(&o, 1, 1).faces);
    try testing.expectApproxEqAbs(PI, areaWhere(&o, 1, 0).area, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), areaWhere(&o, 0, 1).area, 1e-9);
    // The same with the tangent a hair outside the circle: no touch, the map is planar
    // all the same (the vertex nearest the line is 1 away, outside its zone)
    var o2 = Overlay.init(testing.allocator, tol);
    defer o2.deinit();
    _ = try o2.addInput();
    try circle(&o2, .{ 0, 0 }, 1);
    _ = try o2.addInput();
    const above = std.math.nextAfter(f64, 1.0, 2.0);
    try polygon(&o2, &.{ .{ -1, above }, .{ 1, above }, .{ 1, 3 }, .{ -1, 3 } });
    try o2.run();
    try expectPlanar(&o2);
    try testing.expectEqual(@as(usize, 6), o2.edges.items.len);
}

test "overlay: a hole whose leftmost vertex is a circle's centre, the ray through the circle's tangency with a line" {
    // The grown sheet of the fuzzer's chain (offset_test.zig): the ray from the hole's
    // leftmost vertex passes exactly through the point where a join arc touches a band's
    // side, so the two crossings are one point. A hair above the ray the arc is east of
    // the line, so the arc's side (inside the circle) is the region the hole lies in.
    // Here: a region whose boundary runs up x = −1 to the circle's west point, round the
    // circle of radius 1 about the origin, and down again, with a triangle hole whose
    // leftmost vertex is the origin
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    // The outer loop, counter-clockwise: the band below, the circle above
    try o.addEdge(.{ .a = .{ -1, -3 }, .b = .{ 3, -3 } });
    try o.addEdge(.{ .a = .{ 3, -3 }, .b = .{ 3, 0 } });
    try o.addEdge(.{ .a = .{ 3, 0 }, .b = .{ 1, 0 } });
    try o.addEdge(.{ .a = .{ 1, 0 }, .b = .{ -1, 0 }, .arc = .{ .c = .{ 0, 0 }, .r = 1, .ccw = true } });
    try o.addEdge(.{ .a = .{ -1, 0 }, .b = .{ -1, -3 } });
    // The hole, clockwise, its leftmost vertex the circle's centre
    try polygon(&o, &.{ .{ 0, 0 }, .{ 0.5, 0.3 }, .{ 0.5, -0.3 } });
    try o.run();
    try expectPlanar(&o);
    const region = areaWhere(&o, 1, null);
    try testing.expectEqual(@as(usize, 1), region.faces);
    try testing.expectApproxEqAbs(4 * 3 + PI / 2.0 - 0.15, region.area, 1e-9);
}

test "overlay: two arcs meeting a rounding above the ray, where their circles cross at its height, fan down from it" {
    // The fuzzer's find (2026-11-12, an offset's result intersected with its source): the
    // circles of radius √4.5 about (1.5, 0.5) and (1.5, −1.5) cross at (1.5 + √3.5, −0.5),
    // welded to a vertex a rounding above. A region east of both circles has its dents
    // meet there, and a sliver west of it touches it there. The ray from the second
    // input's leftmost vertex, at height −0.5 exactly, meets the region's arc and the
    // sliver's at one exact x; below the vertex the region's arc is the nearer, so the
    // second input lies in the region (taking every tie as a fan up put it in the plane)
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    const r = 2.1213203435596424;
    const v = Vec2{ 3.3708286933869704, -0.4999999999999998 };
    _ = try o.addInput();
    // The region, counter-clockwise, its dents clockwise arcs
    try o.addEdge(.{ .a = v, .b = .{ 3.566037735849056, -1.0188679245283017 }, .arc = .{ .c = .{ 1.5, -1.5 }, .r = r, .ccw = false } });
    try o.addEdge(.{ .a = .{ 3.566037735849056, -1.0188679245283017 }, .b = .{ 7, -1.5 } });
    try o.addEdge(.{ .a = .{ 7, -1.5 }, .b = .{ 7, 1 } });
    try o.addEdge(.{ .a = .{ 7, 1 }, .b = .{ 3.6213203435596424, 0.5 } });
    try o.addEdge(.{ .a = .{ 3.6213203435596424, 0.5 }, .b = v, .arc = .{ .c = .{ 1.5, 0.5 }, .r = r, .ccw = false } });
    // The sliver, counter-clockwise
    try o.addEdge(.{ .a = v, .b = .{ 3, 0 }, .arc = .{ .c = .{ 1.5, -1.5 }, .r = r, .ccw = true } });
    try o.addEdge(.{ .a = .{ 3, 0 }, .b = .{ 3.2926829268292686, -0.6341463414634141 } });
    try o.addEdge(.{ .a = .{ 3.2926829268292686, -0.6341463414634141 }, .b = v, .arc = .{ .c = .{ 1.5, 0.5 }, .r = r, .ccw = true } });
    _ = try o.addInput();
    try polygon(&o, &.{ .{ 4, -0.5 }, .{ 5, -0.8 }, .{ 6, -0.5 }, .{ 5, 0 } });
    try o.run();
    try expectPlanar(&o);
    const both = areaWhere(&o, 1, 1);
    try testing.expectEqual(@as(usize, 1), both.faces);
    try testing.expectApproxEqAbs(@as(f64, 0.8), both.area, 1e-12);
    try testing.expectEqual(@as(usize, 0), areaWhere(&o, 0, 1).faces);
}

test "overlay: a hole's ray through a circle's lowest point, an extreme and no vertex, passes the circle by" {
    // The overlay fuzz target's find (2026-11-12): a component's leftmost vertex at y = 1,
    // and to its west a circle of radius 0.5 about (0.5, 1.5) whose lowest point is at
    // y = 1 exactly, between its two arcs' ends at (0, 1.5) and (1, 1.5). The ray meets the
    // circle's two pieces at x = 0.5, level and opposite, a tie at no vertex; a hair above,
    // the east piece is nearer and the region east of it is outside the circle. The bend
    // chose the west piece and nested the component inside the circle, offsetting all its
    // labels by the circle's winding
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 1, 1.5 }, .b = .{ 0, 1.5 }, .arc = .{ .c = .{ 0.5, 1.5 }, .r = 0.5, .ccw = false } });
    try o.addEdge(.{ .a = .{ 0, 1.5 }, .b = .{ 1, 1.5 }, .arc = .{ .c = .{ 0.5, 1.5 }, .r = 0.5, .ccw = false } });
    _ = try o.addInput();
    try polygon(&o, &.{ .{ 1.75, 1 }, .{ 3, 0 }, .{ 4, 1 }, .{ 3, 2 } });
    try o.run();
    try expectPlanar(&o);
    // The diamond is outside the circle: wound by its own input alone
    const diamond = areaWhere(&o, 0, 1);
    try testing.expectEqual(@as(usize, 1), diamond.faces);
    try testing.expectApproxEqAbs(@as(f64, 2.25), diamond.area, 1e-12);
    try testing.expectEqual(@as(usize, 0), areaWhere(&o, 1, 1).faces + areaWhere(&o, -1, 1).faces);
}

test "overlay: a hole's ray through an arc's lowest point, the arc's west piece ending straight above it" {
    // The overlay fuzz target's find (2026-11-13), reduced: a circle whose leftmost vertex
    // is at y = 1, and to its west a three-quarter arc, clockwise about (0.25, 3.5) from
    // its east point down through its lowest point (0.25, 1) and round to its top (0.25, 6),
    // closed by a line. Its west piece runs from the lowest point to the top straight
    // above it, so the direction it leaves the lowest point by, taken from the way to its
    // top, was east, the east piece's own: the tie went to the west piece and the circle
    // was nested inside the arc's region, its labels offset by that winding
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 2.75, 3.5 }, .b = .{ 0.25, 6 }, .arc = .{ .c = .{ 0.25, 3.5 }, .r = 2.5, .ccw = false } });
    try o.addEdge(.{ .a = .{ 0.25, 6 }, .b = .{ 2.75, 3.5 } });
    _ = try o.addInput();
    try circle(&o, .{ 2, 1 }, 0.25);
    try o.run();
    try expectPlanar(&o);
    // The circle is outside the arc's region: wound by its own input alone
    const disc = areaWhere(&o, 0, 1);
    try testing.expectEqual(@as(usize, 1), disc.faces);
    try testing.expectApproxEqAbs(PI * 0.25 * 0.25, disc.area, 1e-9);
    try testing.expectEqual(@as(usize, 0), areaWhere(&o, 1, 1).faces + areaWhere(&o, -1, 1).faces);
}

test "overlay: a cycle that runs each of its edges both ways bounds nothing, whatever its area's rounding" {
    // The overlay fuzz target's find (2026-11-12): three collinear points, one a rounding
    // off the grid, closed into a ring of no area. Its cycle runs both edges each way; the
    // area's sum rounded to 2e-16 and made it a face, and Euler's formula counted a
    // component too many. A slit standing alone and a tree of three edges likewise
    for ([_][]const Vec2{
        &.{ .{ 0.5, 2 }, .{ 1.2500000000000002, 2 }, .{ 4, 2 } },
        &.{ .{ 0.1, 0.3 }, .{ 2.7, 1.9 }, .{ 0.1, 0.3 } },
    }) |ring| {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        for (ring, 0..) |a, i| {
            const b = ring[(i + 1) % ring.len];
            if (a[0] != b[0] or a[1] != b[1]) try o.addEdge(.{ .a = a, .b = b });
        }
        try o.run();
        try expectPlanar(&o);
        try testing.expectEqual(@as(usize, 0), o.faces.items.len);
    }
    // A tree of three edges, traced there and back (an input is closed)
    var tree = Overlay.init(testing.allocator, tol);
    defer tree.deinit();
    _ = try tree.addInput();
    for ([_][2]Vec2{ .{ .{ 0, 0 }, .{ 1, 0 } }, .{ .{ 1, 0 }, .{ 2, 1 } }, .{ .{ 1, 0 }, .{ 2, -1 } } }) |e| {
        try tree.addEdge(.{ .a = e[0], .b = e[1] });
        try tree.addEdge(.{ .a = e[1], .b = e[0] });
    }
    try tree.run();
    try expectPlanar(&tree);
    try testing.expectEqual(@as(usize, 0), tree.faces.items.len);
}

/// The overlay fuzz target's find of 2026-11-12, as its arrangement printed it.
fn bisectedCircle(o: *Overlay) !void {
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 2.25, 0.75 }, .b = .{ 0.25, 0.7500000000000001 }, .arc = .{ .c = .{ 1.25, 0.75 }, .r = 1, .ccw = true } });
    try o.addEdge(.{ .a = .{ 0.25, 0.7500000000000001 }, .b = .{ 2.25, 0.75 }, .arc = .{ .c = .{ 1.25, 0.75 }, .r = 1, .ccw = true } });
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 2.25, 0.5 }, .b = .{ 6.000000000000001, 0.75 } });
    try o.addEdge(.{ .a = .{ 6.000000000000001, 0.75 }, .b = .{ 4, 4 }, .arc = .{ .c = .{ 3.375, 1.3749999999999996 }, .r = 2.6983791431153636, .ccw = true } });
    try o.addEdge(.{ .a = .{ 4, 4 }, .b = .{ 5.5, 1.25 }, .arc = .{ .c = .{ 3.375, 1.875 }, .r = 2.2150056433336687, .ccw = false } });
    try o.addEdge(.{ .a = .{ 5.5, 1.25 }, .b = .{ 0.25, 0.75 }, .arc = .{ .c = .{ 2.75, 2.3125 }, .r = 2.948119103767689, .ccw = false } });
    try o.addEdge(.{ .a = .{ 0.25, 0.75 }, .b = .{ 2.75, 0.75 } });
    try o.addEdge(.{ .a = .{ 2.75, 0.75 }, .b = .{ 3.5, 3.25 } });
    try o.addEdge(.{ .a = .{ 3.5, 3.25 }, .b = .{ 0.75, 1 } });
    try o.addEdge(.{ .a = .{ 0.75, 1 }, .b = .{ 2.25, 0.5 } });
}

test "overlay: a circle's west extreme a rounding from the vertex its arcs leave is that vertex" {
    // The overlay fuzz target's find (2026-11-12): a circle in two halves meeting at
    // (0.25, 0.75 + 1 ulp), its west extreme one rounding below, and a ring whose line
    // runs through both its vertices and whose arc leaves the same vertex. Taken from the
    // extreme, the ray crossed that arc a rounding to the west (its radius rounded), and
    // the component's outer boundary was nested as a hole of one of its own faces: every
    // label 0. From the vertex, the edges leaving it meet the ray where it starts
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    try bisectedCircle(&o);
    try o.run();
    try expectPlanar(&o);
    // The circle wound once over all of its disc
    try testing.expectApproxEqAbs(@as(f64, PI), areaWhere(&o, 1, null).area, 1e-9);
}

test "overlay: a ray a rounding above a vertex an arc and a line leave orders them as the overlay did" {
    // The overlay fuzz target's find (2026-11-12): a small circle's leftmost vertex one
    // ulp above the height of a vertex (2.75, 0.25) that a line and an arc leave upward;
    // at that height the arc's exact crossing (its radius rounded, its welded end a
    // rounding off its circle) fell west of the line's, the circle was nested in the wrong
    // region and labelled −1 for the polygon it lies outside of
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 0.5, 2 }, .b = .{ 1.5, 4 }, .arc = .{ .c = .{ 0.5, 3.25 }, .r = 1.25, .ccw = true } });
    try o.addEdge(.{ .a = .{ 1.5, 4 }, .b = .{ 0.5, 2 }, .arc = .{ .c = .{ 0.5, 3.25 }, .r = 1.25, .ccw = false } });
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 4, 0.25 }, .b = .{ 3.5, 0.25000000000000006 }, .arc = .{ .c = .{ 3.75, 0.25 }, .r = 0.25, .ccw = false } });
    try o.addEdge(.{ .a = .{ 3.5, 0.25000000000000006 }, .b = .{ 4, 0.25 }, .arc = .{ .c = .{ 3.75, 0.25 }, .r = 0.25, .ccw = false } });
    for ([_][2]Vec2{ .{ .{ 4.5, 1 }, .{ 4.25, 0.75 } }, .{ .{ 4.25, 0.75 }, .{ 4, 1 } }, .{ .{ 4, 1 }, .{ 4.25, 1.25 } }, .{ .{ 4.25, 1.25 }, .{ 4.5, 1 } } }) |e| {
        try o.addEdge(.{ .a = e[0], .b = e[1], .arc = .{ .c = .{ 4.25, 1 }, .r = 0.25, .ccw = false } });
    }
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 2.75, 0.25 }, .b = .{ 3.5, 6 } });
    try o.addEdge(.{ .a = .{ 3.5, 6 }, .b = .{ 0, 5.5 }, .arc = .{ .c = .{ 2, 4 }, .r = 2.5, .ccw = true } });
    try o.addEdge(.{ .a = .{ 0, 5.5 }, .b = .{ 2.75, 0.25 }, .arc = .{ .c = .{ 0.0625, 2.1875 }, .r = 3.313089570174643, .ccw = false } });
    try o.addEdge(.{ .a = .{ 0, 3.25 }, .b = .{ 1.75, 0.5 } });
    try o.addEdge(.{ .a = .{ 1.75, 0.5 }, .b = .{ 2, 3.25 }, .arc = .{ .c = .{ 0.5, 2 }, .r = 1.9525624189766635, .ccw = false } });
    try o.addEdge(.{ .a = .{ 2, 3.25 }, .b = .{ 1, 3.25 } });
    try o.addEdge(.{ .a = .{ 1, 3.25 }, .b = .{ 6, 4 } });
    try o.addEdge(.{ .a = .{ 6, 4 }, .b = .{ 1.75, 2 }, .arc = .{ .c = .{ 4.375, 1.9375 }, .r = 2.6257439422000006, .ccw = true } });
    try o.addEdge(.{ .a = .{ 1.75, 2 }, .b = .{ 3.25, 1.25 } });
    try o.addEdge(.{ .a = .{ 3.25, 1.25 }, .b = .{ 1.25, 0.5 } });
    try o.addEdge(.{ .a = .{ 1.25, 0.5 }, .b = .{ 0, 3.25 } });
    try o.run();
    try expectPlanar(&o);
    // The faces inside the small circle (every vertex of their outer cycle in its box):
    // wound once by it, clockwise, and not at all by the polygon east of which it lies
    var inside: usize = 0;
    for (o.faces.items, 0..) |f, i| {
        const in_box = for (o.halvesOf(f.outer)) |h| {
            const p = o.point(o.origin(h));
            if (p[0] < 3.5 - 1e-9 or p[0] > 4 + 1e-9 or p[1] < -1e-9 or p[1] > 0.5 + 1e-9) break false;
        } else true;
        if (!in_box) continue;
        inside += 1;
        try testing.expectEqual(@as(i32, -1), o.windingOf(@intCast(i), 1));
        try testing.expectEqual(@as(i32, 0), o.windingOf(@intCast(i), 2));
    }
    try testing.expectEqual(@as(usize, 1), inside);
}

test "overlay: two arcs between the same vertices within the zone of each other are one edge, the lens between them no region" {
    // Over a chord 0.02 long, circles of radius 2.5 and 2.2 bow 2e-5 and 2.27e-5: each
    // past the zone of the chord, the two 2.7e-6 apart
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    const a = Vec2{ 0, 0 };
    const b = Vec2{ 0.02, 0 };
    const r1 = 2.5;
    const r2 = 2.2;
    try o.addEdge(.{ .a = a, .b = b, .arc = .{ .c = .{ 0.01, @sqrt(r1 * r1 - 1e-4) }, .r = r1, .ccw = true } });
    try o.addEdge(.{ .a = b, .b = a, .arc = .{ .c = .{ 0.01, @sqrt(r2 * r2 - 1e-4) }, .r = r2, .ccw = false } });
    try o.run();
    try testing.expectEqual(@as(usize, 1), o.edges.items.len);
    try testing.expectEqual(@as(u32, 2), o.edges.items[0].contributions);
    try testing.expectEqual(@as(usize, 0), o.faces.items.len);
    try expectPlanar(&o);
}

test "overlay: a ring doubling back along a tangent circle, a line crossing both arcs where they are within the zone, is planar" {
    // The nightly's find (run 43525003122, locus): the arcs of two internally tangent
    // circles meet at (4.5, 4.25), the ring turning back there; the line's crossings with
    // both, 0.0165 from it, weld to one vertex, and both arcs cut there made two edges
    // between the same vertices, a lens of area 1.9e-8 the map counted as a cycle
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 0, 4.25 }, .b = .{ 4.5, 4.25 }, .arc = .{ .c = .{ 2.25, 5.375 }, .r = 2.5155764746872635, .ccw = true } });
    try o.addEdge(.{ .a = .{ 4.5, 4.25 }, .b = .{ 0.5, 4.25 }, .arc = .{ .c = .{ 2.5, 5.25 }, .r = 2.23606797749979, .ccw = false } });
    try o.addEdge(.{ .a = .{ 0.5, 4.25 }, .b = .{ 1, 3.5 }, .arc = .{ .c = .{ 1.125, 4.125 }, .r = 0.6373774391990981, .ccw = true } });
    try o.addEdge(.{ .a = .{ 1, 3.5 }, .b = .{ 5.750000000000001, 4.5 } });
    try o.addEdge(.{ .a = .{ 5.750000000000001, 4.5 }, .b = .{ 5.75, 6 } });
    try o.addEdge(.{ .a = .{ 5.75, 6 }, .b = .{ 0, 4.25 }, .arc = .{ .c = .{ 3.75, 2.25 }, .r = 4.25, .ccw = true } });
    try o.run();
    try expectPlanar(&o);
}

test "overlay: circles missing each other by less than the zone meet nowhere, exactly" {
    // A circle inside another, 1e-6 short of it at the top, where neither has an end: the
    // meeting test on the square-rooted distance with the zone's slack took them as
    // touching there and cut both at a point on neither; the exact signs of their centres
    // and radii say nested (D26)
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try circle(&o, .{ 0, 0 }, 2);
    _ = try o.addInput();
    try circle(&o, .{ 0, 1 }, 1 - 1e-6);
    try o.run();
    try testing.expectEqual(@as(usize, 4), o.points.items.len);
    for (o.points.items) |p| try testing.expect(@abs(p[0]) > 0.5);
    try expectPlanar(&o);
}

test "overlay: circles touching exactly meet at one vertex, crossing at two" {
    // Internally tangent (centres 1.25 apart, radii 3 and 1.75), the touch at (2.4, 1.8)
    // where neither has an end; and a pair crossing near tangency
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try circle(&o, .{ 0, 0 }, 3);
    _ = try o.addInput();
    try circle(&o, .{ 0.75, 1 }, 1.75);
    try o.run();
    var at_touch: usize = 0;
    for (o.points.items) |p| at_touch += @intFromBool(vec.distance2(.{ p[0], p[1] }, .{ 1.8, 2.4 }) <= tol.zone);
    try testing.expectEqual(@as(usize, 1), at_touch);
    try expectPlanar(&o);
}

test "overlay: a sliver far from the origin is a face, its area as near the origin" {
    // A cycle's signed area summed about the world's origin: a sliver 1e7 out summed
    // terms of 1e14 to an area of 0, and a cycle of no area is no face. About a point
    // of the cycle the sum is as near as anywhere else (D27's rule: from a local point)
    const sliver = [_]Vec2{ .{ 0, 0 }, .{ 1, 0 }, .{ 0.5, 0.01 } };
    var areas: [2]f64 = undefined;
    for ([_]Vec2{ .{ 0, 0 }, .{ 1e7, 1e7 } }, &areas) |at, *area| {
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        var ring: [3]Vec2 = undefined;
        for (sliver, &ring) |p, *q| q.* = vec.add2(p, at);
        try polygon(&o, &ring);
        try o.run();
        try expectPlanar(&o);
        try testing.expectEqual(@as(usize, 1), o.faces.items.len);
        area.* = areaWhere(&o, 1, null).area;
    }
    // The far sliver's apex is where its coordinates round it, 1.9e-9 at most
    try testing.expectApproxEqAbs(@as(f64, 0.005), areas[0], 1e-15);
    try testing.expectApproxEqAbs(areas[0], areas[1], 1e-9);
}
