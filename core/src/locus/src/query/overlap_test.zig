//! The overlap rules on sound solids (a box, a box with a void, a solid in the void of
//! another, the bow tie's two prisms touching along a line) and one negative fixture per
//! rule, each of which every rule of the checker passes: a shell folded through itself,
//! two solids crossing, two lying on each other over part of a face, a solid inside
//! another, a void outside every solid, a void inside a void.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const traverse = @import("../topology/traverse.zig");
const integrals = @import("../topology/integrals.zig");
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const sew = @import("../construct/sew.zig");
const overlap = @import("overlap.zig");
const cover = @import("../topology/cover.zig");
const transform = @import("../construct/transform.zig");
const mat = @import("../math/mat.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
/// Two sheets whose faces cross along the x axis (the audit of order and frame,
/// 2026-11-27): one in z = 0, a square with a V notch from its top whose apex lies
/// `NOTCH_APEX` intersection tolerances over the axis; one in y = 0, drawn in (x, z), a
/// rectangle with a notch up from its bottom over x 4..6, so the gap of the faces' line
/// between that notch's sides lies outside it, its middle under the V's apex.
const NOTCH_APEX = [_]f64{ 1, 0.5, 1.5 };
const NOTCH_SHIFTS = [_]Vec3{ vec.ZERO3, .{ 1e5, -2e5, 3e5 } };
/// A corner of an extruded sheet where a narrow side face folds back over its long
/// neighbour within the zone of their shared edge: the sheet's outline, the long side
/// first, the narrow one second, its far end 1.9e-5 over the long side's line (the
/// tolerance 2e-5) and 9e-6 back along it (the zone 1e-5), 64.7° to it: the corner of the
/// nightly's sheet (2026-11-21, bu) and the same at 65° from a round corner.
const FOLDS = [_][4]vec.Vec2{
    .{ .{ 4.5, 2 }, .{ 5.000015276650916, 2 }, .{ 5.00000632455532, 2.000018973665961 }, .{ 4.6552495314720685, 2.114937904693712 } },
    .{ .{ 0, 0 }, .{ 0.5, 0 }, .{ 0.5 - FOLD_RISE / @tan(FOLD_TURN), FOLD_RISE }, .{ 0.15, 0.12 } },
};
const FOLD_RISE: f64 = 1.9e-5;
const FOLD_TURN: f64 = 65.0 * std.math.pi / 180.0;
/// Folds past the zone: a narrow side 1.9e-5 or 1.5e-5 over the long side's line at 10°,
/// 45° and 55° to it, back along it by 1.3e-5 to 1.1e-4, lying on the long face over a
/// strip wider than the zone (in degrees, and the rise).
const FOLDS_PAST = [_][2]f64{ .{ 45, 1.9e-5 }, .{ 55, 1.9e-5 }, .{ 10, 1.5e-5 } };
/// How tall the folds are extruded, as the nightly's chain extruded its sheet.
const FOLD_HEIGHT: f64 = 6;
/// The quarter turns about z the folds are tried in.
const QUARTER_TURNS = 4;
/// A box's far corner moved out along its diagonal, off its three edges' lines by these
/// distances, its gap then covering them (`cover.coverBody`): within the tolerance (no
/// gap), at it, find eh's (2.031e-5), and past it to a gap of nearly the zone.
const CORNER_OFFSETS = [_]f64{ 1.5e-5, 2e-5, 2.031e-5, 2.5e-5, 2.9e-5 };
/// The boxes whose far corner is moved: at the origin, and where eh's lay.
const CORNER_BOXES = [_]BoxSpec{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } }, .{ .lo = .{ 1.5, -0.5, 0 }, .hi = .{ 2.335335, 0.66467, 1.00001 } } };
/// The rigid moves the moved corner is tried under besides in place: a turn and a far
/// shift (the solids fuzzer's, out to 3e5), and the mirrors in each axis.
const CORNER_TURN_AXIS: Vec3 = .{ 1, 2, 3 };
const CORNER_TURN: f64 = 0.3;
const CORNER_FAR: Vec3 = .{ 1e5, -2e5, 3e5 };

/// An axis-aligned box from `lo` to `hi`, a void's (faces wound into it) when `void`.
const BoxSpec = struct { lo: Vec3, hi: Vec3, void: bool = false };

/// The boxes as the shells of one body, built by hand (`polyhedron` grades each shell an
/// outer one): a shell of negative volume is a void.
fn boxes(allocator: std.mem.Allocator, specs: []const BoxSpec) !Body {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try primitives.Builder.init(allocator, tol, .solid, &diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const quads = [6][4]u8{ .{ 0, 3, 2, 1 }, .{ 4, 5, 6, 7 }, .{ 0, 1, 5, 4 }, .{ 1, 2, 6, 5 }, .{ 2, 3, 7, 6 }, .{ 3, 0, 4, 7 } };
    const normals = [6]Vec3{ vec.neg(vec.Z3), vec.Z3, vec.neg(vec.Y3), vec.X3, vec.Y3, vec.neg(vec.X3) };
    const faces = try allocator.alloc(sew.FaceSpec, 6 * specs.len);
    defer allocator.free(faces);
    const edges = try allocator.alloc([4]sew.EdgeSpec, 6 * specs.len);
    defer allocator.free(edges);
    const loops = try allocator.alloc([1]sew.LoopSpec, 6 * specs.len);
    defer allocator.free(loops);
    var vertex_at: std.AutoHashMapUnmanaged(u32, types.VertexIndex) = .empty;
    defer vertex_at.deinit(allocator);
    for (specs, 0..) |spec, k| {
        const lo = spec.lo;
        const hi = spec.hi;
        const corners = [8]Vec3{
            lo,                       .{ hi[0], lo[1], lo[2] }, .{ hi[0], hi[1], lo[2] }, .{ lo[0], hi[1], lo[2] },
            .{ lo[0], lo[1], hi[2] }, .{ hi[0], lo[1], hi[2] }, hi,                       .{ lo[0], hi[1], hi[2] },
        };
        var v: [8]types.VertexIndex = undefined;
        for (corners, 0..) |p, i| {
            // One vertex record per point: boxes sharing a corner share its vertex
            const at = try b.point(p);
            const entry = try vertex_at.getOrPut(allocator, @backingInt(at));
            if (!entry.found_existing) entry.value_ptr.* = try b.vertexAt(at);
            v[i] = entry.value_ptr.*;
        }
        for (quads, normals, 0..) |q, n, f| {
            const i = 6 * k + f;
            var order = q;
            if (spec.void) std.mem.reverse(u8, &order);
            for (0..4) |j| edges[i][j] = try b.straight(v[order[j]], v[order[(j + 1) % 4]]);
            loops[i] = .{.{ .edges = &edges[i] }};
            const out = if (spec.void) vec.neg(n) else n;
            const x = vec.normalized(vec.sub(corners[order[1]], corners[order[0]])).?;
            const facing = try b.facingPlane(geometry.Frame.init(corners[order[0]], x, out), &.{ corners[order[0]], corners[order[1]], corners[order[2]], corners[order[3]] });
            const frame = b.body.geometry.planes.items[facing.surface.index].frame;
            var uv = geometry.Box2.empty;
            for (order) |c| {
                const l = frame.toLocal(corners[c]);
                uv.grow(.{ l[0], l[1] });
            }
            faces[i] = .{ .surface = facing.surface, .same_sense = facing.same_sense, .loops = &loops[i], .uv_box = uv };
        }
    }
    _ = try sew.sew(&b.body, faces, .outer);
    var shells = traverse.Shells.init(&b.body);
    while (try shells.next()) |s| {
        if (try integrals.shellSense(&b.body, s, .{}, &diag) < 0) b.body.shell(s).kind = .void;
    }
    return b.body;
}

/// Every rule of the checker passes `body`.
fn expectChecked(body: *const Body) !void {
    var report = try check.run(testing.allocator, body, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| std.debug.print("checker: {f}\n", .{f});
    try testing.expect(report.ok());
}

fn expectSound(body: *const Body) !void {
    try expectChecked(body);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    overlap.check(testing.allocator, body, .{}, &diag) catch |e| {
        if (diag.first()) |f| std.debug.print("overlap: {f}\n", .{f});
        return e;
    };
}

/// The checker passes `body`, the overlap rules fail it with `code` on an entity of `kind`.
fn expectOverlap(body: *const Body, code: diagnostics.Code, kind: diagnostics.EntityKind) !diagnostics.Finding {
    try expectChecked(body);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.NotValid, overlap.check(testing.allocator, body, .{}, &diag));
    const f = diag.first().?;
    try testing.expectEqual(code, f.code);
    try testing.expectEqual(kind, f.entity.kind);
    return f;
}

test "overlap: sound solids pass, a box, a box with a void, a solid in another's void, prisms touching along a line" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 1, 2, 3, false, &diag);
    defer box.deinit();
    try expectSound(&box);
    var hollow = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 4, 4, 4 } }, .{ .lo = .{ 1, 1, 1 }, .hi = .{ 3, 3, 3 }, .void = true } });
    defer hollow.deinit();
    try testing.expectEqual(@as(usize, 2), hollow.counts().shells);
    try expectSound(&hollow);
    // A box in the void of a hollow box, with a void of its own
    var nested = try boxes(testing.allocator, &.{
        .{ .lo = .{ 0, 0, 0 }, .hi = .{ 10, 10, 10 } },
        .{ .lo = .{ 1, 1, 1 }, .hi = .{ 9, 9, 9 }, .void = true },
        .{ .lo = .{ 2, 2, 2 }, .hi = .{ 8, 8, 8 } },
        .{ .lo = .{ 3, 3, 3 }, .hi = .{ 7, 7, 7 }, .void = true },
    });
    defer nested.deinit();
    try expectSound(&nested);
    // The bow tie's prisms: two solids, an edge each on the line they touch along, their
    // diagonal sides two faces in one plane meeting there
    var bow = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 2, 2 }, .{ 2, 0 }, .{ 0, 2 } }, &diag);
    defer bow.deinit();
    var prism = try sweep.extrude(testing.allocator, &bow, .{ 0, 0, 3 }, .{}, &diag);
    defer prism.deinit();
    try testing.expectEqual(@as(usize, 2), prism.counts().shells);
    try expectSound(&prism);
    // Two boxes touching along an edge line, apart elsewhere
    var corner = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } }, .{ .lo = .{ 1, 1, 0.25 }, .hi = .{ 2, 2, 0.75 } } });
    defer corner.deinit();
    try expectSound(&corner);
}

test "overlap: a shell folded through itself crosses its own faces, which no rule of the checker sees" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // A unit cube whose top is a pyramid with its apex pushed down through the bottom
    const points = [_]Vec3{
        .{ 0, 0, 0 },        .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 },
        .{ 0, 0, 1 },        .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 },
        .{ 0.5, 0.5, -0.5 },
    };
    const triangles = [_][3]u32{
        .{ 0, 2, 1 }, .{ 0, 3, 2 }, // bottom
        .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 1, 2, 6 }, .{ 1, 6, 5 }, // front, right
        .{ 2, 3, 7 }, .{ 2, 7, 6 }, .{ 3, 0, 4 }, .{ 3, 4, 7 }, // back, left
        .{ 4, 5, 8 }, .{ 5, 6, 8 }, .{ 6, 7, 8 }, .{ 7, 4, 8 }, // the roof, inverted
    };
    // The rules see it, and polyhedron, which takes a host's triangles, runs them on what it
    // made: the roof crosses the bottom on the bottom's diagonal edge, two features 0
    // apart, so the rules run where features come nearer than the minimum feature size
    // refuse it (`below_feature_size`, the face they found named); a crossing far from
    // every feature the polyhedron leaves to the caller, as OCCT's makers do
    try testing.expectError(error.Degenerate, primitives.polyhedron(testing.allocator, tol, &points, &triangles, &diag));
    try testing.expectEqual(.below_feature_size, diag.first().?.code);
    try testing.expectEqual(.face, diag.first().?.entity.kind);
}

test "overlap: two solids crossing, and two lying on each other over part of a face" {
    var crossing = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 2, 2, 2 } }, .{ .lo = .{ 1, 1, 1 }, .hi = .{ 3, 3, 3 } } });
    defer crossing.deinit();
    _ = try expectOverlap(&crossing, .faces_intersect, .face);
    // Side by side, the second slid half a unit along y: the faces on x = 1 cover a region
    // together (and the second's side at y = 0.5 meets the first's face inside it)
    var lying = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } }, .{ .lo = .{ 1, 0.5, 0 }, .hi = .{ 2, 1.5, 1 } } });
    defer lying.deinit();
    _ = try expectOverlap(&lying, .faces_intersect, .face);
    // Stacked exactly, sharing a whole face but no edge record: the two faces on z = 1
    var stacked = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } }, .{ .lo = .{ 0.25, 0.25, 1 }, .hi = .{ 0.75, 0.75, 2 } } });
    defer stacked.deinit();
    _ = try expectOverlap(&stacked, .faces_intersect, .face);
}

test "overlap: a solid inside another, a void outside every solid, a void inside a void" {
    var inside = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 4, 4, 4 } }, .{ .lo = .{ 1, 1, 1 }, .hi = .{ 2, 2, 2 } } });
    defer inside.deinit();
    var f = try expectOverlap(&inside, .shell_overlaps, .shell);
    try testing.expectEqual(@as(f64, 1), f.measured);
    try testing.expectEqual(@as(f64, 0), f.threshold);
    var outside = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } }, .{ .lo = .{ 3, 0, 0 }, .hi = .{ 4, 1, 1 }, .void = true } });
    defer outside.deinit();
    f = try expectOverlap(&outside, .shell_overlaps, .shell);
    try testing.expectEqual(@as(f64, 0), f.measured);
    try testing.expectEqual(@as(f64, 1), f.threshold);
    var twice = try boxes(testing.allocator, &.{
        .{ .lo = .{ 0, 0, 0 }, .hi = .{ 10, 10, 10 } },
        .{ .lo = .{ 1, 1, 1 }, .hi = .{ 9, 9, 9 }, .void = true },
        .{ .lo = .{ 2, 2, 2 }, .hi = .{ 8, 8, 8 }, .void = true },
    });
    defer twice.deinit();
    _ = try expectOverlap(&twice, .shell_overlaps, .shell);
}

test "overlap: a shell's winding number is 1 inside a solid, −1 in a void's cavity, 0 outside, a half on a face" {
    var hollow = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 4, 4, 4 } }, .{ .lo = .{ 1, 1, 1 }, .hi = .{ 3, 3, 3 }, .void = true } });
    defer hollow.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var shells: [2]types.ShellIndex = undefined;
    var it = traverse.Shells.init(&hollow);
    var n: usize = 0;
    while (try it.next()) |s| : (n += 1) shells[n] = s;
    const outer = if (hollow.shell(shells[0]).kind == .outer) shells[0] else shells[1];
    const cavity = if (outer == shells[0]) shells[1] else shells[0];
    var triangles = try overlap.FaceTriangles.build(testing.allocator, &hollow, &shells, &diag);
    defer triangles.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f64, 1), try overlap.winding(&hollow, &triangles, outer, .{ 2, 2, 2 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), try overlap.winding(&hollow, &triangles, cavity, .{ 2, 2, 2 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), try overlap.winding(&hollow, &triangles, cavity, .{ 0.5, 0.5, 0.5 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), try overlap.winding(&hollow, &triangles, outer, .{ 5, 2, 2 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), try overlap.winding(&hollow, &triangles, outer, .{ 4, 2, 2 }, &diag), 1e-12);
}

test "overlap: a face whose loop crosses itself has no triangles for the winding number, named" {
    // A bow tie: the unit square's corners taken across, its sides crossing at the middle
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.Builder.init(testing.allocator, tol, .sheet, &diag);
    defer b.deinit();
    defer b.body.deinit();
    const corners = [4]Vec3{ .{ 0, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    var v: [4]types.VertexIndex = undefined;
    for (corners, 0..) |p, i| v[i] = try b.vertexAt(try b.point(p));
    var edges: [4]sew.EdgeSpec = undefined;
    for (0..4) |i| edges[i] = try b.straight(v[i], v[(i + 1) % 4]);
    const loops = [1]sew.LoopSpec{.{ .edges = &edges }};
    const facing = try b.facingPlane(geometry.Frame.init(corners[0], vec.X3, vec.Z3), &corners);
    const faces = [1]sew.FaceSpec{.{ .surface = facing.surface, .same_sense = facing.same_sense, .loops = &loops, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 1, 1 } } }};
    const sheet = try sew.sew(&b.body, &faces, .sheet);
    try testing.expectError(error.NotValid, overlap.FaceTriangles.build(testing.allocator, &b.body, &.{sheet}, &diag));
    try testing.expectEqual(diagnostics.Code.not_simple, diag.first().?.code);
    try testing.expectEqual(diagnostics.EntityKind.face, diag.first().?.entity.kind);
}

test "overlap: faces meeting at a merged vertex touch within its gap, its edges reaching as far as their ends' gaps" {
    // A box and a plate 1.95e-4 apart at an intersection tolerance of 2e-4 (the plate's
    // zone 1e-4), their left faces 2.05e-4 apart, united as the boolean did until it
    // refused them (2026-11-14, the merged crossing in an edge's end strip), as placed and
    // moved whole far out. A vertex merged between them has a gap of 9.75e-5: the box's
    // top edge from it lies in the plate's left plane within the tolerance and that gap,
    // and the rule measured its far end against the plate's left face's boundary with the
    // tolerance alone (2.27e-4, not near); moved, a face's edge from the vertex lies in
    // its neighbour's plane by the vertex's gap, and the rule did not give the vertex's
    // own end that gap
    for ([_][]const u8{ @embedFile("../fixtures/strip_union.json"), @embedFile("../fixtures/strip_union_moved.json") }) |text| {
        var body = try @import("../io/body_json.zig").load(testing.allocator, text);
        defer body.deinit();
        try expectSound(&body);
    }
}

test "overlap: two voids of one solid sharing a corner are a pinch; two solids sharing one pass" {
    // research/manifold-parity.md (2026-11-14): shells of one solid touch nowhere
    var voids = try boxes(testing.allocator, &.{
        .{ .lo = .{ 0, 0, 0 }, .hi = .{ 6, 6, 6 } },
        .{ .lo = .{ 1, 1, 1 }, .hi = .{ 3, 3, 3 }, .void = true },
        .{ .lo = .{ 3, 3, 3 }, .hi = .{ 5, 5, 5 }, .void = true },
    });
    defer voids.deinit();
    try expectChecked(&voids);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, overlap.check(testing.allocator, &voids, .{}, &diag));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    try testing.expectEqual(diagnostics.EntityKind.shell, diag.first().?.entity.kind);
    var solids = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } }, .{ .lo = .{ 1, 1, 1 }, .hi = .{ 2, 2, 2 } } });
    defer solids.deinit();
    try expectSound(&solids);
}

test "overlap: two faces of one solid back to back in one plane over a region are a pinch; facing one way, or of two solids, they lie on each other" {
    // A void whose top lies in its outer shell's top: the floor between them no thickness,
    // the solid touching itself over an area (find dr's fin, two shells); before, the two
    // faces lay on each other (`faces_intersect`), as faces of two solids still do
    var void_on_top = try boxes(testing.allocator, &.{
        .{ .lo = .{ 0, 0, 0 }, .hi = .{ 6, 6, 6 } },
        .{ .lo = .{ 1, 1, 4 }, .hi = .{ 3, 3, 6 }, .void = true },
    });
    defer void_on_top.deinit();
    try expectChecked(&void_on_top);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, overlap.check(testing.allocator, &void_on_top, .{}, &diag));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    try testing.expectEqual(diagnostics.EntityKind.shell, diag.first().?.entity.kind);
    // Two solids stacked, a face of each on the other's: back to back, of two solids
    var stacked = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 2, 2, 1 } }, .{ .lo = .{ 0.5, 0.5, 1 }, .hi = .{ 1.5, 1.5, 2 } } });
    defer stacked.deinit();
    _ = try expectOverlap(&stacked, .faces_intersect, .face);
    // Two solids one inside the other, their bottoms in one plane facing one way
    var nested = try boxes(testing.allocator, &.{ .{ .lo = .{ 0, 0, 0 }, .hi = .{ 4, 4, 4 } }, .{ .lo = .{ 1, 1, 0 }, .hi = .{ 2, 2, 1 } } });
    defer nested.deinit();
    _ = try expectOverlap(&nested, .faces_intersect, .face);
}

test "overlap: features nearer than twice the tolerance that do not meet are warned of; a box has none" {
    // research/consistent-tolerances.md, T3: the minimum feature size a boolean reaching
    // both needs is twice its reach; valid bodies may come nearer, and say so. A flat
    // tetrahedron's opposite edges 1.5e-5 apart, a plate 3e-5 thick
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // Wound outward: the lower edge's faces face down, the upper's up
    var tetra = try primitives.polyhedron(testing.allocator, tol, &.{ .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 1.5e-5 }, .{ 0, 1, 1.5e-5 } }, &.{ .{ 0, 1, 2 }, .{ 0, 3, 1 }, .{ 2, 1, 3 }, .{ 0, 2, 3 } }, &diag);
    defer tetra.deinit();
    try overlap.check(testing.allocator, &tetra, .{}, &diag);
    try testing.expectEqual(@as(usize, 1), diag.warnings());
    const w = diag.findings.items[0];
    try testing.expectEqual(diagnostics.Code.features_near, w.code);
    try testing.expectEqual(diagnostics.EntityKind.edge, w.entity.kind);
    try testing.expectApproxEqAbs(@as(f64, 1.5e-5), w.measured, 1e-12);
    diag.clear();
    var plate = try boxes(testing.allocator, &.{.{ .lo = .{ 0, 0, 0 }, .hi = .{ 10, 10, 3e-5 } }});
    defer plate.deinit();
    try overlap.check(testing.allocator, &plate, .{}, &diag);
    try testing.expectEqual(@as(usize, 1), diag.warnings());
    try testing.expectApproxEqAbs(@as(f64, 3e-5), diag.findings.items[0].measured, 1e-12);
    diag.clear();
    var box = try primitives.box(testing.allocator, tol, 1, 2, 3, false, &diag);
    defer box.deinit();
    try overlap.check(testing.allocator, &box, .{}, &diag);
    try testing.expectEqual(@as(usize, 0), diag.findings.items.len);
}

/// Fold `outline` as drawn, its narrow side first or second, turned by `quarter` quarter
/// turns about z and mirrored in x or not (turned round, so it still runs counter-
/// clockwise and the same side comes first).
fn placedOutline(outline: [4]vec.Vec2, narrow_first: bool, quarter: usize, mirrored: bool) [4]vec.Vec2 {
    const drawn: [4]vec.Vec2 = if (narrow_first) .{ outline[1], outline[2], outline[3], outline[0] } else outline;
    const order: [4]usize = if (mirrored) .{ 1, 0, 3, 2 } else .{ 0, 1, 2, 3 };
    var points: [4]vec.Vec2 = undefined;
    for (&points, order) |*p, from| {
        var q: vec.Vec2 = .{ if (mirrored) -drawn[from][0] else drawn[from][0], drawn[from][1] };
        for (0..quarter) |_| {
            const turned: vec.Vec2 = .{ -q[1], q[0] };
            q = turned;
        }
        p.* = q;
    }
    return points;
}

test "overlap: a narrow side face folded within the zone of its neighbour's edge covers no region of it, whichever face comes first, turned or mirrored" {
    // The nightly's find (2026-11-21, bu): a sheet's corner where a side 2.1e-5 long
    // leaves a long one at 64.7°, its far end 1.9e-5 over the long side's line and 9e-6
    // back along it. Extruded, the narrow side face lies in the long one's plane (both its
    // edges within the tolerance of it) and the long one does not lie in the narrow one's;
    // the overlay of the two was taken in the first face's plane, so with the narrow face
    // first the long face, flattened 64.7° into its plane, covered it (`faces_intersect`),
    // and with the long face first the narrow one was a strip within the zone of their
    // shared edge, no region. The plane that holds both decides (`planar_faces.Holder`)
    for (FOLDS) |outline| for ([_]bool{ false, true }) |narrow_first| for (0..QUARTER_TURNS) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("narrow side first {}, {d} quarter turns, mirrored {}\n", .{ narrow_first, quarter, mirrored });
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const points = placedOutline(outline, narrow_first, quarter, mirrored);
        var sheet = try primitives.polygon(testing.allocator, tol, &points, &diag);
        defer sheet.deinit();
        var prism = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, FOLD_HEIGHT }, .{}, &diag);
        defer prism.deinit();
        try expectSound(&prism);
    };
}

test "overlap: a narrow side face folded back over its neighbour past the zone is swept into no solid, refused below the feature size whichever face comes first, turned or mirrored" {
    // The folds the narrow face covers its neighbour in past the zone, in the plane that
    // holds both: features of the sheet nearer than the minimum feature size, a solid's
    // faces lying on each other over a strip wider than the zone. The sweep refuses them
    // as the boolean refuses such a result (`overlap.nearRules`); the nightly's sheet
    // (2026-11-21, bu) had one at its other corner, a side 3.8e-5 long 31.8° off its
    // neighbour, its far end 2e-5 over that neighbour's line
    for (FOLDS_PAST) |fold| for ([_]bool{ false, true }) |narrow_first| for (0..QUARTER_TURNS) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("{d}° and {e} over, narrow side first {}, {d} quarter turns, mirrored {}\n", .{ fold[0], fold[1], narrow_first, quarter, mirrored });
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const outline = [4]vec.Vec2{ .{ 0, 0 }, .{ 0.5, 0 }, .{ 0.5 - fold[1] / @tan(fold[0] * std.math.pi / 180.0), fold[1] }, .{ 0.15, 0.12 } };
        const points = placedOutline(outline, narrow_first, quarter, mirrored);
        var sheet = try primitives.polygon(testing.allocator, tol, &points, &diag);
        defer sheet.deinit();
        try testing.expectError(error.Degenerate, sweep.extrude(testing.allocator, &sheet, .{ 0, 0, FOLD_HEIGHT }, .{}, &diag));
        try testing.expectEqual(diagnostics.Code.below_feature_size, diag.first().?.code);
    };
}

test "overlap: a vertex its gap covers at its edges' lines to rounding is on its own faces by record, not at the tolerance (find eh)" {
    // Find eh (the locus_solids session on 4e969adf): a union the boolean made, whose
    // vertex lay 2.031e-5 from both edges it ends on its face, at a reach of 2.031e-5:
    // `cover.coverLine` gives a vertex off its edge's line the gap that covers the
    // distance less D27's band. The rules measured the vertex against its own face's
    // boundary and refused it there (`at_tolerance`). A vertex of a face is on it by
    // record (`planar_faces.VertexOf`): sound in place, moved far and mirrored, the corner
    // within the tolerance of its edges or covered past it
    for (CORNER_BOXES) |spec| for (CORNER_OFFSETS) |offset| {
        errdefer std.debug.print("box to {any}, corner off its edges by {e}\n", .{ spec.hi, offset });
        var body = try boxes(testing.allocator, &.{spec});
        defer body.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        for (body.vertices.items, 0..) |v, i| {
            const p = body.point(.of(i));
            if (v.tombstone or p[0] != spec.hi[0] or p[1] != spec.hi[1] or p[2] != spec.hi[2]) continue;
            // Along the diagonal, off each edge's line by √(2/3) of the move
            const by = offset * @sqrt(1.5) / @sqrt(3.0);
            body.geometry.points.items[@backingInt(v.point)] = vec.add(spec.hi, .{ by, by, by });
            // Its edges' ranges ending at its projection on their lines, as an edit of an
            // edge's ends sets them (`simplify`'s `rebase`)
            for (body.edges.items) |*e| {
                if (e.flags.tombstone) continue;
                const line = body.geometry.curve(e.curve).line;
                if (e.start == types.VertexIndex.of(i)) e.t0 = line.project(body.point(e.start));
                if (e.end == types.VertexIndex.of(i)) e.t1 = line.project(body.point(e.end));
            }
        }
        try cover.coverBody(&body, &diag);
        try expectSound(&body);
        const far = mat.Affine.translate(CORNER_FAR).compose(&mat.Affine.rotate(vec.normalized(CORNER_TURN_AXIS).?, CORNER_TURN));
        const moves = [_]mat.Affine{ far, mat.Affine.mirror(vec.X3), mat.Affine.mirror(vec.Y3), mat.Affine.mirror(vec.Z3) };
        for (moves, 0..) |move, k| {
            errdefer std.debug.print("move {d}\n", .{k});
            var moved = try transform.transform(testing.allocator, &body, &move, .{}, &diag);
            defer moved.deinit();
            try expectSound(&moved);
        }
    };
}

/// The sheet in z = 0 with the V notch whose apex is `apex` over the x axis, and the sheet
/// in y = 0 with the notch up from its bottom (`NOTCH_APEX`), each mirrored in x = 0 when
/// `mirrored` and moved by `shift`.
fn notchedSheets(apex: f64, mirrored: bool, shift: Vec3, diag: *Diagnostics) ![2]Body {
    const level = [_]vec.Vec2{ .{ 0, -5 }, .{ 10, -5 }, .{ 10, 5 }, .{ 5.5, 5 }, .{ 5, apex }, .{ 4.5, 5 }, .{ 0, 5 } };
    const upright = [_]vec.Vec2{ .{ -1, -1 }, .{ 4, -1 }, .{ 4, 0.5 }, .{ 6, 0.5 }, .{ 6, -1 }, .{ 11, -1 }, .{ 11, 1 }, .{ -1, 1 } };
    // (x, y, 0) to (x, 0, y), exactly; then the mirror and the move
    const stand: mat.Affine = .{ .linear = .{ 1, 0, 0, 0, 0, 1, 0, 1, 0 } };
    var place = mat.Affine.translate(shift);
    if (mirrored) place = place.compose(&mat.Affine.mirror(vec.X3));
    var sheets: [2]Body = undefined;
    for ([2][]const vec.Vec2{ &level, &upright }, [2]mat.Affine{ place, place.compose(&stand) }, &sheets, 0..) |points, map, *sheet, k| {
        var drawn = try primitives.polygon(testing.allocator, tol, points, diag);
        defer drawn.deinit();
        sheet.* = transform.transform(testing.allocator, &drawn, &map, .{}, diag) catch |err| {
            if (k == 1) sheets[0].deinit();
            return err;
        };
    }
    return sheets;
}

test "overlap: two faces' shared pieces are found alike whichever face comes first, a gap's middle at one's boundary to rounding and outside the other" {
    // The audit of order and frame, 2026-11-27: `planar_faces.meet` judged a gap between
    // two marks on the faces' line by its middle in the first face, then in the second;
    // the middle the tolerance to rounding from the first's boundary (the V's apex) was
    // refused (`at_tolerance`) though it lies clearly outside the second (in its notch),
    // which settles it whatever the first says, and the other way round the pieces were
    // found. Both faces are placed before either decides, as the paves' `placeInBoth`
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const planar_faces = @import("../intersect/planar_faces.zig");
    const f = types.FaceIndex.of(0);
    for (NOTCH_APEX) |apex| for ([_]bool{ false, true }) |mirrored| for (NOTCH_SHIFTS) |shift| {
        errdefer std.debug.print("apex {d} tolerances over the line, mirrored {}, moved {any}\n", .{ apex, mirrored, shift });
        var sheets = try notchedSheets(apex * tol.xsect, mirrored, shift, &diag);
        defer for (&sheets) |*sheet| sheet.deinit();
        var counts: [2]usize = undefined;
        for ([2][2]*const Body{ .{ &sheets[0], &sheets[1] }, .{ &sheets[1], &sheets[0] } }, &counts) |order, *count| {
            var pieces: std.ArrayList(planar_faces.Piece) = .empty;
            defer pieces.deinit(testing.allocator);
            const relation = try planar_faces.meet(testing.allocator, order[0], f, order[1], f, tol, &pieces, &diag);
            try testing.expect(relation == .crossing);
            count.* = pieces.items.len;
        }
        try testing.expectEqual(counts[0], counts[1]);
        try testing.expectEqual(@as(usize, 2), counts[0]);
    };
}
