//! The first three phases alone on two boxes overlapping at a corner, `a` from 0 to 2 on
//! each axis and `b` from 1 to 3, whose answers are counted by hand: the paves (merged
//! vertices, crossings, section segments), the fragments each face splits into, and their
//! classes; and on two boxes sharing a plane, the coplanar pairs and the same-domain
//! classes.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const mat = @import("../math/mat.zig");
const in_face = @import("../query/in_face.zig");
const pave = @import("pave.zig");
const imprint = @import("imprint.zig");
const classify = @import("classify.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
/// The probes of the test of a sample at the tolerance from a partner face's boundary to
/// rounding (find ec): the first the intersection tolerance outside the partner's side
/// x = 1, then one inside the partner, one outside it, or none; and whether the samples put
/// the fragment inside the partner.
const PROBE_AT: Vec3 = .{ 1 - 2e-5, 2, 1 };
const PROBE_CASES = [_]struct { next: ?Vec3, inside: bool }{
    .{ .next = .{ 2, 2, 1 }, .inside = true },
    .{ .next = .{ 0.5, 0.5, 1 }, .inside = false },
    .{ .next = null, .inside = false },
};
/// The rigid moves the probes and their boxes are taken through: a turn and a shift, and
/// the solids fuzzer's far move to 3e5.
const PROBE_MOVES = [_]struct { axis: Vec3, angle: f64, shift: Vec3 }{
    .{ .axis = .{ 0, 0, 1 }, .angle = 0, .shift = .{ 0, 0, 0 } },
    .{ .axis = .{ 1, 2, 3 }, .angle = 0.3, .shift = .{ 0.5, -1, 2 } },
    .{ .axis = .{ 1, 2, 3 }, .angle = 0.014142253476507214, .shift = .{ 1e5, -2e5, 3e5 } },
};
/// Where each run of the paves is; the refusal test reads it.
var stage: pave.Stage = .vertex_vertex;

fn box(lo: Vec3, hi: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var unit = try primitives.box(testing.allocator, tol, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], false, &diag);
    defer unit.deinit();
    return transform.transform(testing.allocator, &unit, &mat.Affine.translate(lo), .{}, &diag);
}

/// The face of `body` facing along `normal`.
fn facing(body: *const Body, normal: Vec3) u32 {
    for (body.faces.items, 0..) |f, i| {
        if (f.flags.tombstone) continue;
        if (vec.dot(in_face.outwardNormal(body, types.FaceIndex.of(i), .{ 0, 0 }), normal) > 0.5) return @intCast(i);
    }
    unreachable;
}

test "paves: two boxes at a corner, sixteen vertices and six crossings, two section segments on each notched face" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    // Each of the three edges of `b` from its corner inside `a` leaves through a face of
    // `a`, and each of `a`'s from its corner inside `b` enters through a face of `b`
    try testing.expectEqual(@as(usize, 16 + 6), p.points.items.len);
    var crossings: usize = 0;
    for (p.owners.items) |o| crossings += @intFromBool(o == 0);
    try testing.expectEqual(@as(usize, 6), crossings);
    // Every edge of `a` from (2, 2, 2) has one crossing inside it, at its middle
    var split: usize = 0;
    for (p.edge_paves[0]) |list| {
        if (list.items.len == 3) {
            split += 1;
            try testing.expectApproxEqAbs(@as(f64, 0.5), list.items[1].s, 1e-12);
        } else try testing.expectEqual(@as(usize, 2), list.items.len);
    }
    try testing.expectEqual(@as(usize, 3), split);
    // The faces of `a` at x, y, z = 2 each take two segments of `b`'s faces; the others none
    for ([_]Vec3{ vec.X3, vec.Y3, vec.Z3 }) |n| {
        try testing.expectEqual(@as(usize, 2), p.sections[0][facing(&a, n)].items.len);
        try testing.expectEqual(@as(usize, 0), p.sections[0][facing(&a, vec.neg(n))].items.len);
        try testing.expectEqual(@as(usize, 2), p.sections[1][facing(&b, vec.neg(n))].items.len);
    }
    try testing.expectEqual(@as(usize, 0), p.coplanar.items.len);

    // Imprinted: the three notched faces of each box in two, the rest whole
    var fragments = try imprint.run(testing.allocator, &p, .{}, &diag);
    defer fragments.deinit();
    try testing.expectEqual(@as(usize, 2 * (3 + 3 * 2)), fragments.items.items.len);
    // Classified: of each box, the three unit squares inside the other
    var stats: classify.Stats = .{};
    const classes = try classify.run(testing.allocator, &p, &fragments, .{}, true, &diag, &stats);
    defer testing.allocator.free(classes);
    var inside = [2]usize{ 0, 0 };
    for (fragments.items.items, classes) |f, c| {
        try testing.expect(c.class == .inside or c.class == .outside);
        inside[f.operand] += @intFromBool(c.class == .inside);
    }
    try testing.expectEqual([2]usize{ 3, 3 }, inside);
}

test "paves: boxes on one plane pair their faces there, and the shared part is the same domain" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 0 }, .{ 3, 3, 1 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    // Tops with tops and bottoms with bottoms; no side lies in another's plane
    try testing.expectEqual(@as(usize, 2), p.coplanar.items.len);
    var fragments = try imprint.run(testing.allocator, &p, .{}, &diag);
    defer fragments.deinit();
    var stats: classify.Stats = .{};
    const classes = try classify.run(testing.allocator, &p, &fragments, .{}, true, &diag, &stats);
    defer testing.allocator.free(classes);
    // Each top and bottom: the shared unit square, on the other's face facing the same way
    var same: usize = 0;
    for (classes) |c| {
        try testing.expect(c.class != .on_opposite);
        same += @intFromBool(c.class == .on_same);
        // A coincident piece names the face it lies on
        try testing.expectEqual(c.class == .on_same, c.partner != classify.NONE);
    }
    try testing.expectEqual(@as(usize, 4), same);
}

test "paves: a box resting on another meets it face to face, the same domain facing the other way" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    var b = try box(.{ 0.5, 0.5, 1 }, .{ 1.5, 1.5, 2 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.coplanar.items.len);
    // The resting box's corners lie on the top's face, inside it
    try testing.expectEqual(@as(usize, 16), p.points.items.len);
    var fragments = try imprint.run(testing.allocator, &p, .{}, &diag);
    defer fragments.deinit();
    var stats: classify.Stats = .{};
    const classes = try classify.run(testing.allocator, &p, &fragments, .{}, true, &diag, &stats);
    defer testing.allocator.free(classes);
    var opposite: usize = 0;
    for (classes) |c| opposite += @intFromBool(c.class == .on_opposite);
    // The square under the resting box, and the resting box's bottom
    try testing.expectEqual(@as(usize, 2), opposite);
}

test "paves: boxes overlapping along four edges have four common blocks; at a corner none" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 0, 0 }, .{ 3, 2, 2 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    // Each of the four edges along x where y and z are 0 or 2: from x = 1 to 2 in both
    try testing.expectEqual(@as(usize, 4), p.common.items.len);
    for (p.common.items) |block| {
        try testing.expectApproxEqAbs(@as(f64, 1), vec.distance(p.point(block.vertices[0]), p.point(block.vertices[1])), 1e-12);
    }
    var c = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer c.deinit();
    var q = try pave.run(testing.allocator, &a, &c, tol, .{}, &diag, &stage);
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.common.items.len);
}

test "paves: an edge whose shrunk range is under twice the tolerance is not split, but refused" {
    // A slab three intersection tolerances thick, cut through the middle of its height:
    // each vertical edge would be split a tolerance and a half from either end
    const xsect = tol.xsect;
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 3 * xsect });
    defer a.deinit();
    var b = try box(.{ 0.25, 0.25, 1.5 * xsect }, .{ 2, 2, 1 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.TooSmallEdge, pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage));
    const f = diag.first().?;
    try testing.expectEqual(diagnostics.Code.edge_too_short, f.code);
    try testing.expectEqual(diagnostics.EntityKind.edge, f.entity.kind);
    // Refused in the class that would have split it, which the finding names
    try testing.expectEqual(pave.Stage.edge_face, stage);
    try testing.expect(std.mem.indexOf(u8, f.label, "(edge–face)") != null);
}

test "paves: a vertex between the zone and the tolerance of a face's edge is that edge's pave and on the face's boundary, not touching inside it" {
    // Vertex–edge made the apex a pave of the box's top edge (within the intersection
    // tolerance); vertex–face then decided the same incidence again at the zone and found
    // the apex inside the top face, a touch (the research review, 2026-11-14)
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const apex = Vec3{ 1, 1.5e-5, 2 };
    var b = try @import("../construct/hull.zig").hull(testing.allocator, tol, &.{ apex, .{ 0.5, 0.5, 3 }, .{ 1.5, 0.5, 3 }, .{ 1, 1, 3 } }, &diag);
    defer b.deinit();
    var phase: pave.Stage = .operands;
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &phase);
    defer p.deinit();
    // The apex's merged vertex
    var m: ?u32 = null;
    for (b.vertices.items, 0..) |v, i| {
        if (!v.tombstone and vec.distance(b.geometry.point(v.point), apex) == 0) m = p.vertex_of[1][i];
    }
    try testing.expect(m != null);
    // A pave of an edge of the box
    var paved = false;
    for (p.edge_paves[0]) |list| for (list.items) |x| {
        paved = paved or x.vertex == m.?;
    };
    try testing.expect(paved);
    // And no touch inside a face of the box
    for (p.touches.items) |t| try testing.expect(!(t.operand == 0 and t.vertex == m.?));
}

test "paves: two solids of an operand touching along a line meet there by their edges' copies, a face across the line's middle not refused" {
    // OCCT's buc60801 as a chain (the corpus port, 2026-11-14): a difference leaves two
    // solids touching along a line, each with its own edge there; the next cut, its face
    // across the line's middle, was refused (`below_feature_size`): the faces of the two
    // solids on either side of the vertex there meet at it only through the edges' copies
    const pipeline = @import("pipeline.zig");
    const helpers = @import("pipeline_test.zig");
    var p = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer p.deinit();
    var q = try box(.{ 1, 1, 0 }, .{ 2, 2, 1 });
    defer q.deinit();
    var touching = try helpers.sound(&p, &q, .@"union");
    defer touching.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, helpers.shellKinds(&touching));
    var cut = try box(.{ -1, -1, 0.5 }, .{ 3, 3, 2 });
    defer cut.deinit();
    // The tops and the bottoms: two solids touching along the line, as they were
    for ([_]pipeline.Op{ .intersection, .difference }) |op| {
        var r = try helpers.sound(&touching, &cut, op);
        defer r.deinit();
        try testing.expectEqual([2]usize{ 2, 0 }, helpers.shellKinds(&r));
        try testing.expectApproxEqAbs(@as(f64, 1), try helpers.volume(&r), 1e-12);
    }
    // The union is one solid whose bottoms still touch along the line: a pinch, refused by
    // design, not a feature too small
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &touching, &cut, .@"union", .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
}

test "paves: a fragment's sample the tolerance from a partner's boundary to rounding says nothing, the next sample decides, alike mirrored and moved (find ec)" {
    // Find ec (the nightly's locus_solids on 61054773): a fragment with no twin is checked
    // to be no region of a partner by samples inside it, its triangulation's centroids,
    // which a mirror changes. One sample lay 3.8e-14 past the tolerance from the partner's
    // boundary, within D27's band, and the union was refused `at_tolerance` in place and
    // made mirrored, where no sample lay there. A sample at the boundary to rounding says
    // nothing, as one on it does (`planar_faces.placed`)
    for (PROBE_MOVES) |move| for ([_]bool{ false, true }) |mirrored| for (PROBE_CASES) |case| {
        errdefer std.debug.print("turned {d} about {any}, shifted {any}, mirrored {}, next {any}\n", .{ move.angle, move.axis, move.shift, mirrored, case.next });
        var place = mat.Affine.translate(move.shift).compose(&mat.Affine.rotate(vec.normalized(move.axis).?, move.angle));
        if (mirrored) place = place.compose(&mat.Affine.mirror(.{ 1, 0, 0 }));
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var drawn_a = try box(.{ 0, 0, 0 }, .{ 4, 4, 1 });
        defer drawn_a.deinit();
        var drawn_b = try box(.{ 1, 1, 0 }, .{ 3, 3, 1 });
        defer drawn_b.deinit();
        var a = try transform.transform(testing.allocator, &drawn_a, &place, .{}, &diag);
        defer a.deinit();
        var b = try transform.transform(testing.allocator, &drawn_b, &place, .{}, &diag);
        defer b.deinit();
        var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
        defer p.deinit();
        const up = place.vector(.{ 0, 0, 1 });
        const top_a = types.FaceIndex.of(facing(&a, up));
        const top_b = facing(&b, up);
        var samples: [2]Vec3 = undefined;
        samples[0] = place.point(PROBE_AT);
        // The first sample is at the boundary to rounding
        try testing.expect(try planar_faces.placed(&b, types.FaceIndex.of(top_b), samples[0], 0, tol, &diag) == .at_tolerance);
        var n: usize = 1;
        if (case.next) |q| {
            samples[1] = place.point(q);
            n = 2;
        }
        const found = try classify.sameDomain(&p, &a, top_a, 1, samples[0..n], &.{top_b}, &diag);
        try testing.expectEqual(case.inside, found != null);
    };
}
