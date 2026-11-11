const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const traverse = @import("../topology/traverse.zig");
const check = @import("../topology/check.zig");
const primitives = @import("primitives.zig");
const hull = @import("hull.zig");
const bbox = @import("../measure/bbox.zig");
const body_json = @import("../io/body_json.zig");
const mass = @import("../measure/mass.zig");
const trig = @import("../math/trig.zig");
const Vec3 = vec.Vec3;
const Vec2 = vec.Vec2;
const PI = std.math.pi;

const tol = Tolerance.fromZone(1e-5);

fn expectVec(expected: Vec3, actual: Vec3, t: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], t);
}

fn expectValid(body: *const Body) !void {
    var report = try check.run(testing.allocator, body, .geometric);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try f.format(&w);
        std.debug.print("checker: {s}\n", .{w.buffered()});
    }
    try testing.expect(report.ok());
}

fn expectCounts(body: *const Body, v: usize, e: usize, f: usize, l: usize) !void {
    const c = body.counts();
    try testing.expectEqual(v, c.vertices);
    try testing.expectEqual(e, c.edges);
    try testing.expectEqual(f, c.faces);
    try testing.expectEqual(l, c.loops);
}

/// Twice the signed area of a loop's chords in its face's UV: positive when counter-
/// clockwise. Through the pcurves where they exist (a face past the seam wraps), by
/// projection on a plane.
fn loopAreaUv(body: *const Body, l: types.LoopIndex) !f64 {
    const face = body.face(body.loop(l).face);
    const surface = body.geometry.surface(face.surface);
    var area: f64 = 0;
    var it = traverse.Coedges.init(body, l);
    while (try it.next()) |c| {
        const ce = body.coedge(c);
        const e = body.edge(ce.edge);
        // Three points along the coedge (a two-edge loop has no chord area)
        const ts = if (ce.same_sense) [3]f64{ e.t0, (e.t0 + e.t1) / 2, e.t1 } else [3]f64{ e.t1, (e.t0 + e.t1) / 2, e.t0 };
        var uv: [3]vec.Vec2 = undefined;
        for (ts, 0..) |t, k| {
            uv[k] = if (ce.pcurve.isNone())
                surface.project(body.geometry.curve(e.curve).eval(t), tol.approx, 50)
            else
                body.geometry.pcurve(ce.pcurve).eval(t);
        }
        area += uv[0][0] * uv[1][1] - uv[1][0] * uv[0][1];
        area += uv[1][0] * uv[2][1] - uv[2][0] * uv[1][1];
    }
    return area;
}

test "box: counts, the checker, the bounds, and every face counter-clockwise about its outward normal" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer b.deinit();
    try expectCounts(&b, 8, 12, 6, 6);
    try expectValid(&b);
    try testing.expectEqual(@as(usize, 6), b.geometry.planes.items.len);
    try testing.expectEqual(@as(usize, 12), b.geometry.lines.items.len);
    const box = try bbox.bodyBounds(&b);
    try expectVec(.{ 0, 0, 0 }, box.min, 1e-12);
    try expectVec(.{ 2, 3, 4 }, box.max, 1e-12);
    for (b.loops.items, 0..) |_, i| try testing.expect(try loopAreaUv(&b, types.LoopIndex.of(i)) > 0);
    // Every face's outward normal points away from the centre
    for (b.faces.items) |f| {
        const n = b.geometry.surface(f.surface).normal(0, 0);
        const o = b.geometry.planes.items[f.surface.index].frame.origin;
        try testing.expect(vec.dot(n, vec.sub(o, .{ 1, 1.5, 2 })) > 0);
    }
    var c = try primitives.box(testing.allocator, tol, 2, 2, 2, true, &diag);
    defer c.deinit();
    const cbox = try bbox.bodyBounds(&c);
    try expectVec(.{ -1, -1, -1 }, cbox.min, 1e-12);
    try expectVec(.{ 1, 1, 1 }, cbox.max, 1e-12);
    try testing.expectError(error.InvalidInput, primitives.box(testing.allocator, tol, 0, 1, 1, false, &diag));
    try testing.expectError(error.InvalidInput, primitives.box(testing.allocator, tol, 1, std.math.nan(f64), 1, false, &diag));
}

test "cylinder: two half-faces with seams and pcurves, two caps, the checker and the bounds" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.cylinder(testing.allocator, tol, 2, 5, true, &diag);
    defer b.deinit();
    try expectCounts(&b, 4, 6, 4, 4);
    try expectValid(&b);
    try testing.expectEqual(@as(usize, 1), b.geometry.cylinders.items.len);
    try testing.expectEqual(@as(usize, 2), b.geometry.circles.items.len);
    const box = try bbox.bodyBounds(&b);
    try expectVec(.{ -2, -2, -2.5 }, box.min, 1e-12);
    try expectVec(.{ 2, 2, 2.5 }, box.max, 1e-12);
    var seams: usize = 0;
    var g1: usize = 0;
    for (b.edges.items) |e| {
        seams += @intFromBool(e.flags.seam);
        g1 += @intFromBool(e.regularity == .g1);
    }
    try testing.expectEqual(@as(usize, 2), seams);
    try testing.expectEqual(@as(usize, 2), g1);
    // Every loop counter-clockwise in its face's UV; the side faces have pcurves, the caps none
    for (b.loops.items, 0..) |_, i| try testing.expect(try loopAreaUv(&b, types.LoopIndex.of(i)) > 0);
    for (b.coedges.items) |c| {
        const on_side = b.face(b.loop(c.loop).face).surface.kind == .cylinder;
        try testing.expectEqual(on_side, !c.pcurve.isNone());
    }
}

test "sphere: two hemispheres, one meridian circle in two halves, a degenerate edge per pole per face" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer b.deinit();
    try expectCounts(&b, 2, 6, 2, 2);
    try expectValid(&b);
    try testing.expectEqual(@as(usize, 1), b.geometry.spheres.items.len);
    try testing.expectEqual(@as(usize, 3), b.geometry.circles.items.len);
    const box = try bbox.bodyBounds(&b);
    try expectVec(.{ -3, -3, -3 }, box.min, 1e-12);
    try expectVec(.{ 3, 3, 3 }, box.max, 1e-12);
    var degenerate: usize = 0;
    var seams: usize = 0;
    for (b.edges.items) |e| {
        degenerate += @intFromBool(e.flags.degenerate);
        seams += @intFromBool(e.flags.seam);
        if (e.flags.degenerate) try testing.expectEqual(e.start, e.end);
    }
    try testing.expectEqual(@as(usize, 4), degenerate);
    try testing.expectEqual(@as(usize, 2), seams);
    for (b.loops.items, 0..) |_, i| try testing.expect(try loopAreaUv(&b, types.LoopIndex.of(i)) > 0);
    for (b.coedges.items) |c| try testing.expect(!c.pcurve.isNone());
    try testing.expectError(error.InvalidInput, primitives.sphere(testing.allocator, tol, 0, &diag));
}

test "cone: two half-faces and caps; an apex is a degenerate edge per face; equal radii are the cylinder" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var frustum = try primitives.cone(testing.allocator, tol, 2, 1, 3, false, &diag);
    defer frustum.deinit();
    try expectCounts(&frustum, 4, 6, 4, 4);
    try expectValid(&frustum);
    try testing.expectEqual(@as(usize, 1), frustum.geometry.cones.items.len);
    try testing.expectEqual(@as(usize, 2), frustum.geometry.circles.items.len);
    const fbox = try bbox.bodyBounds(&frustum);
    try expectVec(.{ -2, -2, 0 }, fbox.min, 1e-12);
    try expectVec(.{ 2, 2, 3 }, fbox.max, 1e-12);
    for (frustum.loops.items, 0..) |_, i| try testing.expect(try loopAreaUv(&frustum, types.LoopIndex.of(i)) > 0);
    // The side's outward normal leans up and out for a cone narrowing upward
    const n = frustum.geometry.surface(frustum.faces.items[0].surface).normal(0, 0);
    try testing.expect(n[0] > 0 and n[2] > 0);

    var apex_up = try primitives.cone(testing.allocator, tol, 2, 0, 3, true, &diag);
    defer apex_up.deinit();
    try expectCounts(&apex_up, 3, 6, 3, 3);
    try expectValid(&apex_up);
    const abox = try bbox.bodyBounds(&apex_up);
    try expectVec(.{ -2, -2, -1.5 }, abox.min, 1e-12);
    try expectVec(.{ 2, 2, 1.5 }, abox.max, 1e-12);
    var degenerate: usize = 0;
    for (apex_up.edges.items) |e| degenerate += @intFromBool(e.flags.degenerate);
    try testing.expectEqual(@as(usize, 2), degenerate);
    for (apex_up.loops.items, 0..) |_, i| try testing.expect(try loopAreaUv(&apex_up, types.LoopIndex.of(i)) > 0);

    var apex_down = try primitives.cone(testing.allocator, tol, 0, 2, 3, false, &diag);
    defer apex_down.deinit();
    try expectCounts(&apex_down, 3, 6, 3, 3);
    try expectValid(&apex_down);
    const dbox = try bbox.bodyBounds(&apex_down);
    try expectVec(.{ -2, -2, 0 }, dbox.min, 1e-12);
    try expectVec(.{ 2, 2, 3 }, dbox.max, 1e-12);

    var same = try primitives.cone(testing.allocator, tol, 2, 2, 3, false, &diag);
    defer same.deinit();
    try testing.expectEqual(@as(usize, 1), same.geometry.cylinders.items.len);
    try testing.expectError(error.InvalidInput, primitives.cone(testing.allocator, tol, 0, 0, 3, false, &diag));
    try testing.expectError(error.InvalidInput, primitives.cone(testing.allocator, tol, -1, 2, 3, false, &diag));
    try testing.expectError(error.InvalidInput, primitives.cone(testing.allocator, tol, 1, 2, 0, false, &diag));
}

test "torus: four faces over the two periods, eight arcs, the checker, the bounds" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.torus(testing.allocator, tol, 5, 2, &diag);
    defer b.deinit();
    try expectCounts(&b, 4, 8, 4, 4);
    try expectValid(&b);
    try testing.expectEqual(@as(usize, 1), b.geometry.tori.items.len);
    try testing.expectEqual(@as(usize, 4), b.geometry.circles.items.len);
    const box = try bbox.bodyBounds(&b);
    try expectVec(.{ -7, -7, -2 }, box.min, 1e-12);
    try expectVec(.{ 7, 7, 2 }, box.max, 1e-12);
    for (b.loops.items, 0..) |_, i| try testing.expect(try loopAreaUv(&b, types.LoopIndex.of(i)) > 0);
    for (b.coedges.items) |c| try testing.expect(!c.pcurve.isNone());
    // Every edge has its two coedges, opposite
    for (b.edges.items) |e| {
        const partner = b.coedge(e.coedge).partner;
        try testing.expect(partner != .none);
        try testing.expect(b.coedge(partner).same_sense != b.coedge(e.coedge).same_sense);
    }
    try testing.expectError(error.InvalidInput, primitives.torus(testing.allocator, tol, 2, 2, &diag));
    try testing.expectError(error.InvalidInput, primitives.torus(testing.allocator, tol, 2, -1, &diag));
}

test "sketches: a square, an exact circle, a polygon turned around, polygons with a hole" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 4, 2, true, &diag);
    defer sq.deinit();
    try testing.expectEqual(@import("../topology/body.zig").Kind.sheet, sq.kind);
    try expectCounts(&sq, 4, 4, 1, 1);
    try expectValid(&sq);
    const sbox = try bbox.bodyBounds(&sq);
    try expectVec(.{ -2, -1, 0 }, sbox.min, 1e-12);
    try expectVec(.{ 2, 1, 0 }, sbox.max, 1e-12);

    var ci = try primitives.circle(testing.allocator, tol, 3, &diag);
    defer ci.deinit();
    try expectCounts(&ci, 2, 2, 1, 1);
    try expectValid(&ci);
    const cbox = try bbox.bodyBounds(&ci);
    try expectVec(.{ -3, -3, 0 }, cbox.min, 1e-12);
    try expectVec(.{ 3, 3, 0 }, cbox.max, 1e-12);
    try testing.expect(try loopAreaUv(&ci, types.LoopIndex.of(0)) > 0);

    // A clockwise triangle is turned around
    const cw = [_]vec.Vec2{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 } };
    var tri = try primitives.polygon(testing.allocator, tol, &cw, &diag);
    defer tri.deinit();
    try expectValid(&tri);
    try testing.expect(try loopAreaUv(&tri, types.LoopIndex.of(0)) > 0);

    // A square with a square hole: the hole clockwise
    const outer = [_]vec.Vec2{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_]vec.Vec2{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    var holed = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer holed.deinit();
    try expectCounts(&holed, 8, 8, 1, 2);
    try expectValid(&holed);
    const face = types.FaceIndex.of(0);
    const first = holed.face(face).first_loop;
    const second = holed.loop(first).next_in_face;
    try testing.expect(try loopAreaUv(&holed, first) > 0);
    try testing.expect(try loopAreaUv(&holed, second) < 0);
    // A point repeated, and the first again at the end, are one corner each: the same
    // body as the clean outline
    const clean = [_]vec.Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 3 } };
    const written_closed = [_]vec.Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 0 + 1e-7 }, .{ 4, 3 }, .{ 0, 0 } };
    var a = try primitives.polygon(testing.allocator, tol, &clean, &diag);
    defer a.deinit();
    var b = try primitives.polygon(testing.allocator, tol, &written_closed, &diag);
    defer b.deinit();
    try testing.expectEqual(try body_json.hash(testing.allocator, &a), try body_json.hash(testing.allocator, &b));
    // Refusals
    try testing.expectError(error.InvalidInput, primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 1, 0 } }, &diag));
    try testing.expectError(error.Degenerate, primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 0 }, .{ 0, 0 } }, &diag));
    try testing.expectError(error.InvalidInput, primitives.circle(testing.allocator, tol, -1, &diag));
}

test "polyhedron: a pyramid, the checker, and refusals of bad indices and open shells" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const pts = [_]Vec3{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 } };
    const tris = [_][3]u32{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 } };
    var p = try primitives.polyhedron(testing.allocator, tol, &pts, &tris, &diag);
    defer p.deinit();
    try expectCounts(&p, 5, 9, 6, 6);
    try expectValid(&p);
    // The two base triangles share one plane record
    try testing.expectEqual(@as(usize, 5), p.geometry.planes.items.len);
    for (p.loops.items, 0..) |_, i| try testing.expect(try loopAreaUv(&p, types.LoopIndex.of(i)) > 0);
    const bad = [_][3]u32{.{ 0, 1, 9 }};
    try testing.expectError(error.InvalidInput, primitives.polyhedron(testing.allocator, tol, &pts, &bad, &diag));
    try testing.expectError(error.NotValid, primitives.polyhedron(testing.allocator, tol, &pts, tris[0..3], &diag));
    try testing.expect(diag.failures() >= 2);
}

test "hull: a cube's corners with interior points give the cube; two cubes give their hull" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var pts = std.ArrayList(Vec3).empty;
    defer pts.deinit(testing.allocator);
    for ([_]f64{ 0, 10 }) |x| for ([_]f64{ 0, 10 }) |y| for ([_]f64{ 0, 10 }) |z| try pts.append(testing.allocator, .{ x, y, z });
    try pts.append(testing.allocator, .{ 5, 5, 5 });
    try pts.append(testing.allocator, .{ 2, 3, 4 });
    var h = try hull.hull(testing.allocator, tol, pts.items, &diag);
    defer h.deinit();
    try expectValid(&h);
    try testing.expectEqual(@as(usize, 8), h.counts().vertices);
    try testing.expectEqual(@as(usize, 12), h.counts().faces);
    try testing.expectEqual(@as(usize, 6), h.geometry.planes.items.len);
    const box = try bbox.bodyBounds(&h);
    try expectVec(.{ 0, 0, 0 }, box.min, 1e-12);
    try expectVec(.{ 10, 10, 10 }, box.max, 1e-12);
    // Two cubes 20 apart: a 30 × 10 × 10 box
    for (0..8) |i| try pts.append(testing.allocator, vec.add(pts.items[i], .{ 20, 0, 0 }));
    var two = try hull.hull(testing.allocator, tol, pts.items, &diag);
    defer two.deinit();
    try expectValid(&two);
    try testing.expectEqual(@as(usize, 8), two.counts().vertices);
    const tbox = try bbox.bodyBounds(&two);
    try expectVec(.{ 30, 10, 10 }, tbox.max, 1e-12);
    // Coplanar or too few points
    try testing.expectError(error.Degenerate, hull.hull(testing.allocator, tol, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 } }, &diag));
    try testing.expectError(error.Degenerate, hull.hull(testing.allocator, tol, pts.items[0..3], &diag));
}

fn areaOf(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).area;
}

test "outlines: a rounded rectangle, a stadium, a circle as two arcs and a major arc, exact; refusals" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // A 4 by 2 rectangle with its corners rounded to a half, counter-clockwise from the
    // bottom edge: area 8 − (4 − π) r²
    const Arc = primitives.OutlineArc;
    const rounded = [_]primitives.OutlineEdge{
        .{ .a = .{ 0.5, 0 }, .b = .{ 3.5, 0 } },
        .{ .a = .{ 3.5, 0 }, .b = .{ 4, 0.5 }, .arc = Arc{ .c = .{ 3.5, 0.5 }, .r = 0.5, .ccw = true } },
        .{ .a = .{ 4, 0.5 }, .b = .{ 4, 1.5 } },
        .{ .a = .{ 4, 1.5 }, .b = .{ 3.5, 2 }, .arc = Arc{ .c = .{ 3.5, 1.5 }, .r = 0.5, .ccw = true } },
        .{ .a = .{ 3.5, 2 }, .b = .{ 0.5, 2 } },
        .{ .a = .{ 0.5, 2 }, .b = .{ 0, 1.5 }, .arc = Arc{ .c = .{ 0.5, 1.5 }, .r = 0.5, .ccw = true } },
        .{ .a = .{ 0, 1.5 }, .b = .{ 0, 0.5 } },
        .{ .a = .{ 0, 0.5 }, .b = .{ 0.5, 0 }, .arc = Arc{ .c = .{ 0.5, 0.5 }, .r = 0.5, .ccw = true } },
    };
    var rect = try primitives.outlines(testing.allocator, tol, &.{&rounded}, &diag);
    defer rect.deinit();
    try expectCounts(&rect, 8, 8, 1, 1);
    try expectValid(&rect);
    try testing.expectApproxEqRel(8 - (4 - PI) * 0.25, try areaOf(&rect), 1e-12);
    const box = try bbox.bodyBounds(&rect);
    try expectVec(.{ 0, 0, 0 }, box.min, 1e-12);
    try expectVec(.{ 4, 2, 0 }, box.max, 1e-12);
    // A stadium: a 4 by 2 rectangle with half-discs at its ends, given clockwise (the
    // even-odd rule fills it all the same): area 8 + π
    const stadium = [_]primitives.OutlineEdge{
        .{ .a = .{ 0, 0 }, .b = .{ 0, 2 }, .arc = Arc{ .c = .{ 0, 1 }, .r = 1, .ccw = false } },
        .{ .a = .{ 0, 2 }, .b = .{ 4, 2 } },
        .{ .a = .{ 4, 2 }, .b = .{ 4, 0 }, .arc = Arc{ .c = .{ 4, 1 }, .r = 1, .ccw = false } },
        .{ .a = .{ 4, 0 }, .b = .{ 0, 0 } },
    };
    var slot = try primitives.outlines(testing.allocator, tol, &.{&stadium}, &diag);
    defer slot.deinit();
    try expectCounts(&slot, 4, 4, 1, 1);
    try expectValid(&slot);
    try testing.expectApproxEqRel(8 + PI, try areaOf(&slot), 1e-12);
    // A full circle as two arcs: the circle primitive's area and counts
    const halves = [_]primitives.OutlineEdge{
        .{ .a = .{ 3, 0 }, .b = .{ -3, 0 }, .arc = Arc{ .c = .{ 0, 0 }, .r = 3, .ccw = true } },
        .{ .a = .{ -3, 0 }, .b = .{ 3, 0 }, .arc = Arc{ .c = .{ 0, 0 }, .r = 3, .ccw = true } },
    };
    var disc = try primitives.outlines(testing.allocator, tol, &.{&halves}, &diag);
    defer disc.deinit();
    try expectCounts(&disc, 2, 2, 1, 1);
    try expectValid(&disc);
    try testing.expectApproxEqRel(9 * PI, try areaOf(&disc), 1e-12);
    // A chord and the arc about (1, −0.5) of radius √1.25 between its ends: the minor arc
    // (counter-clockwise, above the chord) is the segment, the major arc (clockwise, round
    // below) is the disc less that segment: ½ r² (θ − sin θ), θ the chord's angle
    const r2 = 1.25;
    const theta = 2 * trig.atan2(1.0, 0.5);
    const segment = 0.5 * r2 * (theta - @sin(theta));
    const minor = [_]primitives.OutlineEdge{
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 } },
        .{ .a = .{ 2, 0 }, .b = .{ 0, 0 }, .arc = Arc{ .c = .{ 1, -0.5 }, .r = @sqrt(r2), .ccw = true } },
    };
    var bite = try primitives.outlines(testing.allocator, tol, &.{&minor}, &diag);
    defer bite.deinit();
    try expectValid(&bite);
    try testing.expectApproxEqRel(segment, try areaOf(&bite), 1e-9);
    const major = [_]primitives.OutlineEdge{
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 } },
        .{ .a = .{ 2, 0 }, .b = .{ 0, 0 }, .arc = Arc{ .c = .{ 1, -0.5 }, .r = @sqrt(r2), .ccw = false } },
    };
    var bitten = try primitives.outlines(testing.allocator, tol, &.{&major}, &diag);
    defer bitten.deinit();
    try expectValid(&bitten);
    try testing.expectApproxEqRel(PI * r2 - segment, try areaOf(&bitten), 1e-9);
    // A hole: the stadium inside a big square
    const frame = [_]primitives.OutlineEdge{
        .{ .a = .{ -5, -5 }, .b = .{ 9, -5 } },
        .{ .a = .{ 9, -5 }, .b = .{ 9, 7 } },
        .{ .a = .{ 9, 7 }, .b = .{ -5, 7 } },
        .{ .a = .{ -5, 7 }, .b = .{ -5, -5 } },
    };
    var framed = try primitives.outlines(testing.allocator, tol, &.{ &frame, &stadium }, &diag);
    defer framed.deinit();
    try expectCounts(&framed, 8, 8, 1, 2);
    try expectValid(&framed);
    try testing.expectApproxEqRel(14 * 12 - (8 + PI), try areaOf(&framed), 1e-12);
    // Refusals: an edge ending off the next one's start, an arc's end off its circle, a
    // radius that is not positive, outlines of no area
    const unchained = [_]primitives.OutlineEdge{ .{ .a = .{ 0, 0 }, .b = .{ 1, 0 } }, .{ .a = .{ 2, 0 }, .b = .{ 0, 1 } }, .{ .a = .{ 0, 1 }, .b = .{ 0, 0 } } };
    try testing.expectError(error.InvalidInput, primitives.outlines(testing.allocator, tol, &.{&unchained}, &diag));
    const off_circle = [_]primitives.OutlineEdge{ .{ .a = .{ 0, 0 }, .b = .{ 2, 0 } }, .{ .a = .{ 2, 0 }, .b = .{ 0, 0 }, .arc = Arc{ .c = .{ 1, 0 }, .r = 0.9, .ccw = true } } };
    try testing.expectError(error.InvalidInput, primitives.outlines(testing.allocator, tol, &.{&off_circle}, &diag));
    const no_radius = [_]primitives.OutlineEdge{ .{ .a = .{ 0, 0 }, .b = .{ 2, 0 } }, .{ .a = .{ 2, 0 }, .b = .{ 0, 0 }, .arc = Arc{ .c = .{ 1, 0 }, .r = 0, .ccw = true } } };
    try testing.expectError(error.InvalidInput, primitives.outlines(testing.allocator, tol, &.{&no_radius}, &diag));
    const flat = [_]primitives.OutlineEdge{ .{ .a = .{ 0, 0 }, .b = .{ 2, 0 } }, .{ .a = .{ 2, 0 }, .b = .{ 0, 0 } } };
    try testing.expectError(error.Degenerate, primitives.outlines(testing.allocator, tol, &.{&flat}, &diag));
    try testing.expectError(error.InvalidInput, primitives.outlines(testing.allocator, tol, &.{}, &diag));
}
