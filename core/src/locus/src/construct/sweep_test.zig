//! Extrusions of the sketch faces: the counts, the checker, the bounds, and every face's
//! outward normal pointing away from the material (what the checker's orientation rules
//! do not yet test).

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const mass = @import("../measure/mass.zig");
const primitives = @import("primitives.zig");
const sweep = @import("sweep.zig");
const bbox = @import("../measure/bbox.zig");
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);

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

fn expectCounts(body: *const Body, vertices: usize, edges: usize, faces: usize, loops: usize) !void {
    const c = body.counts();
    try testing.expectEqual(vertices, c.vertices);
    try testing.expectEqual(edges, c.edges);
    try testing.expectEqual(faces, c.faces);
    try testing.expectEqual(loops, c.loops);
}

fn expectVec(expected: Vec3, actual: Vec3, t: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], t);
}

/// How far into a face from its first edge the probe point sits, and how far off the face
/// the two probes are placed (the first small against any curvature).
const INTO_FACE = 5e-3;
const OFF_FACE = 1e-3;

/// Every face has the material on its left and its outward normal leaving it: from the
/// middle of its first edge, a step into the face (to the coedge's left) lands on the face,
/// and from there a step along the outward normal lands outside the solid `inside`
/// describes, a step against it inside.
fn expectOutward(body: *const Body, comptime inside: fn (Vec3) bool) !void {
    const traverse = @import("../topology/traverse.zig");
    for (body.faces.items, 0..) |f, fi| {
        if (f.flags.tombstone) continue;
        const s = body.geometry.surface(f.surface);
        var it = traverse.Coedges.init(body, f.first_loop);
        const c = (try it.next()).?;
        const coedge = body.coedge(c);
        const e = body.edge(coedge.edge);
        const curve = body.geometry.curve(e.curve);
        const t = (e.t0 + e.t1) / 2.0;
        const on_edge = curve.eval(t);
        const tangent = vec.normalized(vec.scale(curve.d1(t), if (coedge.same_sense) @as(f64, 1) else -1)).?;
        const uv = s.project(on_edge, body.tol.approx, 50);
        const n = vec.scale(s.normal(uv[0], uv[1]), if (f.same_sense) @as(f64, 1) else -1);
        const p = vec.addScaled(on_edge, vec.normalized(vec.cross(n, tangent)).?, INTO_FACE);
        errdefer std.debug.print("face {d}: probe {d:.3} {d:.3} {d:.3}, normal {d:.3} {d:.3} {d:.3}\n", .{ fi, p[0], p[1], p[2], n[0], n[1], n[2] });
        try testing.expect(!inside(vec.addScaled(p, n, OFF_FACE)));
        try testing.expect(inside(vec.addScaled(p, n, -OFF_FACE)));
    }
}

/// The solids the tests build, as what a point of them is.
const Solids = struct {
    fn box(p: Vec3) bool {
        return p[0] > 0 and p[0] < 2 and p[1] > 0 and p[1] < 3 and p[2] > 0 and p[2] < 4;
    }
    fn cylinder(p: Vec3) bool {
        return radial(p) < 2 and p[2] > 0 and p[2] < 5;
    }
    fn platePlusHole(p: Vec3, z0: f64, z1: f64) bool {
        const in_plate = @abs(p[0]) < 10 and @abs(p[1]) < 10 and p[2] > z0 and p[2] < z1;
        const in_hole = @abs(p[0]) < 2 and @abs(p[1]) < 2;
        return in_plate and !in_hole;
    }
    fn plateUp(p: Vec3) bool {
        return platePlusHole(p, 0, 3);
    }
    fn plateDown(p: Vec3) bool {
        return platePlusHole(p, -3, 0);
    }
    fn skew(p: Vec3) bool {
        // The circle of radius 2 swept along (1, 0, 4): at height z its centre is at x = z/4
        if (p[2] <= 0 or p[2] >= 4) return false;
        const cx = p[2] / 4.0;
        return (p[0] - cx) * (p[0] - cx) + p[1] * p[1] < 4;
    }
    fn ring(p: Vec3) bool {
        const r = radial(p);
        return r > 1 and r < 3 and p[2] > 0 and p[2] < 3;
    }
    fn drum(p: Vec3) bool {
        return radial(p) < 2 and p[2] > 0 and p[2] < 3;
    }
    fn cone(p: Vec3) bool {
        // Radius 2 at z = 0 to 0 at z = 3
        return p[2] > 0 and p[2] < 3 and radial(p) < 2.0 * (1.0 - p[2] / 3.0);
    }
    fn torus(p: Vec3) bool {
        const d = radial(p) - 3.0;
        return d * d + p[2] * p[2] < 1;
    }
    fn quarterRing(p: Vec3) bool {
        return ring(p) and p[0] > 0 and p[1] > 0;
    }
    fn mostOfRing(p: Vec3) bool {
        // All but the quarter x > 0, y < 0
        return ring(p) and !(p[0] > 0 and p[1] < 0);
    }
    fn backQuarter(p: Vec3) bool {
        return ring(p) and p[0] > 0 and p[1] < 0;
    }
    fn radial(p: Vec3) f64 {
        return @sqrt(p[0] * p[0] + p[1] * p[1]);
    }
};

/// `revolve`, with the diagnostics printed when it fails.
fn revolved(profile: *const Body, angle: f64, diag: *Diagnostics) !Body {
    return sweep.revolve(testing.allocator, profile, vec.ZERO3, vec.Z3, angle, .{}, diag) catch |e| {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        diag.format(&w) catch {};
        std.debug.print("revolve: {s}\n", .{w.buffered()});
        return e;
    };
}

test "extrude: a square is a box, a circle a cylinder, each outward" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 2, 3, false, &diag);
    defer sq.deinit();
    var box = try sweep.extrude(testing.allocator, &sq, .{ 0, 0, 4 }, .{}, &diag);
    defer box.deinit();
    try expectCounts(&box, 8, 12, 6, 6);
    try expectValid(&box);
    const bb = try bbox.bodyBounds(&box);
    try expectVec(.{ 0, 0, 0 }, bb.min, 1e-12);
    try expectVec(.{ 2, 3, 4 }, bb.max, 1e-12);
    try expectOutward(&box, Solids.box);
    try testing.expectEqual(@as(usize, 6), box.geometry.planes.items.len);

    var ci = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer ci.deinit();
    var cyl = try sweep.extrude(testing.allocator, &ci, .{ 0, 0, 5 }, .{}, &diag);
    defer cyl.deinit();
    try expectCounts(&cyl, 4, 6, 4, 4);
    try expectValid(&cyl);
    const cb = try bbox.bodyBounds(&cyl);
    try expectVec(.{ -2, -2, 0 }, cb.min, 1e-12);
    try expectVec(.{ 2, 2, 5 }, cb.max, 1e-12);
    try expectOutward(&cyl, Solids.cylinder);
    try testing.expectEqual(@as(usize, 1), cyl.geometry.cylinders.items.len);
    for (cyl.coedges.items) |c| {
        const on_side = cyl.face(cyl.loop(c.loop).face).surface.kind == .cylinder;
        try testing.expectEqual(on_side, !c.pcurve.isNone());
    }
}

test "extrude: a plate with a hole has the hole through it; downward and askew sweeps stay outward" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]vec.Vec2{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_]vec.Vec2{ .{ -2, -2 }, .{ -2, 2 }, .{ 2, 2 }, .{ 2, -2 } };
    var plate = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer plate.deinit();
    var solid = try sweep.extrude(testing.allocator, &plate, .{ 0, 0, 3 }, .{}, &diag);
    defer solid.deinit();
    try expectCounts(&solid, 16, 24, 10, 12);
    try expectValid(&solid);
    try expectOutward(&solid, Solids.plateUp);

    // Downward: the same solid below the plane
    var down = try sweep.extrude(testing.allocator, &plate, .{ 0, 0, -3 }, .{}, &diag);
    defer down.deinit();
    try expectCounts(&down, 16, 24, 10, 12);
    try expectValid(&down);
    const db = try bbox.bodyBounds(&down);
    try expectVec(.{ -10, -10, -3 }, db.min, 1e-12);
    try expectVec(.{ 10, 10, 0 }, db.max, 1e-12);
    try expectOutward(&down, Solids.plateDown);

    // Askew: a circle's side is an extrusion surface, a square's are planes
    var ci = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer ci.deinit();
    var skew = try sweep.extrude(testing.allocator, &ci, .{ 1, 0, 4 }, .{}, &diag);
    defer skew.deinit();
    try expectCounts(&skew, 4, 6, 4, 4);
    try expectValid(&skew);
    try testing.expectEqual(@as(usize, 2), skew.geometry.extrusions.items.len);
    try expectOutward(&skew, Solids.skew);

    // Refusals: no rise, a solid as a profile
    try testing.expectError(error.InvalidInput, sweep.extrude(testing.allocator, &plate, .{ 1, 0, 0 }, .{}, &diag));
    try testing.expectError(error.InvalidInput, sweep.extrude(testing.allocator, &solid, .{ 0, 0, 1 }, .{}, &diag));
    try testing.expectError(error.InvalidInput, sweep.extrude(testing.allocator, &plate, .{ 0, 0, 0 }, .{}, &diag));
}

/// The sketch stood up in the xz-plane: its x the radius, its y the height (what KupCAD
/// revolves about z).
fn stoodUp(sketch: *const Body, diag: *Diagnostics) !Body {
    const transform = @import("transform.zig");
    const mat = @import("../math/mat.zig");
    const up = mat.Affine.rotate(vec.X3, std.math.pi / 2.0);
    return transform.transform(testing.allocator, sketch, &up, .{}, diag);
}

test "revolve: a square off the axis is a ring, on the axis a cylinder, a triangle a cone, a circle a torus" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // A ring: two cylinders and two annuli, each in two halves
    var sq = try primitives.square(testing.allocator, tol, 2, 3, false, &diag);
    defer sq.deinit();
    const transform = @import("transform.zig");
    const mat = @import("../math/mat.zig");
    var shifted = try transform.transform(testing.allocator, &sq, &mat.Affine.translate(.{ 1, 0, 0 }), .{}, &diag);
    defer shifted.deinit();
    var profile = try stoodUp(&shifted, &diag);
    defer profile.deinit();
    var ring = try revolved(&profile, 2.0 * std.math.pi, &diag);
    defer ring.deinit();
    try expectCounts(&ring, 8, 16, 8, 8);
    try expectValid(&ring);
    const rb = try bbox.bodyBounds(&ring);
    try expectVec(.{ -3, -3, 0 }, rb.min, 1e-12);
    try expectVec(.{ 3, 3, 3 }, rb.max, 1e-12);
    try expectOutward(&ring, Solids.ring);
    try testing.expectEqual(@as(usize, 2), ring.geometry.cylinders.items.len);

    // A cylinder: the edge on the axis sweeps nothing, its ends are the discs' centres
    var on_axis = try stoodUp(&sq, &diag);
    defer on_axis.deinit();
    var cyl = try revolved(&on_axis, 2.0 * std.math.pi, &diag);
    defer cyl.deinit();
    try expectCounts(&cyl, 6, 10, 6, 6);
    try expectValid(&cyl);
    const cb = try bbox.bodyBounds(&cyl);
    try expectVec(.{ -2, -2, 0 }, cb.min, 1e-12);
    try expectVec(.{ 2, 2, 3 }, cb.max, 1e-12);
    try expectOutward(&cyl, Solids.drum);

    // A cone with its apex on the axis: degenerate edges there
    var tri_sketch = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 3 } }, &diag);
    defer tri_sketch.deinit();
    var tri = try stoodUp(&tri_sketch, &diag);
    defer tri.deinit();
    var cone = try revolved(&tri, 2.0 * std.math.pi, &diag);
    defer cone.deinit();
    try expectValid(&cone);
    try testing.expectEqual(@as(usize, 1), cone.geometry.cones.items.len);
    try expectOutward(&cone, Solids.cone);
    var degenerate: usize = 0;
    for (cone.edges.items) |e| degenerate += @intFromBool(e.flags.degenerate);
    try testing.expectEqual(@as(usize, 2), degenerate);

    // A torus from a circle off the axis
    var ci = try primitives.circle(testing.allocator, tol, 1, &diag);
    defer ci.deinit();
    var ci_off = try transform.transform(testing.allocator, &ci, &mat.Affine.translate(.{ 3, 0, 0 }), .{}, &diag);
    defer ci_off.deinit();
    var ci_up = try stoodUp(&ci_off, &diag);
    defer ci_up.deinit();
    var torus = try revolved(&ci_up, 2.0 * std.math.pi, &diag);
    defer torus.deinit();
    try expectCounts(&torus, 4, 8, 4, 4);
    try expectValid(&torus);
    try testing.expectEqual(@as(usize, 1), torus.geometry.tori.items.len);
    const tb = try bbox.bodyBounds(&torus);
    try expectVec(.{ -4, -4, -1 }, tb.min, 1e-12);
    try expectVec(.{ 4, 4, 1 }, tb.max, 1e-12);
    try expectOutward(&torus, Solids.torus);
}

test "revolve: a partial turn has caps, a long one is split, a negative one turns the other way; crossings are refused" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const transform = @import("transform.zig");
    const mat = @import("../math/mat.zig");
    var sq = try primitives.square(testing.allocator, tol, 2, 3, false, &diag);
    defer sq.deinit();
    var shifted = try transform.transform(testing.allocator, &sq, &mat.Affine.translate(.{ 1, 0, 0 }), .{}, &diag);
    defer shifted.deinit();
    var profile = try stoodUp(&shifted, &diag);
    defer profile.deinit();

    var quarter = try revolved(&profile, std.math.pi / 2.0, &diag);
    defer quarter.deinit();
    try expectCounts(&quarter, 8, 12, 6, 6);
    try expectValid(&quarter);
    const qb = try bbox.bodyBounds(&quarter);
    try expectVec(.{ 0, 0, 0 }, qb.min, 1e-12);
    try expectVec(.{ 3, 3, 3 }, qb.max, 1e-12);
    try expectOutward(&quarter, Solids.quarterRing);

    var most = try revolved(&profile, 1.5 * std.math.pi, &diag);
    defer most.deinit();
    try expectCounts(&most, 12, 20, 10, 10);
    try expectValid(&most);
    const mb = try bbox.bodyBounds(&most);
    try expectVec(.{ -3, -3, 0 }, mb.min, 1e-12);
    try expectVec(.{ 3, 3, 3 }, mb.max, 1e-12);
    try expectOutward(&most, Solids.mostOfRing);

    var back = try revolved(&profile, -std.math.pi / 2.0, &diag);
    defer back.deinit();
    try expectValid(&back);
    const bb = try bbox.bodyBounds(&back);
    try expectVec(.{ 0, -3, 0 }, bb.min, 1e-12);
    try expectVec(.{ 3, 0, 3 }, bb.max, 1e-12);
    try expectOutward(&back, Solids.backQuarter);

    // Refusals: a profile across the axis, an axis out of the plane, a turn of nothing
    var centred = try primitives.square(testing.allocator, tol, 2, 2, true, &diag);
    defer centred.deinit();
    var crossing = try stoodUp(&centred, &diag);
    defer crossing.deinit();
    try testing.expectError(error.NotRepresentable, sweep.revolve(testing.allocator, &crossing, vec.ZERO3, vec.Z3, 1, .{}, &diag));
    try testing.expectError(error.InvalidInput, sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Y3, 1, .{}, &diag));
    try testing.expectError(error.InvalidInput, sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Z3, 0, .{}, &diag));
}


test "extrude: a sheet whose arc crosses its circle's seam sweeps two cylinder faces, not a periodic one" {
    // A stadium from outlines: its right arc runs from −90° through 0° to 90° about
    // (4, 1), split at the seam into two edges, so the extrusion has two side faces
    // there, each within its cylinder's period (the fuzzer's and the case rig's closed
    // paths, 2026-11-11)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const Arc = primitives.OutlineArc;
    const stadium = [_]primitives.OutlineEdge{
        .{ .a = .{ 0, 0 }, .b = .{ 4, 0 } },
        .{ .a = .{ 4, 0 }, .b = .{ 4, 2 }, .arc = Arc{ .c = .{ 4, 1 }, .r = 1, .ccw = true } },
        .{ .a = .{ 4, 2 }, .b = .{ 0, 2 } },
        .{ .a = .{ 0, 2 }, .b = .{ 0, 0 }, .arc = Arc{ .c = .{ 0, 1 }, .r = 1, .ccw = true } },
    };
    var sheet = try primitives.outlines(testing.allocator, tol, &.{&stadium}, &diag);
    defer sheet.deinit();
    var solid = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 2 }, .{}, &diag);
    defer solid.deinit();
    try expectValid(&solid);
    // Two caps and five sides
    try std.testing.expectEqual(@as(usize, 7), solid.counts().faces);
    const m = try @import("../measure/mass.zig").mass(&solid, .{}, &diag);
    try std.testing.expectApproxEqRel((8 + std.math.pi) * 2, m.volume, 1e-9);
}

test "revolve: a profile arc across its torus's seam is split there and the ring is valid, its volume Pappus's" {
    // A 2 by 1 rectangle with a round top: the arc from (1, 1) to (-1, 1) about (0, 0.5),
    // radius √1.25, runs from 0.4636 to π − 0.4636 and so across π/2; turned about an
    // axis along x through (0, -5, 0), the radial direction is +y and the torus's seam is
    // at the arc's top, inside it
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const r = @sqrt(1.25);
    const Arc = primitives.OutlineArc;
    const outline = [_]primitives.OutlineEdge{
        .{ .a = .{ -1, 0 }, .b = .{ 1, 0 } },
        .{ .a = .{ 1, 0 }, .b = .{ 1, 1 } },
        .{ .a = .{ 1, 1 }, .b = .{ -1, 1 }, .arc = Arc{ .c = .{ 0, 0.5 }, .r = r, .ccw = true } },
        .{ .a = .{ -1, 1 }, .b = .{ -1, 0 } },
    };
    var sheet = try primitives.outlines(testing.allocator, tol, &.{&outline}, &diag);
    defer sheet.deinit();
    try testing.expectEqual(@as(usize, 4), sheet.counts().edges);
    // (The radial direction is the axis crossed with the sheet's normal, +y for −x and
    // +z, so the axis runs along −x to keep the profile on the radial side)
    var ring = try sweep.revolve(testing.allocator, &sheet, .{ 0, -5, 0 }, vec.neg(vec.X3), 2 * std.math.pi, .{}, &diag);
    defer ring.deinit();
    var report = try check.run(testing.allocator, &ring, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| std.debug.print("checker: {f}\n", .{f});
    try testing.expect(report.ok());
    // Two torus faces per half turn: the arc was split at the seam
    var tori: usize = 0;
    for (ring.faces.items) |f| tori += @intFromBool(!f.flags.tombstone and f.surface.kind == .torus);
    try testing.expectEqual(@as(usize, 4), tori);
    // Pappus: the profile's area times the circle its centroid runs (the rectangle and
    // the circular segment over the chord y = 1)
    const half: f64 = 0.5;
    const theta = 2 * (std.math.pi / 2.0 - std.math.atan2(half, 1.0));
    const segment = r * r / 2.0 * (theta - @sin(theta));
    const segment_centroid = 0.5 + 4 * r * std.math.pow(f64, @sin(theta / 2), 3) / (3 * (theta - @sin(theta)));
    const area = 2 + segment;
    const centroid_y = (2 * 0.5 + segment * segment_centroid) / area;
    const m = try mass.mass(&ring, .{}, &diag);
    try testing.expectApproxEqRel(2 * std.math.pi * (centroid_y + 5) * area, m.volume, 1e-9);
    // About an axis along y, the seam at the arc's ends: nothing split, the same validity
    var about_y = try sweep.revolve(testing.allocator, &sheet, .{ -5, 0, 0 }, vec.Y3, std.math.pi, .{}, &diag);
    defer about_y.deinit();
    var r2 = try check.run(testing.allocator, &about_y, .global);
    defer r2.deinit(testing.allocator);
    try testing.expect(r2.ok());
}
