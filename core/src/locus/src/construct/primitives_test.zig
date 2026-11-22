const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics_mod = @import("../diagnostics.zig");
const Diagnostics = diagnostics_mod.Diagnostics;
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const traverse = @import("../topology/traverse.zig");
const check = @import("../topology/check.zig");
const primitives = @import("primitives.zig");
const hull = @import("hull.zig");
const bbox = @import("../topology/bbox.zig");
const body_json = @import("../io/body_json.zig");
const mass = @import("../measure/mass.zig");
const trig = @import("../math/trig.zig");
const Vec3 = vec.Vec3;
const Vec2 = vec.Vec2;
const PI = std.math.pi;

const tol = Tolerance.fromZone(1e-5);
/// A tetrahedron on the unit right triangle with its apex `LOW_RISES` zones over (0.3,
/// 0.3): under twice the zone (the intersection tolerance) its sides lie in its base's
/// plane, faces on each other; past it, near the base but apart. Not the zone or twice it
/// themselves, where rounding has it either way.
const LOW_BASE = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
const LOW_APEX: [2]f64 = .{ 0.3, 0.3 };
const LOW_TRIANGLES = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 } };
const LOW_THIN = [_]f64{ 1.25, 1.5, 1.9 };
const LOW_APART = [_]f64{ 2.5, 3, 5 };
/// How far along each axis a second unit cube is nudged in the tests of a hull of two cubes
/// nearly one: their corners 1.73 and 2.6 zones apart, past the zone the hull welds at,
/// about the intersection tolerance.
const WELD_NUDGES = [_]f64{ 1e-5, 1.5e-5 };
/// Lunes of two circles through one vertex, the second's tangent there tilted toward the
/// first by the angle (degrees, under the angular tolerance): batch E's probe's (cs, radii
/// 10 and 2 at 0.2°, 1.015 of the least area of no sliver), and neighbours on either side
/// of that least area.
const LUNE_FIND_RADII = [2]f64{ 10, 2 };
const LUNE_FIND_TILT = 0.2;
const LUNE_RADII = [_][2]f64{ .{ 10, 2 }, .{ 8, 2 }, .{ 10, 3 } };
const LUNE_TILTS = [_]f64{ 0.15, 0.18, 0.2, 0.22, 0.3 };

/// The disc and the round hole near its rim of the hole rule's tests (the audit of
/// 2026-11-22): the hole's centre at `RIM_HOLE_AT` from the disc's, on rays every
/// `RIM_HOLE_STEP` degrees from `RIM_HOLE_FIRST` (between the points a half circle sampled
/// four times is a polygon of: 22.5°, where the octagon is 0.924 of the radius).
const RIM_DISC: f64 = 10;
const RIM_HOLE: f64 = 0.2;
const RIM_HOLE_AT: f64 = 9.5;
const RIM_HOLE_OUT: f64 = 10.5;
const RIM_HOLE_FIRST: f64 = 22.5;
const RIM_HOLE_STEP: f64 = 11.25;
const RIM_HOLE_RAYS: usize = 32;
/// C rings for the winding rule's tests: the outer arc's sweep in degrees about −x, the
/// inner radius as a share of the outer (`C_OUTER`), and how many edges the inner arc is in
/// (a tooth touching it at each cut).
const C_OUTER: f64 = 10;
const C_SWEEPS = [_]f64{ 90, 180, 270, 340 };
const C_SHARES = [_]f64{ 0.85, 0.9, 0.93, 0.97 };
const C_CUTS = [_]usize{ 1, 2, 3, 5 };
/// How far back from the inner arc a tooth's base is, and half its width.
const C_TOOTH = [2]f64{ 1, 0.3 };
const MAX_C_TEETH: usize = 4;

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
    // The cube's faces, one for each plane its triangles were given
    try testing.expectEqual(@as(usize, 8), h.counts().vertices);
    try testing.expectEqual(@as(usize, 6), h.counts().faces);
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

test "hull: faces by the interner's plane records, points by its point records: a flat tetrahedron, a cube with points within the zone of it" {
    // Item 4 of the research review (Leo, 2026-11-14: decide once). A tetrahedron whose
    // opposite edges are 1.5e-5 apart: its upper faces, 1.5e-5 apart at their far corners,
    // were one face by the hull's own coplanarity test and two plane records by the
    // interner's, and the fans did not sew
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var flat = try hull.hull(testing.allocator, tol, &.{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 1.5e-5 }, .{ 0, 1, 1.5e-5 } }, &diag);
    defer flat.deinit();
    try expectValid(&flat);
    try testing.expectEqual(@as(usize, 4), flat.counts().faces);
    try testing.expectApproxEqAbs(@as(f64, 1e-5), (try mass.mass(&flat, .{}, &diag)).volume, 1e-15);
    // A cube's corners, a point 1e-7 over its top's middle, another a corner's 1e-7 off, and
    // its edges' middles: within the zone, the top's plane and the corner's point; on its
    // edges, the lines of their neighbours. The cube, its eight corners and six faces
    var pts = std.ArrayList(Vec3).empty;
    defer pts.deinit(testing.allocator);
    for ([_]f64{ 0, 10 }) |x| for ([_]f64{ 0, 10 }) |y| for ([_]f64{ 0, 10 }) |z| try pts.append(testing.allocator, .{ x, y, z });
    try pts.append(testing.allocator, .{ 5, 5, 10 + 1e-7 });
    try pts.append(testing.allocator, .{ 10 + 1e-7, 10, 10 });
    for ([_]Vec3{ .{ 5, 0, 0 }, .{ 10, 5, 0 }, .{ 0, 0, 5 }, .{ 10, 10, 5 } }) |p| try pts.append(testing.allocator, p);
    var cube = try hull.hull(testing.allocator, tol, pts.items, &diag);
    defer cube.deinit();
    try expectValid(&cube);
    try testing.expectEqual(@as(usize, 8), cube.counts().vertices);
    try testing.expectEqual(@as(usize, 12), cube.counts().edges);
    try testing.expectEqual(@as(usize, 6), cube.counts().faces);
    try testing.expectApproxEqAbs(@as(f64, 1000), (try mass.mass(&cube, .{}, &diag)).volume, 1e-4);
    // All within the zone of one plane: no solid
    try testing.expectError(error.Degenerate, hull.hull(testing.allocator, tol, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 5e-6 } }, &diag));
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
    // The right arc crosses its circle's seam (the point to +x of the centre), so it is
    // two edges meeting there: no edge's range leaves its circle's period (D7)
    try expectCounts(&slot, 5, 5, 1, 1);
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
    try expectCounts(&framed, 9, 9, 1, 2);
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

test "polyhedron: two tetrahedra meeting at a vertex, a face of each on one plane facing opposite ways" {
    // The plane record is shared by coplanar triangles; the one facing against its
    // normal took its sense from it and its loop ran backwards (the checker's
    // loop_winding), found when the shell grades were tested
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const pts = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ -1, 0, 0 }, .{ 0, -1, 0 }, .{ 0, 0, -1 } };
    const tris = [_][3]u32{
        .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 0, 3, 2 }, .{ 1, 2, 3 },
        .{ 0, 4, 5 }, .{ 0, 6, 4 }, .{ 0, 5, 6 }, .{ 4, 6, 5 },
    };
    var pair = try primitives.polyhedron(testing.allocator, tol, &pts, &tris, &diag);
    defer pair.deinit();
    var report = try check.run(testing.allocator, &pair, .geometric);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 6.0), (try mass.mass(&pair, .{}, &diag)).volume, 1e-12);
}

/// The low tetrahedron's corners with its apex `rise` zones up, turned `quarter` quarter
/// turns about z and mirrored in x when `mirrored`.
fn lowPoints(rise: f64, quarter: usize, mirrored: bool) [4]Vec3 {
    var out: [4]Vec3 = undefined;
    for (LOW_BASE ++ [_]Vec3{.{ LOW_APEX[0], LOW_APEX[1], rise * tol.zone }}, 0..) |p, i| {
        var q = p;
        for (0..quarter) |_| {
            const turned: Vec3 = .{ -q[1], q[0], q[2] };
            q = turned;
        }
        out[i] = if (mirrored) .{ -q[0], q[1], q[2] } else q;
    }
    return out;
}

/// The low tetrahedron's triangles, wound the other way when mirrored.
fn lowTriangles(mirrored: bool) [LOW_TRIANGLES.len][3]u32 {
    var out = LOW_TRIANGLES;
    if (mirrored) for (&out) |*t| std.mem.swap(u32, &t[1], &t[2]);
    return out;
}

test "polyhedron and hull: a tetrahedron lower than the intersection tolerance is refused below the feature size, higher made" {
    // Its sides lie in its base's plane within the tolerance: faces on each other, which a
    // boolean refuses of its result and of its operands (find bd's tetrahedron, made by the
    // constructors directly)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        const triangles = lowTriangles(mirrored);
        for (LOW_THIN) |rise| {
            errdefer std.debug.print("rise {d} zones, quarter turns {d}, mirrored {}\n", .{ rise, quarter, mirrored });
            const points = lowPoints(rise, quarter, mirrored);
            try testing.expectError(error.Degenerate, primitives.polyhedron(testing.allocator, tol, &points, &triangles, &diag));
            try testing.expectEqual(.below_feature_size, diag.first().?.code);
            diag.deinit();
            diag = Diagnostics.init(testing.allocator);
            try testing.expectError(error.Degenerate, hull.hull(testing.allocator, tol, &points, &diag));
            try testing.expectEqual(.below_feature_size, diag.first().?.code);
            diag.deinit();
            diag = Diagnostics.init(testing.allocator);
        }
        for (LOW_APART) |rise| {
            errdefer std.debug.print("rise {d} zones, quarter turns {d}, mirrored {}: {any}\n", .{ rise, quarter, mirrored, diag.first() });
            const points = lowPoints(rise, quarter, mirrored);
            var p = try primitives.polyhedron(testing.allocator, tol, &points, &triangles, &diag);
            defer p.deinit();
            try expectValid(&p);
            var h = try hull.hull(testing.allocator, tol, &points, &diag);
            defer h.deinit();
            try expectValid(&h);
        }
    };
}

test "hull: two cubes nudged apart by less than the intersection tolerance give a hull or a refusal of the input's size, never an invalid body" {
    // The hull welds its points at the zone (the interner's one decision of sameness): two
    // corners 1.73 zones apart are two points, and the hull's edge between them is shorter
    // than the checker allows; a body the input's sizes made, refused as such
    // (`Degenerate`), where it read as the kernel's fault (`NotValid`)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (WELD_NUDGES) |d| {
        var pts: [16]Vec3 = undefined;
        var n: usize = 0;
        for ([_]f64{ 0, 1 }) |x| for ([_]f64{ 0, 1 }) |y| for ([_]f64{ 0, 1 }) |z| {
            pts[n] = .{ x, y, z };
            pts[n + 8] = .{ x + d, y + d, z + d };
            n += 1;
        };
        errdefer std.debug.print("nudge {e}: {any}\n", .{ d, diag.first() });
        if (hull.hull(testing.allocator, tol, &pts, &diag)) |h| {
            var made = h;
            defer made.deinit();
            try expectValid(&made);
        } else |e| try testing.expectEqual(error.Degenerate, e);
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
    }
}

/// The lune inside the circle of radius `radii[0]` and outside the circle of `radii[1]`,
/// both through the origin, the first's centre on +y, the second's tangent there tilted
/// `degrees` toward it; every point turned `turn` quarter turns about the origin, mirrored
/// in x first or not (exact for the turns).
fn tiltedLune(radii: [2]f64, degrees: f64, turn: usize, mirrored: bool, diag: *Diagnostics) !Body {
    const at = struct {
        fn place(p: Vec2, quarters: usize, mirror: bool) Vec2 {
            var q: Vec2 = if (mirror) .{ -p[0], p[1] } else p;
            for (0..quarters) |_| {
                const turned: Vec2 = .{ -q[1], q[0] };
                q = turned;
            }
            return q;
        }
    };
    const angle = -degrees * PI / 180;
    const a_centre: Vec2 = .{ 0, radii[0] };
    const b_centre = vec.scale2(.{ -@sin(angle), @cos(angle) }, radii[1]);
    // The circles' second meeting: the origin reflected in the line of the centres
    const along = vec.sub2(b_centre, a_centre);
    const t = -vec.dot2(a_centre, along) / vec.dot2(along, along);
    const far = vec.scale2(vec.add2(a_centre, vec.scale2(along, t)), 2);
    const v = at.place(.{ 0, 0 }, turn, mirrored);
    const p = at.place(far, turn, mirrored);
    const lune = [_]primitives.OutlineEdge{
        .{ .a = v, .b = p, .arc = .{ .c = at.place(a_centre, turn, mirrored), .r = radii[0], .ccw = !mirrored } },
        .{ .a = p, .b = v, .arc = .{ .c = at.place(b_centre, turn, mirrored), .r = radii[1], .ccw = mirrored } },
    };
    return primitives.outlines(testing.allocator, tol, &.{&lune}, diag);
}

/// The lune's outcome: made, or the code of the finding it was refused with.
fn luneOutcome(radii: [2]f64, degrees: f64, turn: usize, mirrored: bool) !?diagnostics_mod.Code {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = tiltedLune(radii, degrees, turn, mirrored, &diag) catch |err| switch (err) {
        error.Degenerate, error.NotValid => return diag.findings.items[diag.findings.items.len - 1].code,
        else => return err,
    };
    sheet.deinit();
    return null;
}

test "primitives: a lune of two circles 0.2° apart at their vertex, just wider than a sliver, is made in every quarter turn, mirrored or not (find cs)" {
    // Batch E's probe (2026-11-22, cs): the sliver rule measured the face by the polygon
    // of samples along its edges, so by how many edges its arc was cut into; the arc of
    // radius 2 cut at its circle's seam in two of the eight placements measured 1.03 of the
    // least area and was made, whole in the other six, 0.95, refused `sliver_face`.
    // Measured exactly (`check.loopMeasure`) it is 1.015, made in all
    for (0..4) |turn| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("quarter turns {d}, mirrored {}\n", .{ turn, mirrored });
        try testing.expectEqual(@as(?diagnostics_mod.Code, null), try luneOutcome(LUNE_FIND_RADII, LUNE_FIND_TILT, turn, mirrored));
    };
}

test "primitives: lunes of two circles a fraction of a degree apart at their vertex, either side of a sliver, are made or refused alike in every quarter turn, mirrored or not" {
    for (LUNE_RADII) |radii| for (LUNE_TILTS) |degrees| {
        const first = try luneOutcome(radii, degrees, 0, false);
        for (0..4) |turn| for ([_]bool{ false, true }) |mirrored| {
            errdefer std.debug.print("radii {any}, {d}°, quarter turns {d}, mirrored {}: in place {any}\n", .{ radii, degrees, turn, mirrored, first });
            try testing.expectEqual(first, try luneOutcome(radii, degrees, turn, mirrored));
        };
    };
}

/// A circle about `c` as an outline's two half turns from its east point, the way round
/// `ccw` says.
fn circleOutline(c: Vec2, r: f64, ccw: bool) [2]primitives.OutlineEdge {
    const east: Vec2 = .{ c[0] + r, c[1] };
    const west: Vec2 = .{ c[0] - r, c[1] };
    return .{ .{ .a = east, .b = west, .arc = .{ .c = c, .r = r, .ccw = ccw } }, .{ .a = west, .b = east, .arc = .{ .c = c, .r = r, .ccw = ccw } } };
}

/// The disc with its hole on the ray at `degrees`, `at` from the centre, the hole's
/// outline mirrored in the x axis when `mirrored`: made, or the code it was refused with.
fn rimHoleOutcome(at: f64, degrees: f64, mirrored: bool) !?diagnostics_mod.Code {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const angle = degrees * PI / 180.0;
    const centre: Vec2 = .{ at * @cos(angle), if (mirrored) -at * @sin(angle) else at * @sin(angle) };
    const disc = circleOutline(.{ 0, 0 }, RIM_DISC, true);
    const hole = circleOutline(centre, RIM_HOLE, false);
    var sheet = primitives.outlines(testing.allocator, tol, &.{ &disc, &hole }, &diag) catch |err| switch (err) {
        error.Degenerate, error.NotValid => return diag.findings.items[diag.findings.items.len - 1].code,
        else => return err,
    };
    defer sheet.deinit();
    // A hole: the disc less it; a second disc beside the first: both
    const expected = PI * (RIM_DISC * RIM_DISC + (if (at < RIM_DISC) -RIM_HOLE * RIM_HOLE else RIM_HOLE * RIM_HOLE));
    try testing.expectApproxEqAbs(expected, (try mass.mass(&sheet, .{}, &diag)).area, 1e-9);
    try testing.expectEqual(@as(usize, if (at < RIM_DISC) 1 else 2), sheet.counts().faces);
    return null;
}

test "primitives: a disc with a round hole near its rim is made wherever round the rim the hole is" {
    // The audit of 2026-11-22: the checker's hole rule asked the hole's first point of the
    // outer loop's polygon of four samples a coedge, a half circle's an octagon's half,
    // and a hole 0.3 inside the rim between two samples was outside it (`hole_outside_outer`)
    for (0..RIM_HOLE_RAYS) |k| for ([_]bool{ false, true }) |mirrored| {
        const degrees = RIM_HOLE_FIRST + RIM_HOLE_STEP * @as(f64, @floatFromInt(k));
        errdefer std.debug.print("the hole at {d}°, mirrored {}\n", .{ degrees, mirrored });
        try testing.expectEqual(@as(?diagnostics_mod.Code, null), try rimHoleOutcome(RIM_HOLE_AT, degrees, mirrored));
        // Past the rim it is no hole: a second disc
        try testing.expectEqual(@as(?diagnostics_mod.Code, null), try rimHoleOutcome(RIM_HOLE_OUT, degrees, mirrored));
    };
}

/// A C ring about the origin: the outer arc of `C_OUTER` sweeping `sweep` degrees about
/// −x in one edge, the inner arc of `share` of it back, two radial lines between; and
/// `cuts − 1` small triangles inside the C, each a corner on the inner arc, which leave it
/// in `cuts` edges (consecutive pieces of one circle are one edge but at a vertex another
/// region touches). Turned and mirrored. Made, or the code it was refused with.
fn cRingOutcome(sweep: f64, share: f64, cuts: usize, turn: usize, mirrored: bool) !?diagnostics_mod.Code {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const at = struct {
        fn polar(r: f64, degrees: f64) Vec2 {
            const a = degrees * PI / 180.0;
            return .{ r * @cos(a), r * @sin(a) };
        }
        fn place(p: Vec2, quarter: usize, mirror: bool) Vec2 {
            var q = p;
            for (0..quarter) |_| {
                // Not in place: the second coordinate reads the first
                const turned: Vec2 = .{ -q[1], q[0] };
                q = turned;
            }
            return if (mirror) .{ -q[0], q[1] } else q;
        }
        fn on(r: f64, degrees: f64, quarter: usize, mirror: bool) Vec2 {
            return place(polar(r, degrees), quarter, mirror);
        }
    };
    const inner = C_OUTER * share;
    const from = 180.0 - sweep / 2.0;
    const to = 180.0 + sweep / 2.0;
    const centre: Vec2 = .{ 0, 0 };
    const ring = [_]primitives.OutlineEdge{
        .{ .a = at.on(C_OUTER, from, turn, mirrored), .b = at.on(C_OUTER, to, turn, mirrored), .arc = .{ .c = centre, .r = C_OUTER, .ccw = !mirrored } },
        .{ .a = at.on(C_OUTER, to, turn, mirrored), .b = at.on(inner, to, turn, mirrored) },
        .{ .a = at.on(inner, to, turn, mirrored), .b = at.on(inner, from, turn, mirrored), .arc = .{ .c = centre, .r = inner, .ccw = mirrored } },
        .{ .a = at.on(inner, from, turn, mirrored), .b = at.on(C_OUTER, from, turn, mirrored) },
    };
    var teeth: [MAX_C_TEETH][3]primitives.OutlineEdge = undefined;
    var contours: [MAX_C_TEETH + 1][]const primitives.OutlineEdge = undefined;
    contours[0] = &ring;
    for (1..cuts) |k| {
        const degrees = from + sweep * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(cuts));
        const apex = at.polar(inner, degrees);
        const back = at.polar(inner - C_TOOTH[0], degrees);
        const across = vec.scale2(vec.perp2(vec.normalized2(apex).?), C_TOOTH[1]);
        const corners = [3]Vec2{ at.place(apex, turn, mirrored), at.place(vec.add2(back, across), turn, mirrored), at.place(vec.sub2(back, across), turn, mirrored) };
        for (0..3) |c| teeth[k - 1][c] = .{ .a = corners[c], .b = corners[(c + 1) % 3] };
        contours[k] = &teeth[k - 1];
    }
    var sheet = primitives.outlines(testing.allocator, tol, contours[0..cuts], &diag) catch |err| switch (err) {
        error.Degenerate, error.NotValid => return diag.findings.items[diag.findings.items.len - 1].code,
        else => return err,
    };
    defer sheet.deinit();
    // The inner arc in as many edges as asked, with the outer (each in one more where
    // the placement puts its circle's seam on it)
    var arcs: usize = 0;
    for (sheet.edges.items) |e| {
        if (e.curve.kind == .circle) arcs += 1;
    }
    try testing.expect(arcs >= cuts + 1);
    const expected = sweep * PI / 360.0 * (C_OUTER * C_OUTER - inner * inner) + @as(f64, @floatFromInt(cuts - 1)) * C_TOOTH[0] * C_TOOTH[1];
    try testing.expectApproxEqAbs(expected, (try mass.mass(&sheet, .{}, &diag)).area, 1e-9);
    return null;
}

test "primitives: a C ring is made however many edges its inner arc is in, in every quarter turn, mirrored or not" {
    // The audit of 2026-11-22: the checker took a loop's winding from the polygon of four
    // samples a coedge; an arc of 270° in one edge lost far more area to its chords than
    // the inner arc in two, and a ring 0.7 wide read as wound backwards (`loop_winding`)
    for (C_SWEEPS) |sweep| for (C_SHARES) |share| for (C_CUTS) |cuts| for (0..4) |turn| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("sweep {d}°, inner {d} of the outer, in {d} edges, quarter turns {d}, mirrored {}\n", .{ sweep, share, cuts, turn, mirrored });
        try testing.expectEqual(@as(?diagnostics_mod.Code, null), try cRingOutcome(sweep, share, cuts, turn, mirrored));
    };
}
