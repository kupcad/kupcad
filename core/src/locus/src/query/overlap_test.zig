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
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const sew = @import("../construct/sew.zig");
const overlap = @import("overlap.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);

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
    for (specs, 0..) |spec, k| {
        const lo = spec.lo;
        const hi = spec.hi;
        const corners = [8]Vec3{
            lo,                       .{ hi[0], lo[1], lo[2] }, .{ hi[0], hi[1], lo[2] }, .{ lo[0], hi[1], lo[2] },
            .{ lo[0], lo[1], hi[2] }, .{ hi[0], lo[1], hi[2] }, hi,                       .{ lo[0], hi[1], hi[2] },
        };
        var v: [8]types.VertexIndex = undefined;
        for (corners, 0..) |p, i| v[i] = try b.vertex(p);
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
        if (try shellVolume(&b.body, s) < 0) b.body.shell(s).kind = .void;
    }
    return b.body;
}

/// The volume shell `s` encloses, by the fan of each face about its first vertex: negative
/// for a void's.
fn shellVolume(body: *const Body, s: types.ShellIndex) !f64 {
    var volume: f64 = 0;
    var faces = traverse.Faces.init(body, s);
    while (try faces.next()) |f| {
        const apex = body.point(body.coedgeStart(body.loop(body.face(f).first_loop).first));
        var loops = traverse.Loops.init(body, f);
        while (try loops.next()) |l| {
            var it = traverse.Coedges.init(body, l);
            while (try it.next()) |c| volume += vec.dot(apex, vec.cross(body.point(body.coedgeStart(c)), body.point(body.coedgeEnd(c)))) / 6.0;
        }
    }
    return volume;
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
    var folded = try primitives.polyhedron(testing.allocator, tol, &points, &triangles, &diag);
    defer folded.deinit();
    _ = try expectOverlap(&folded, .faces_intersect, .face);
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
    try testing.expectApproxEqAbs(@as(f64, 1), try overlap.winding(&hollow, outer, .{ 2, 2, 2 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), try overlap.winding(&hollow, cavity, .{ 2, 2, 2 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), try overlap.winding(&hollow, cavity, .{ 0.5, 0.5, 0.5 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), try overlap.winding(&hollow, outer, .{ 5, 2, 2 }, &diag), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), try overlap.winding(&hollow, outer, .{ 4, 2, 2 }, &diag), 1e-12);
}

test "overlap: a boolean's faces meeting at a merged vertex touch within its gap" {
    // The solids fuzzer's find (2026-11-14): a box's top and a plate's bottom 1.95e-4 apart
    // at an intersection tolerance of 2e-4 (the plate's zone 1e-4), their left faces
    // 2.05e-4 apart. The union merges the plate's bottom edge's crossing of the box's front
    // with the box's top edge, a vertex with a gap of 9.75e-5 midway; the box's top edge
    // from it lies in the plate's left plane within the tolerance and that gap, and the
    // rule found its far end 2.27e-4 from the plate's left face's boundary, measured with
    // the tolerance alone
    const pipeline = @import("../boolean/pipeline.zig");
    const transform = @import("../construct/transform.zig");
    const Affine = @import("../math/mat.zig").Affine;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var unit = try primitives.box(testing.allocator, tol, 2, 1, 2, false, &diag);
    defer unit.deinit();
    var box = try transform.transform(testing.allocator, &unit, &Affine.translate(.{ 2 - 5e-6, 2, -5e-6 }), .{}, &diag);
    defer box.deinit();
    var slab = try primitives.box(testing.allocator, Tolerance.fromZone(1e-4), 50, 150, 2, false, &diag);
    defer slab.deinit();
    var plate = try transform.transform(testing.allocator, &slab, &Affine.translate(.{ 2 + 1.9999999855049283e-4, -48 + 1e-4, 2 - 2.000000014495072e-4 }), .{}, &diag);
    defer plate.deinit();
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    var both = try pipeline.boolean(testing.allocator, &box, &plate, .@"union", .{}, &diag, &report);
    defer both.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1.95e-4), report.max_gap, 1e-11);
    try expectSound(&both);
}
