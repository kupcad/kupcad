//! The overlay on the corpus the plan names: squares overlapping, touching, nested, sharing
//! part of an edge, three edges through one point, a bow tie, circles with squares and
//! with each other, tangent circles; each case checked by its faces' windings and areas.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const overlay = @import("overlay.zig");
const Overlay = overlay.Overlay;
const Vec2 = vec.Vec2;

const tol = Tolerance.fromZone(1e-5);
const PI = std.math.pi;

/// The island family (the test of an island beside a circle in each quarter turn): the
/// circle, the islands' radius, and the shift after the turn, the numbers of the find it
/// was built around (the overlay fuzz target, 2026-11-19, bj).
const FAMILY_CIRCLE_CENTRE: Vec2 = .{ 3.25, 2.25 };
const FAMILY_CIRCLE_RADIUS: f64 = 3;
const FAMILY_ISLAND_RADIUS: f64 = 0.25;
const FAMILY_SHIFT: Vec2 = .{ 0.5, -1 };
/// The quarter turns of a whole turn, and the inputs of the family (the islands, the circle).
const QUARTER_TURNS: usize = 4;
const FAMILY_INPUTS: usize = 2;
/// How far inside a face its probe point is taken (`probeOf`), and the share of that
/// every circle must keep from it for the point to be in the face.
const PROBE_INSET: f64 = 1e-3;
const PROBE_CLEAR: f64 = 0.999;
/// How near the areas of a face in two turns of one arrangement are.
const TURNED_AREA_CLOSE: f64 = 1e-9;
/// Where a circle's four arcs end, as directions from its centre: its extremes, or its
/// lattice points (3, 4, 5), which no quarter turn brings to an extreme.
const EXTREME_ENDS = [QUARTER_TURNS]Vec2{ .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 } };
const LATTICE_ENDS = [QUARTER_TURNS]Vec2{ .{ 4, -3 }, .{ 3, 4 }, .{ -4, 3 }, .{ -3, -4 } };
const LATTICE_HYPOTENUSE: f64 = 5;

/// The hair family (the test of an arc one of whose ends is the least double off an
/// extreme of its circle about the origin): the hair; the radii, whose product with the
/// hair rounds to nothing (0.25), ties and rounds to nothing (0.5) and is the hair (1);
/// the arc's other end as a direction from the centre before the quarter turn, a lattice
/// point; and the probes, as shares of the radius, at heights whose crossings of the circle
/// are 6.8° or more from every end of the family.
const HAIR: f64 = std.math.floatTrueMin(f64);
const HAIR_RADII = [_]f64{ 0.25, 0.5, 1 };
const HAIR_OTHER_END: Vec2 = .{ 0.6, -0.8 };
const HAIR_PROBE_HEIGHTS = [_]f64{ -0.5, 0.5 };
const HAIR_PROBE_XS = [_]f64{ -2, 0, 2 };

/// The stub family (the tests of an arc piece within the zone of its chord): the arc's
/// radius; the angles of the stub a line cuts off its end, each within the zone of its
/// chord (`√(8·zone/r)`, 4.5e-3 at this radius, is the most), the second the find's (the
/// nightly of 2026-11-20, bm); the angle of an arc past the zone of its chord; and the
/// angle the rest of the arc runs through.
const STUB_RADIUS: f64 = 4;
const STUB_ANGLES = [_]f64{ 3e-4, 1.2e-3, 4e-3 };
const STUB_PAST_CHORD: f64 = 1e-2;
const STUB_REST: f64 = 1;

/// Where a circle's four arcs end: at its extremes exactly; at its extremes as their
/// angles' cosine and sine give them (`angled`: as the fuzzer and a caller working in
/// angles draw an arc, an end a rounding to one side of the extreme, 3.25 − 5.5e-16 for
/// 3.25); or at its lattice points.
const Ends = enum { extremes, angled, lattice };

/// A case of the island family: what the island's line passes through (the ray from its
/// leftmost point to −x, which `nestCycles` places it by), where the circle's arcs end,
/// and the island's centre from the circle's as the overlay is given them.
const IslandLineCase = struct {
    name: []const u8,
    ends: Ends,
    island: Vec2,
};

const ISLAND_LINE_CASES = [_]IslandLineCase{
    .{ .name = "the circle's lowest point, no arc's end there", .ends = .lattice, .island = .{ 2.25, -FAMILY_CIRCLE_RADIUS } },
    .{ .name = "the circle's lowest point, two arcs' end", .ends = .extremes, .island = .{ 2.25, -FAMILY_CIRCLE_RADIUS } },
    .{ .name = "the circle's lowest point, two arcs' end a rounding off it", .ends = .angled, .island = .{ 2.25, -FAMILY_CIRCLE_RADIUS } },
    .{ .name = "the circle's highest point, no arc's end there", .ends = .lattice, .island = .{ 2.25, FAMILY_CIRCLE_RADIUS } },
    .{ .name = "the circle's highest point, two arcs' end", .ends = .extremes, .island = .{ 2.25, FAMILY_CIRCLE_RADIUS } },
    .{ .name = "the circle's highest point, two arcs' end a rounding off it", .ends = .angled, .island = .{ 2.25, FAMILY_CIRCLE_RADIUS } },
    .{ .name = "an arc's end where the circle crosses the line, the island outside", .ends = .lattice, .island = .{ 3.5, endOf(.lattice, 0, FAMILY_CIRCLE_RADIUS)[1] } },
    .{ .name = "an arc's end where the circle crosses the line, the island inside", .ends = .lattice, .island = .{ 0, endOf(.lattice, 2, FAMILY_CIRCLE_RADIUS)[1] } },
    .{ .name = "the circle's east and west points, arcs' ends, the island outside", .ends = .extremes, .island = .{ 3.5, 0 } },
    .{ .name = "the circle's east and west points, arcs' ends, the island inside", .ends = .extremes, .island = .{ 1, 0 } },
    .{ .name = "the circle's east and west points, arcs' ends a rounding off them, the island outside", .ends = .angled, .island = .{ 3.5, 0 } },
    .{ .name = "the circle's east and west points, arcs' ends a rounding off them, the island inside", .ends = .angled, .island = .{ 1, 0 } },
    .{ .name = "the circle between its arcs' ends, the island outside", .ends = .lattice, .island = .{ 3.5, 0.5 } },
    .{ .name = "the circle between its arcs' ends, the island inside", .ends = .lattice, .island = .{ 1, 0.5 } },
};

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

/// End `k` of a circle of radius `r` about the origin whose four arcs end at `ends`.
fn endOf(ends: Ends, k: usize, r: f64) Vec2 {
    return switch (ends) {
        .extremes => vec.scale2(EXTREME_ENDS[k], r),
        .angled => .{ r * @cos(@as(f64, @floatFromInt(k)) * PI / 2.0), r * @sin(@as(f64, @floatFromInt(k)) * PI / 2.0) },
        .lattice => vec.scale2(LATTICE_ENDS[k], r / LATTICE_HYPOTENUSE),
    };
}

/// A counter-clockwise circle as four arcs between its `ends`.
fn fourArcs(c: Vec2, r: f64, ends: Ends) [QUARTER_TURNS]overlay.InputEdge {
    var arcs: [QUARTER_TURNS]overlay.InputEdge = undefined;
    for (&arcs, 0..) |*arc, k| arc.* = .{ .a = vec.add2(c, endOf(ends, k, r)), .b = vec.add2(c, endOf(ends, (k + 1) % QUARTER_TURNS, r)), .arc = .{ .c = c, .r = r, .ccw = true } };
    return arcs;
}

/// `p` turned about the origin by the angle whose cosine and sine are `turn`, then
/// shifted: as the fuzzer moves a whole arrangement, the turn's rounding with it (the
/// cosine of a quarter turn is 6.1e-17, not 0).
fn movedPoint(p: Vec2, turn: Vec2, shift: Vec2) Vec2 {
    return .{ turn[0] * p[0] - turn[1] * p[1] + shift[0], turn[1] * p[0] + turn[0] * p[1] + shift[1] };
}

/// Edge `e` moved as `movedPoint` moves its ends and its arc's centre.
fn movedEdge(e: overlay.InputEdge, turn: Vec2, shift: Vec2) overlay.InputEdge {
    var moved: overlay.InputEdge = .{ .a = movedPoint(e.a, turn, shift), .b = movedPoint(e.b, turn, shift) };
    if (e.arc) |arc| moved.arc = .{ .c = movedPoint(arc.c, turn, shift), .r = arc.r, .ccw = arc.ccw };
    return moved;
}

/// A whole circle of an input, for the count `expectDiscWindings` makes of its own.
const Disc = struct {
    input: u32,
    c: Vec2,
    r: f64,
    ccw: bool = true,
};

/// A point `PROBE_INSET` inside face `f`: left of the middle of its outer cycle's longest
/// half-edge.
fn probeOf(o: *const Overlay, f: overlay.Face) Vec2 {
    var probe: Vec2 = undefined;
    var longest: f64 = -1;
    for (o.halvesOf(f.outer)) |h| {
        const a = o.point(o.origin(h));
        const b = o.point(o.target(h));
        if (o.arcOf(h)) |arc| {
            const sweep = overlay.arcSweep(a, b, arc);
            if (arc.r * sweep <= longest) continue;
            longest = arc.r * sweep;
            const start = trig.atan2(a[1] - arc.c[1], a[0] - arc.c[0]);
            const angle = if (arc.ccw) start + sweep / 2 else start - sweep / 2;
            // Left of a counter-clockwise arc is toward its centre
            const r = if (arc.ccw) arc.r - PROBE_INSET else arc.r + PROBE_INSET;
            probe = .{ arc.c[0] + r * @cos(angle), arc.c[1] + r * @sin(angle) };
            continue;
        }
        const length = vec.distance2(a, b);
        if (length <= longest) continue;
        longest = length;
        const along = vec.scale2(vec.sub2(b, a), 1 / length);
        probe = vec.add2(vec.scale2(vec.add2(a, b), 0.5), vec.scale2(vec.perp2(along), PROBE_INSET));
    }
    return probe;
}

/// Every face's winding of every input against a count of its own, for an arrangement of
/// whole circles: at a point just inside the face (`probeOf`, every circle further from
/// it than the way it was stepped in by, so it is in the face), an input winds once for
/// each of its counter-clockwise circles the point is inside, once back for each
/// clockwise one, told by the point's distance from their centres: no ray, no arc piece,
/// nothing the overlay nests or labels by.
fn expectDiscWindings(o: *const Overlay, discs: []const Disc) !void {
    for (o.faces.items, 0..) |f, fi| {
        const p = probeOf(o, f);
        for (discs) |d| try testing.expect(@abs(vec.distance2(p, d.c) - d.r) > PROBE_CLEAR * PROBE_INSET);
        for (0..o.inputs) |k| {
            var want: i32 = 0;
            for (discs) |d| {
                if (d.input == k and vec.distance2(p, d.c) < d.r) want += if (d.ccw) 1 else -1;
            }
            errdefer std.debug.print("face {d} at ({d}, {d}): input {d}\n", .{ fi, p[0], p[1], k });
            try testing.expectEqual(want, o.windingOf(@intCast(fi), @intCast(k)));
        }
    }
}

/// A face of the island family by what a turn leaves it: its windings and its area.
const TurnedFace = struct {
    windings: [FAMILY_INPUTS]i32,
    area: f64,

    fn lessThan(_: void, x: TurnedFace, y: TurnedFace) bool {
        for (x.windings, y.windings) |wx, wy| if (wx != wy) return wx < wy;
        return x.area < y.area;
    }
};

/// The faces of `o` as `TurnedFace`s, in an order no turn changes.
fn turnedFaces(o: *const Overlay, faces: *std.ArrayList(TurnedFace)) !void {
    faces.clearRetainingCapacity();
    for (o.faces.items, 0..) |f, fi| {
        var face: TurnedFace = .{ .windings = undefined, .area = o.cycles.items[f.outer].area };
        for (&face.windings, 0..) |*w, k| w.* = o.windingOf(@intCast(fi), @intCast(k));
        for (o.holesOf(@intCast(fi))) |h| face.area += o.cycles.items[h].area;
        try faces.append(testing.allocator, face);
    }
    std.mem.sort(TurnedFace, faces.items, {}, TurnedFace.lessThan);
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
    // The same with the tangent a hair outside the circle, and half the zone outside:
    // within the zone, a touch all the same (coincidence first, D16; the exact sign said a
    // miss); twice the zone outside, none, and the map is planar all the same
    for ([_]f64{ std.math.nextAfter(f64, 1.0, 2.0), 1 + tol.zone / 2, 1 + 2 * tol.zone }) |above| {
        var o2 = Overlay.init(testing.allocator, tol);
        defer o2.deinit();
        _ = try o2.addInput();
        try circle(&o2, .{ 0, 0 }, 1);
        _ = try o2.addInput();
        try polygon(&o2, &.{ .{ -1, above }, .{ 1, above }, .{ 1, 3 }, .{ -1, 3 } });
        try o2.run();
        try expectPlanar(&o2);
        const touches = above - 1 <= tol.zone;
        try testing.expectEqual(@as(usize, if (touches) 8 else 6), o2.edges.items.len);
    }
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

test "overlay: an island's ray through a circle's lowest point, the circle's vertex a rounding west of it, passes the circle by" {
    // The overlay fuzz target's find (the nightly of 2026-11-19, run 44568960243, bj), as
    // the fuzzer drew it and moved it whole, a quarter turn and (0.5, -1): a small circle
    // about (0.5, -0.75), an island touching nothing, and to its west a circle of radius 3
    // about (-1.75, 2.25) whose lowest point (-1.75, -0.75) is on the island's ray, with
    // the vertex its two lower arcs end at turned to (-1.7500000000000004,
    // -0.7499999999999999), a rounding west of that point and above. The arc leaving the
    // vertex has a piece 4.4e-16 wide down to the lowest point, on the west half; its
    // side was told by the cosine of its middle's angle, a rounding of straight down, and
    // read east (its twin half-edge read it west): the piece tied the true east piece on
    // the ray, level and now the same way, and the bend chose it, nesting the island
    // inside the circle with its labels offset by the circle's winding
    const quarter: Vec2 = .{ @cos(PI / 2.0), @sin(PI / 2.0) };
    const shift: Vec2 = .{ 0.5, -1 };
    const drawn = [_][]const overlay.InputEdge{
        &.{
            .{ .a = .{ 0.5, 0 }, .b = .{ 0, 0.00000000000000003061616997868383 }, .arc = .{ .c = .{ 0.25, 0 }, .r = 0.25, .ccw = false } },
            .{ .a = .{ 0, 0.00000000000000003061616997868383 }, .b = .{ 0.5, 0 }, .arc = .{ .c = .{ 0.25, 0 }, .r = 0.25, .ccw = false } },
            .{ .a = .{ 4.5, 1.75 }, .b = .{ 0.5, 1.7500000000000002 }, .arc = .{ .c = .{ 2.5, 1.75 }, .r = 2, .ccw = true } },
            .{ .a = .{ 0.5, 1.7500000000000002 }, .b = .{ 4.5, 1.75 }, .arc = .{ .c = .{ 2.5, 1.75 }, .r = 2, .ccw = true } },
        },
        &.{
            .{ .a = .{ 6.25, 2.25 }, .b = .{ 3.25, 5.25 }, .arc = .{ .c = .{ 3.25, 2.25 }, .r = 3, .ccw = true } },
            .{ .a = .{ 3.25, 5.25 }, .b = .{ 0.25, 2.2500000000000004 }, .arc = .{ .c = .{ 3.25, 2.25 }, .r = 3, .ccw = true } },
            .{ .a = .{ 0.25, 2.2500000000000004 }, .b = .{ 3.2499999999999996, -0.75 }, .arc = .{ .c = .{ 3.25, 2.25 }, .r = 3, .ccw = true } },
            .{ .a = .{ 3.2499999999999996, -0.75 }, .b = .{ 6.25, 2.25 }, .arc = .{ .c = .{ 3.25, 2.25 }, .r = 3, .ccw = true } },
        },
        &.{
            .{ .a = .{ 7.75, 0.25 }, .b = .{ 1.75, 0.2500000000000004 }, .arc = .{ .c = .{ 4.75, 0.25 }, .r = 3, .ccw = false } },
            .{ .a = .{ 1.75, 0.2500000000000004 }, .b = .{ 7.75, 0.25 }, .arc = .{ .c = .{ 4.75, 0.25 }, .r = 3, .ccw = false } },
            .{ .a = .{ 4, 5.25 }, .b = .{ 1.0000000000000002, 8.25 }, .arc = .{ .c = .{ 1, 5.25 }, .r = 3, .ccw = true } },
            .{ .a = .{ 1.0000000000000002, 8.25 }, .b = .{ -2, 5.25 }, .arc = .{ .c = .{ 1, 5.25 }, .r = 3, .ccw = true } },
            .{ .a = .{ -2, 5.25 }, .b = .{ 0.9999999999999994, 2.25 }, .arc = .{ .c = .{ 1, 5.25 }, .r = 3, .ccw = true } },
            .{ .a = .{ 0.9999999999999994, 2.25 }, .b = .{ 4, 5.25 }, .arc = .{ .c = .{ 1, 5.25 }, .r = 3, .ccw = true } },
        },
    };
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    for (drawn) |edges| {
        _ = try o.addInput();
        for (edges) |e| try o.addEdge(movedEdge(e, quarter, shift));
    }
    try o.run();
    try expectPlanar(&o);
    // The island is the one clockwise circle of the first input and outside every other
    // circle: one face wound -1 by its own input, and by no other
    var islands: usize = 0;
    for (o.faces.items, 0..) |f, fi| {
        if (o.windingOf(@intCast(fi), 0) != -1) continue;
        islands += 1;
        try testing.expectApproxEqAbs(PI * 0.25 * 0.25, o.cycles.items[f.outer].area, 1e-9);
        try testing.expectEqual(@as(i32, 0), o.windingOf(@intCast(fi), 1));
        try testing.expectEqual(@as(i32, 0), o.windingOf(@intCast(fi), 2));
    }
    try testing.expectEqual(@as(usize, 1), islands);
}

test "overlay: an island beside a circle, its line through the circle's lowest or highest point, an arc's end or between, is labelled alike in each quarter turn" {
    // The cases about the find above (Leo, 2026-11-19: a line through a circle's lowest or
    // highest point or an arc's end, across the quarter turns, is where angle sorting,
    // tangent splitting and interval ordering turn over, and a matrix of them around a
    // confirmed find costs no refusal elsewhere). An island is placed by the ray from its
    // leftmost point to −x (`nestCycles`): each case names what of the circle is on that
    // line, with the island east of the circle or inside it. Four islands stand about the
    // circle, each a quarter turn on from the last, so that every quarter turn of the
    // whole arrangement (turned as the fuzzer turns one, by the rounded cosine and sine,
    // then shifted) brings one of them onto the line named and leaves the others north,
    // west and south of it, their rays clear of the circle or across it elsewhere. The
    // islands' own arcs end each way the circle's may (`Ends`: the leftmost point a vertex
    // at the extreme, one a rounding off it, or an arc's west extreme between its ends).
    // Every face's winding of both inputs is held against a count of its
    // own (`expectDiscWindings`), and the faces of the four turns are the same faces
    for (ISLAND_LINE_CASES) |case| for (std.enums.values(Ends)) |island_ends| {
        errdefer std.debug.print("on the island's line: {s}; the islands' arcs end at their {s}\n", .{ case.name, @tagName(island_ends) });
        try expectTurnsAlike(case, island_ends);
    };
}

/// One case of the island family with the islands' arcs ending at `island_ends`, in each
/// quarter turn: planar, every face's windings as `expectDiscWindings` counts them, and
/// the faces those of the arrangement unturned.
fn expectTurnsAlike(case: IslandLineCase, island_ends: Ends) !void {
    var first: std.ArrayList(TurnedFace) = .empty;
    defer first.deinit(testing.allocator);
    var faces: std.ArrayList(TurnedFace) = .empty;
    defer faces.deinit(testing.allocator);
    for (0..QUARTER_TURNS) |q| {
        errdefer std.debug.print("quarter turn {d}\n", .{q});
        const angle = @as(f64, @floatFromInt(q)) * PI / 2.0;
        const turn: Vec2 = .{ @cos(angle), @sin(angle) };
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        var discs: [QUARTER_TURNS + 1]Disc = undefined;
        _ = try o.addInput();
        var from_circle = case.island;
        for (discs[0..QUARTER_TURNS]) |*disc| {
            const c = vec.add2(FAMILY_CIRCLE_CENTRE, from_circle);
            for (fourArcs(c, FAMILY_ISLAND_RADIUS, island_ends)) |e| try o.addEdge(movedEdge(e, turn, FAMILY_SHIFT));
            disc.* = .{ .input = 0, .c = movedPoint(c, turn, FAMILY_SHIFT), .r = FAMILY_ISLAND_RADIUS };
            from_circle = vec.perp2(from_circle);
        }
        _ = try o.addInput();
        for (fourArcs(FAMILY_CIRCLE_CENTRE, FAMILY_CIRCLE_RADIUS, case.ends)) |e| try o.addEdge(movedEdge(e, turn, FAMILY_SHIFT));
        discs[QUARTER_TURNS] = .{ .input = 1, .c = movedPoint(FAMILY_CIRCLE_CENTRE, turn, FAMILY_SHIFT), .r = FAMILY_CIRCLE_RADIUS };
        try o.run();
        try expectPlanar(&o);
        try expectDiscWindings(&o, &discs);
        try turnedFaces(&o, if (q == 0) &first else &faces);
        if (q == 0) continue;
        try testing.expectEqual(first.items.len, faces.items.len);
        for (first.items, faces.items) |want, found| {
            try testing.expectEqual(want.windings, found.windings);
            try testing.expectApproxEqAbs(want.area, found.area, TURNED_AREA_CLOSE);
        }
    }
}

test "overlay: an arc from the least double east of its circle's highest point round to its east point is crossed as its three quarters are" {
    // The overlay fuzz target's find (the session on 9fb6daae, 2026-11-20, bk): the arc
    // about (0, 1.25) of radius 0.25 from (5e-324, 1.5), the least double east of the
    // circle's highest point, counter-clockwise to (0.25, 1.25): over the top, down the
    // west half, through the lowest point and up to the east point. `orient2d` of the
    // highest point against the first end is 0.25 times 5e-324, which rounds to nothing,
    // so the end read as on the highest point's radius and no cut was made there; the
    // piece from that end to the lowest point, the west half, was then told east by its
    // end's x. A ray at a height above the centre crossed the quarter the arc leaves out,
    // and one below it crossed the east half twice
    const a = Vec2{ HAIR, 1.5 };
    const b = Vec2{ 0.25, 1.25 };
    const arc: overlay.Arc = .{ .c = .{ 0, 1.25 }, .r = 0.25, .ccw = true };
    // From inside, above the centre: the east quarter there is not the arc's
    try testing.expect(!overlay.arcCrossings(a, b, arc, .{ -0.1, 1.3 }));
    // The fuzzer's point, inside and below the centre: the east half once
    try testing.expect(overlay.arcCrossings(a, b, arc, .{ 0.22589695592558076, 1.14407165014239 }));
    // From the west, outside: the west half alone above the centre, both halves below it
    try testing.expect(overlay.arcCrossings(a, b, arc, .{ -1, 1.3 }));
    try testing.expect(!overlay.arcCrossings(a, b, arc, .{ -1, 1.2 }));
}

test "overlay: an arc with an end the least double off an extreme of its circle, either side of it, is crossed as its turn has it in each quarter turn" {
    // The cases about the find above: the end the least double east or west of the
    // highest or lowest point (where the product with the radius underflows, ties or
    // survives) and, a quarter turn on, above or below the east or west point; the arc
    // leaving that end or arriving at it, either way round. Each ray's crossings are held
    // against a count by the angles of the circle's two points at its height
    for (HAIR_RADII) |r| for (0..QUARTER_TURNS) |q| for ([_]f64{ HAIR, -HAIR }) |hair| for ([_]bool{ true, false }) |leaves| for ([_]bool{ true, false }) |ccw| {
        errdefer std.debug.print("radius {d}, quarter turn {d}, the end {e} off the extreme, the arc {s} it, {s}\n", .{ r, q, hair, if (leaves) "leaving" else "arriving at", if (ccw) "counter-clockwise" else "clockwise" });
        var near = Vec2{ hair, r };
        var other = vec.scale2(HAIR_OTHER_END, r);
        for (0..q) |_| {
            near = vec.perp2(near);
            other = vec.perp2(other);
        }
        const a = if (leaves) near else other;
        const b = if (leaves) other else near;
        const arc: overlay.Arc = .{ .c = .{ 0, 0 }, .r = r, .ccw = ccw };
        for (HAIR_PROBE_HEIGHTS) |height| for (HAIR_PROBE_XS) |x| {
            const p = Vec2{ x * r, height * r };
            errdefer std.debug.print("the ray from ({d}, {d})\n", .{ p[0], p[1] });
            try testing.expectEqual(crossingsByAngle(a, b, arc, p), overlay.arcCrossings(a, b, arc, p));
        };
    };
}

/// Whether the ray from `p` to +x crosses the arc an odd number of times, by the angles
/// about the centre of the circle's two points at `p`'s height against the arc's turn: a
/// count of the test's own, for rays whose crossings are well clear of the arc's ends.
fn crossingsByAngle(a: Vec2, b: Vec2, arc: overlay.Arc, p: Vec2) bool {
    const start = std.math.atan2(a[1] - arc.c[1], a[0] - arc.c[0]);
    const end = std.math.atan2(b[1] - arc.c[1], b[0] - arc.c[0]);
    const sweep = @mod(if (arc.ccw) end - start else start - end, 2 * PI);
    const dy = p[1] - arc.c[1];
    const half = @sqrt(arc.r * arc.r - dy * dy);
    var odd = false;
    for ([_]f64{ -half, half }) |dx| {
        if (arc.c[0] + dx <= p[0]) continue;
        const at = std.math.atan2(dy, dx);
        const along = @mod(if (arc.ccw) at - start else start - at, 2 * PI);
        if (along < sweep) odd = !odd;
    }
    return odd;
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

/// The point of the stub family's circle, about the origin, at `angle`.
fn onStubCircle(angle: f64) Vec2 {
    return .{ STUB_RADIUS * @cos(angle), STUB_RADIUS * @sin(angle) };
}

test "overlay: an arc piece within the zone of its chord keeps its circle, cut off at either end of its arc, run either way" {
    // The nightly's find (2026-11-20, bm): the piece of an arc of radius 4.1 between its
    // end and a vertex 0.0012 rad along it was taken for its chord, a line 6e-4 rad off
    // the circle's tangent at the end. A circle of two arcs, one starting the stub short
    // of the point to +x of the centre or ending the stub past it, and a square with a
    // side along the radius through that point, which cuts the stub off: the circle's
    // four pieces are arcs, the square's six are lines
    for (STUB_ANGLES) |stub| {
        for ([_]bool{ false, true }) |at_end| {
            for ([_]bool{ true, false }) |ccw| {
                errdefer std.debug.print("a stub of {d} rad at the arc's {s}, the circle run {s}\n", .{ stub, if (at_end) "end" else "start", if (ccw) "counter-clockwise" else "clockwise" });
                var o = Overlay.init(testing.allocator, tol);
                defer o.deinit();
                _ = try o.addInput();
                const start: f64 = if (at_end) stub - PI else -stub;
                const ends = [_]Vec2{ onStubCircle(start), onStubCircle(start + PI) };
                for (ends, 0..) |from, k| {
                    const to = ends[1 - k];
                    try o.addEdge(if (ccw) .{ .a = from, .b = to, .arc = .{ .c = .{ 0, 0 }, .r = STUB_RADIUS, .ccw = true } } else .{ .a = to, .b = from, .arc = .{ .c = .{ 0, 0 }, .r = STUB_RADIUS, .ccw = false } });
                }
                _ = try o.addInput();
                const corners = [_]Vec2{ .{ STUB_RADIUS - 1, 0 }, .{ STUB_RADIUS + 1, 0 }, .{ STUB_RADIUS + 1, 1 }, .{ STUB_RADIUS - 1, 1 } };
                for (corners, 0..) |corner, k| try o.addEdge(.{ .a = corner, .b = corners[(k + 1) % corners.len] });
                try o.run();
                try expectPlanar(&o);
                var arcs: usize = 0;
                for (o.edges.items) |e| arcs += @intFromBool(e.arc != null);
                try testing.expectEqual(@as(usize, 10), o.edges.items.len);
                try testing.expectEqual(@as(usize, 4), arcs);
            }
        }
    }
}

test "overlay: an arc within the zone of the line between its ends is one edge with it, the line's; past the zone, the lens between them is a face" {
    for (STUB_ANGLES ++ [_]f64{STUB_PAST_CHORD}) |angle| {
        errdefer std.debug.print("an arc of {d} rad\n", .{angle});
        var o = Overlay.init(testing.allocator, tol);
        defer o.deinit();
        _ = try o.addInput();
        const a = onStubCircle(-angle);
        const b = onStubCircle(0);
        try o.addEdge(.{ .a = a, .b = b, .arc = .{ .c = .{ 0, 0 }, .r = STUB_RADIUS, .ccw = true } });
        try o.addEdge(.{ .a = b, .b = a });
        try o.run();
        try expectPlanar(&o);
        if (angle == STUB_PAST_CHORD) {
            try testing.expectEqual(@as(usize, 2), o.edges.items.len);
            try testing.expectEqual(@as(usize, 1), o.faces.items.len);
            continue;
        }
        try testing.expectEqual(@as(usize, 1), o.edges.items.len);
        try testing.expectEqual(@as(u32, 2), o.edges.items[0].contributions);
        try testing.expect(o.edges.items[0].arc == null);
        try testing.expectEqual(@as(usize, 0), o.faces.items.len);
    }
}

test "overlay: arcs bowing either side of the line between their ends, each within the zone of it, are one edge with it" {
    // Two lenses on one chord, an arc and the line each, the second's circle the first's
    // mirrored in the line: the arcs are farther apart than either is from the line, 1.6
    // zones at the most, and the line takes both, whichever of them is given first
    for (STUB_ANGLES) |angle| {
        for ([_]bool{ true, false }) |first_line_first| {
            for ([_]bool{ true, false }) |second_line_first| {
                errdefer std.debug.print("arcs of {d} rad, the line given first in the first lens: {}, in the second: {}\n", .{ angle, first_line_first, second_line_first });
                var o = Overlay.init(testing.allocator, tol);
                defer o.deinit();
                const a = onStubCircle(-angle);
                const b = onStubCircle(0);
                const mirrored = vec.add2(a, b);
                const lenses = [_][2]overlay.InputEdge{
                    .{ .{ .a = b, .b = a }, .{ .a = a, .b = b, .arc = .{ .c = .{ 0, 0 }, .r = STUB_RADIUS, .ccw = true } } },
                    .{ .{ .a = a, .b = b }, .{ .a = b, .b = a, .arc = .{ .c = mirrored, .r = STUB_RADIUS, .ccw = true } } },
                };
                for (lenses, [_]bool{ first_line_first, second_line_first }) |lens, line_first| {
                    _ = try o.addInput();
                    try o.addEdge(lens[if (line_first) 0 else 1]);
                    try o.addEdge(lens[if (line_first) 1 else 0]);
                }
                try o.run();
                try expectPlanar(&o);
                try testing.expectEqual(@as(usize, 1), o.edges.items.len);
                try testing.expectEqual(@as(u32, 4), o.edges.items[0].contributions);
                try testing.expect(o.edges.items[0].arc == null);
                try testing.expectEqual(@as(usize, 0), o.faces.items.len);
            }
        }
    }
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

test "overlay: circles missing each other by less than the zone touch at one vertex on both; by more, meet nowhere; by the zone, refused" {
    // A circle inside another, 1e-6 short of it at the top, where neither has an end. The
    // meeting test on the square-rooted distance with the zone's slack took them as
    // touching there and cut both at a point on neither (the radical line's foot); the
    // exact signs alone (D26) then said nested, which left a touch of two circles on the
    // grid to the rounding of their radii (the nightly, 2026-11-16). Coincidence first
    // (D16, Leo 2026-11-16): within the zone they touch, at one vertex midway between
    // them, within the zone of both
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try circle(&o, .{ 0, 0 }, 2);
    _ = try o.addInput();
    try circle(&o, .{ 0, 1 }, 1 - 1e-6);
    try o.run();
    try testing.expectEqual(@as(usize, 5), o.points.items.len);
    var at_top: usize = 0;
    for (o.points.items) |p| if (@abs(p[0]) < 0.5) {
        at_top += 1;
        try testing.expect(@abs(vec.length2(.{ p[0], p[1] }) - 2) <= tol.zone);
        try testing.expect(@abs(vec.distance2(.{ p[0], p[1] }, .{ 0, 1 }) - (1 - 1e-6)) <= tol.zone);
    };
    try testing.expectEqual(@as(usize, 1), at_top);
    try expectPlanar(&o);
    // Twice the zone short: nested, no vertex at the top
    var apart = Overlay.init(testing.allocator, tol);
    defer apart.deinit();
    _ = try apart.addInput();
    try circle(&apart, .{ 0, 0 }, 2);
    _ = try apart.addInput();
    try circle(&apart, .{ 0, 1 }, 1 - 2 * tol.zone);
    try apart.run();
    try testing.expectEqual(@as(usize, 4), apart.points.items.len);
    try expectPlanar(&apart);
    // The zone short to rounding: refused (D27)
    var at = Overlay.init(testing.allocator, tol);
    defer at.deinit();
    _ = try at.addInput();
    try circle(&at, .{ 0, 0 }, 2);
    _ = try at.addInput();
    try circle(&at, .{ 0, 1 }, 1 - tol.zone);
    try testing.expectError(error.AtTolerance, at.run());
}

test "overlay: a line tangent to an arc at their shared vertex, far out, meets it there only" {
    // The sheet rule's first run (2026-11-16, the plain chain run): a face of a union of
    // an offset sheet, turned 0.014 rad and moved 2e6 out, its line tangent to its arc at
    // their vertex. The touch's place along them moves by √(2·r·δ) for a rounding δ of the
    // line (5e-5 at 2e6), and the overlay cut both 2.26e-5 from the vertex, a point the
    // sheet does not have. Two curves that never part beyond the zone between their shared
    // vertex and a meeting meet once, at the vertex. The face as it came
    const a = Vec2{ 2000002.1381644835, -2999996.402944513 };
    const v = Vec2{ 2000001.9573746538, -2999996.972016436 };
    const b = Vec2{ 2000002.2701891724, -2999996.33661458 };
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try o.addEdge(.{ .a = a, .b = v });
    try o.addEdge(.{ .a = v, .b = b, .arc = .{ .c = .{ 2000004.2177559903, -2999997.690122426 }, .r = 2.3717082451262845, .ccw = false } });
    try o.addEdge(.{ .a = b, .b = a, .arc = .{ .c = .{ 2000003.9996, -2999999.9434328717 }, .r = 4, .ccw = true } });
    try o.run();
    try testing.expectEqual(@as(usize, 3), o.points.items.len);
    try testing.expectEqual(@as(usize, 3), o.edges.items.len);
    try expectPlanar(&o);
}

test "overlay: two arcs crossing at a shared vertex and again 5.8e-3 on, a lens 9.2e-6 thick between, are cut at both" {
    // The overlay target's find (2026-11-16, on 7a1bfb5e), the arrangement as it came:
    // taking a meeting the curves reach from a shared vertex within the zone for that
    // vertex's own left the second crossing uncut, and the map was not planar. Only a
    // meeting within rounding of the vertex's contact is it; the lens is merged as before
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 2, 2.75 }, .b = .{ 3.75, 0.75 } });
    try o.addEdge(.{ .a = .{ 3.75, 0.75 }, .b = .{ 0.75, 0.75 } });
    try o.addEdge(.{ .a = .{ 0.75, 0.75 }, .b = .{ 3.75, 5.5 }, .arc = .{ .c = .{ 4.625, 1.625 }, .r = 3.972562145517676, .ccw = true } });
    try o.addEdge(.{ .a = .{ 3.75, 5.5 }, .b = .{ 5, 2.5 } });
    try o.addEdge(.{ .a = .{ 5, 2.5 }, .b = .{ 4.75, 5.5 } });
    try o.addEdge(.{ .a = .{ 4.75, 5.5 }, .b = .{ 1, 1.75 }, .arc = .{ .c = .{ 1.9375, 4.5625 }, .r = 2.9646353064078554, .ccw = false } });
    try o.addEdge(.{ .a = .{ 1, 1.75 }, .b = .{ 2, 1.5 }, .arc = .{ .c = .{ 1.5625, 1.875 }, .r = 0.5762215285808054, .ccw = false } });
    try o.addEdge(.{ .a = .{ 2, 1.5 }, .b = .{ 2, 2.75 } });
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 7.5, 3.75 }, .b = .{ 3.5, 3.7500000000000004 }, .arc = .{ .c = .{ 5.5, 3.75 }, .r = 2, .ccw = true } });
    try o.addEdge(.{ .a = .{ 3.5, 3.7500000000000004 }, .b = .{ 7.5, 3.75 }, .arc = .{ .c = .{ 5.5, 3.75 }, .r = 2, .ccw = true } });
    _ = try o.addInput();
    try o.addEdge(.{ .a = .{ 3.75, 3.75 }, .b = .{ 0.75, 3.5 } });
    try o.addEdge(.{ .a = .{ 0.75, 3.5 }, .b = .{ 4.75, 2.5 } });
    try o.addEdge(.{ .a = .{ 4.75, 2.5 }, .b = .{ 0, 4.75 } });
    try o.addEdge(.{ .a = .{ 0, 4.75 }, .b = .{ 3.75, 3.75 } });
    try o.addEdge(.{ .a = .{ 4, 4.5 }, .b = .{ 6, 5.25 } });
    try o.addEdge(.{ .a = .{ 6, 5.25 }, .b = .{ 1.7500000000000002, 5.75 } });
    try o.addEdge(.{ .a = .{ 1.7500000000000002, 5.75 }, .b = .{ 2, 1.5 } });
    try o.addEdge(.{ .a = .{ 2, 1.5 }, .b = .{ 5, 1.75 }, .arc = .{ .c = .{ 3.625, 0.125 }, .r = 2.1286732957408003, .ccw = false } });
    try o.addEdge(.{ .a = .{ 5, 1.75 }, .b = .{ 2.75, 2.25 } });
    try o.addEdge(.{ .a = .{ 2.75, 2.25 }, .b = .{ 4, 4.5 } });
    try o.run();
    try expectPlanar(&o);
}

test "overlay: two circles on the grid touching inside, their radii square roots, meet at one vertex" {
    // The nightly's find (2026-11-16, run 43773180777, locus): radii √11.25 and √0.3125,
    // centres √7.8125 apart, their difference: touching inside at (3.6, 6.8). The radii
    // rounded, the exact sign said nested, no vertex was made there, and a sheet's face
    // between the arcs touched itself where it had none
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try circle(&o, .{ 3, 3.5 }, @sqrt(11.25));
    _ = try o.addInput();
    try circle(&o, .{ 3.5, 6.25 }, @sqrt(0.3125));
    try o.run();
    var at_touch: usize = 0;
    for (o.points.items) |p| at_touch += @intFromBool(vec.distance2(.{ p[0], p[1] }, .{ 3.6, 6.8 }) <= tol.zone);
    try testing.expectEqual(@as(usize, 1), at_touch);
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

test "overlay: a vertex the zone from coincident sides given either way round is on both or neither" {
    // A point measured against a line from the given edge's start is 1.00000000003e-5
    // from it one way round and 9.99999999997e-6 the other (the zone 1e-5): two triangles
    // sharing that side, each giving it its own way, had it cut on one and not the other,
    // the side kept whole beside its two pieces through the point, a sliver face one zone
    // wide between them. Measured from the side's lower end, alike either way
    const a = Vec2{ 0.5488586922664005, 2.483174774363169 };
    const b = Vec2{ 5.959108785343814, 4.628549545013987 };
    const p = Vec2{ 3.57730011599369, 3.684080446739448 };
    var o = Overlay.init(testing.allocator, tol);
    defer o.deinit();
    _ = try o.addInput();
    try polygon(&o, &.{ a, b, .{ 3, 6 } });
    _ = try o.addInput();
    try polygon(&o, &.{ b, a, .{ 3, 1 } });
    // A small triangle with a corner on the point, reaching away from the side (its
    // normal toward the point, (b − a) turned a quarter left), crossing nothing
    const along = vec.scale2(vec.sub2(b, a), 1 / vec.distance2(a, b));
    const away = Vec2{ -along[1], along[0] };
    try polygon(&o, &.{ p, vec.add2(p, vec.add2(vec.scale2(away, 0.5), vec.scale2(along, 0.1))), vec.add2(p, vec.add2(vec.scale2(away, 0.5), vec.scale2(along, -0.1))) });
    try o.run();
    try expectPlanar(&o);
    // The side is one edge from end to end or two through the point, never both
    var ends: [3]u32 = undefined;
    for ([_]Vec2{ a, b, p }, &ends) |q, *v| v.* = for (0..o.points.items.len) |i| {
        if (vec.distance2(o.point(@intCast(i)), q) <= tol.zone) break @intCast(i);
    } else unreachable;
    var between: [3]usize = @splat(0);
    for (o.edges.items) |e| for ([_][2]u32{ .{ ends[0], ends[1] }, .{ ends[0], ends[2] }, .{ ends[2], ends[1] } }, &between) |pair, *n| {
        n.* += @intFromBool((e.a == pair[0] and e.b == pair[1]) or (e.a == pair[1] and e.b == pair[0]));
    };
    errdefer std.debug.print("edges a–b {d}, a–p {d}, p–b {d}\n", .{ between[0], between[1], between[2] });
    try testing.expect(std.mem.eql(usize, &between, &.{ 1, 0, 0 }) or std.mem.eql(usize, &between, &.{ 0, 1, 1 }));
}
