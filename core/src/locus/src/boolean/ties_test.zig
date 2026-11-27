//! The tests of the boolean's ties (D28): a choice between candidates that measure alike,
//! to rounding or exactly, is made by what does not change when the operands are swapped
//! or the solids are moved whole together, so a boolean and the same boolean the other way
//! round, or moved, make the same solid or refuse it alike.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const transform = @import("../construct/transform.zig");
const traverse = @import("../topology/traverse.zig");
const types = @import("../topology/types.zig");
const pipeline = @import("pipeline.zig");
const helpers = @import("pipeline_test.zig");
const degeneracy = @import("degeneracy_test.zig");
const hull_mod = @import("../construct/hull.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

/// The rigid moves the tests take two solids through together: in place, turns about the
/// axes and skew axes the solids fuzzer turns about (0.3, a quarter, an eighth, a hair),
/// and shifts out to where the coordinates' rounding is a thousand times the origin's.
const MOVES = [_]struct { axis: Vec3, angle: f64, shift: Vec3 }{
    .{ .axis = vec.Z3, .angle = 0, .shift = vec.ZERO3 },
    .{ .axis = vec.X3, .angle = 0.3, .shift = .{ 0.5, -1, 2 } },
    .{ .axis = .{ 1, 2, 3 }, .angle = std.math.pi / 4.0, .shift = vec.ZERO3 },
    .{ .axis = .{ 1, 2, 3 }, .angle = 0.3, .shift = .{ 1e3, -2e3, 500 } },
    .{ .axis = vec.X3, .angle = 1e-6, .shift = vec.ZERO3 },
    .{ .axis = .{ 1, 2, 3 }, .angle = std.math.pi / 2.0, .shift = .{ 0.5, -1, 2 } },
    .{ .axis = .{ 3, -1, 2 }, .angle = 1.1, .shift = vec.ZERO3 },
    .{ .axis = .{ 0, 1, 0 }, .angle = 2.0, .shift = vec.ZERO3 },
    .{ .axis = .{ -2, 1, 1 }, .angle = 0.7, .shift = .{ 1e3, -2e3, 500 } },
};
/// `MOVES` and the solids fuzzer's own far moves, out to 3e5, where D27's band at the
/// coordinates (64 ulps of them, 4e-9) is ten thousand times the origin's: a difference
/// below it there and above it in place is a tie in one place only.
const FAR_MOVES = MOVES ++ [_]@TypeOf(MOVES[0]){
    .{ .axis = .{ 1, 2, 3 }, .angle = 0.014142253476507214, .shift = .{ 1e5, -2e5, 3e5 } },
    .{ .axis = .{ 1, 2, 3 }, .angle = std.math.pi / 4.0, .shift = .{ 1e5, -2e5, 3e5 } },
    .{ .axis = vec.X3, .angle = 0.3, .shift = .{ -3e5, 1e5, 2e5 } },
};
const OPS = [_]pipeline.Op{ .@"union", .intersection, .difference };
/// How far a point of one result may lie from its counterpart in the same result moved
/// whole and moved back, or made the other way round: the rounding of coordinates up to
/// 2e3 and back (a vertex or an edge moved by a tie the tests look for, 1e-5 to 1e-4, is
/// ten thousand times this or more).
const SAME_POINT: f64 = 1e-9;

/// The hull and the box of the tests of two merged vertices at one position along two
/// faces' line (the locus fuzzer's be, 2026-11-19, reduced to a box): the hull's bottom
/// edge 1e-5 under the box's bottom face, the box's bottom edge 1.4e-5 off the hull's side,
/// their ends at the box's side 3.2e-5 apart across the line.
const BE_HULL = [_]Vec3{ .{ 3, 1, 4 }, .{ 3, 3, 2 }, .{ 0, 3, 0 }, .{ 4, 4, 1 }, .{ 1, 3, 0 } };
const BE_HULL_NUDGE: Vec3 = .{ -2.000000005684342e-5, -1e-5, -1.9999999943156583e-5 };
const BE_BOX = [2]Vec3{ .{ -1.748, 2.00002, -1e-5 }, .{ 0.0020299999999999745, 3.00002, 0.99999 } };

/// The solids of the tests of a shell's probe point at a face's reach to rounding (the
/// audit of order and frame, 2026-11-27; the edge matrix's families "ridge in a face" and
/// "solids touching along a line" run mirrored and swapped): the result's overlap rules
/// count each shell at a point of one of its faces, the centroid of a triangle of it, which
/// a mirror's triangulation or the other operand order's numbering moves. A plate (zone
/// `PROBE_ZONE`) and a wedge on its face y = 0, turned `PROBE_RIDGE_TURNS` about its ridge
/// and lifted `PROBE_RIDGE_LIFTS` intersection tolerances off the face; two boxes touching
/// along x = y = 1 and a box turned 3π/4 about that line, `PROBE_CUTTER_OFFS` tolerances
/// off it, at the zones `PROBE_CUTTER_ZONES`.
const PROBE_ZONE: f64 = 1e-5;
const PROBE_PLATE = [2]Vec3{ .{ -5, -2, -1 }, .{ 5, 0, 3 } };
const PROBE_RIDGE_TURNS = [_]f64{ 1e-5, -1e-5 };
const PROBE_RIDGE_LIFTS = [_]f64{ 0, 0.5 };
const PROBE_CUTTER_TURN: f64 = 3.0 * std.math.pi / 4.0;
const PROBE_CUTTER_OFFS = [_]f64{ 1.5, -1.5 };
const PROBE_CUTTER_ZONES = [_]f64{ 1e-5, 1e-4 };

/// How far the box's side (x) and its bottom edge's line (y) are moved in the family about
/// be: the two ends across the faces' line 3.2e-5 apart in the find, closer and farther by
/// half a zone and a zone.
const BE_SHIFTS = [_]f64{ -1e-5, 0, 1e-5 };

/// The solids of the tests of two merged vertices nearly at one position along two faces'
/// line, the one across from the other (the ReleaseSafe session's cx, 2026-11-22): a hull
/// whose corner lies in a thin plate's thickness, and the plate, 2.1 intersection
/// tolerances thick, as the solids fuzzer drew them (a plate with a gap, turned a hair
/// about an axis through the grid's middle). The hull's edge down from the corner crosses
/// the plate's edge 2.7e-5 across the faces' line from the corner and 7e-10 along it.
const CX_HULL = [_]Vec3{ .{ 1, 0, 0 }, .{ 4, 0, 2 }, .{ 2, 2, 2 }, .{ 1, 2, 1 }, .{ 2, 3, 0 }, .{ 0, 1, 4 } };
const CX_HULL_MOVE: Vec3 = .{ 0.00001, 0, 1 };
const CX_HULL_NUDGE: Vec3 = .{ -1.9999999928945728e-5, -2.0000000071054275e-5, 0 };
const CX_PLATE = [2]Vec3{ .{ 0, 0, 4 }, .{ 2, 3, 4 } };
/// Half the plate's thickness: 2.1 intersection tolerances at zone 1e-5.
const CX_PLATE_HALF: f64 = 2.1 * 2e-5 / 2.0;
const CX_PLATE_AXIS: Vec3 = .{ 1, 2, 3 };
const CX_PLATE_MIDDLE: Vec3 = .{ 2, 2, 2 };
const CX_PLATE_MOVE: Vec3 = .{ 0.5, -1, -1 };
/// The plate's turns in the family: a tenth of the find's (the two 1e-10 apart along the
/// line, above D27's band in place and under it far out), the find's (7e-10), and ten
/// times it (1e-8, a tie at no placement). Unturned, the hull's corner is the tolerance
/// from the plate's side to D27's band, the fuzzer's nudge, refused in place and made once
/// a turn's rounding takes it past the band, which no tie rule decides.
const CX_PLATE_TURNS = [_]f64{ 1e-7, 1e-6, 1e-5 };
/// The hull lifted in z in the family: the find's, and half a zone, the two farther across.
const CX_HULL_LIFTS = [_]f64{ 0, 5e-6 };

/// The solids of the tests of a face within the tolerance of a knife pair's two faces only
/// along a line (the audit of fixed numbers, 2026-11-22): a flat tetrahedron whose bottom
/// and top meet at 6e-5 rad along its edge on the x axis, and a box beside it, its top in
/// the bottom's plane (or `KNIFE_DROPS` under it) and its top's edge along the knife edge
/// (or `KNIFE_OVERS` past it, under the tetrahedron, or short of it).
const KNIFE_TETRAHEDRON = [_]Vec3{ .{ 0, 0, 0 }, .{ 4, 0, 0 }, .{ 2, 4, 0 }, .{ 2, 4, 2.4e-4 } };
const KNIFE_BOX = [2]Vec3{ .{ 0, -2, -1 }, .{ 4, 0, 0 } };
const KNIFE_DROPS = [_]f64{ 0, 5e-6 };
/// How far the box's top runs past the knife edge: on it, where the footprints only touch
/// (made), ten zones under the tetrahedron (within the tolerance of both its faces over a
/// strip that wide: refused), and ten zones short of it (made).
const KNIFE_OVERS = [_]struct { by: f64, refused: bool }{ .{ .by = 0, .refused = false }, .{ .by = 1e-4, .refused = true }, .{ .by = -1e-4, .refused = false } };
/// The flat tetrahedron with a side edge of its bottom on the y axis, and the box beside
/// it whose top's edge lies along that side edge (`KNIFE_SIDES`: on it or 5e-6 under the
/// tetrahedron, within reach of its bottom and top over a third of the edge, refused; 5e-6
/// short of it, its ends merged with the side's and the edge leaving the top's side at
/// once, made).
const KNIFE_SIDE_TETRAHEDRON = [_]Vec3{ .{ 0, 0, 0 }, .{ 4, 0, 0 }, .{ 0, 4, 0 }, .{ 0, 4, 2.4e-4 } };
const KNIFE_SIDE_BOX = [2]Vec3{ .{ -2, 0, -1 }, .{ 0, 4, 0 } };
const KNIFE_SIDES = [_]struct { by: f64, drop: f64, refused: bool }{
    .{ .by = 0, .drop = 0, .refused = true },
    .{ .by = 0, .drop = 5e-6, .refused = true },
    .{ .by = 5e-6, .drop = 0, .refused = true },
    .{ .by = 5e-6, .drop = 5e-6, .refused = true },
    .{ .by = -5e-6, .drop = 0, .refused = false },
};
/// The plates of find dp (the oracle extensions' first sessions on 05c27278, locus_solids),
/// as the fuzzer placed them at a zone of 1e-4 (`helpers.fuzzPlaced`: size, lower corner,
/// turn about z, move, nudge): two joined, the second turned 0.3 and its top 2e-4 over
/// the first's, then less a third whose top is a zone under the first's; and the third's
/// drops (the find's 1e-4, the zone's half, the intersection tolerance's three quarters).
const DP_ZONE: f64 = 1e-4;
const DP_FIRST = .{ .size = Vec3{ 50, 150, 4 }, .lo = Vec3{ 52, -48, 0 }, .turn = 0.0, .move = Vec3{ 0, 0, 0 }, .nudge = Vec3{ -2.000000014495072e-4, -1.9999999855049283e-4, 0 } };
const DP_SECOND = .{ .size = Vec3{ 150, 50, 1 }, .lo = Vec3{ -98, 52, 3 }, .turn = 0.3, .move = Vec3{ 0, -0.5, 0 }, .nudge = Vec3{ 1.9999999825084743e-4, 0, 1.9999999825084743e-4 } };
const DP_THIRD = .{ .size = Vec3{ 100, 100, 2 }, .lo = Vec3{ 2, 2, 2 }, .turn = 0.0, .move = Vec3{ 0, 0, 0 }, .nudge = Vec3{ 2e-2, -1.9999999855049283e-4, 0 } };
const DP_DROPS = [_]f64{ 1e-4, 5e-5, 1.5e-4 };

/// What a boolean of two solids gives: a refusal's code, or the made solid's counts, its
/// shells' kinds and its points (each vertex; each edge's curve at the middle of its range,
/// which a joined edge's line decides; each planar face's corners' centroid on its plane,
/// which the plane a group of faces takes decides, its vertices staying within their
/// gaps of it), moved back by the move the operands took, the solid checked sound.
/// The solids of find du (the solids sessions on 9015ab26), as the fuzzer drew them: a box
/// at the zone the chain's plate left it (1e-4) and a hull turned 0.01414 rad about
/// (1, 2, 3), whose base lies 0.0085 rad off the box's top, a corner of the base 5.6e-5
/// over the top and the base's edge from it crossing the top's edge 1e-5 under it.
const DU_BOX = struct { size: Vec3 = .{ 4, 1, 1 }, lo: Vec3 = .{ 0, 3, 0 }, move: Vec3 = .{ -0.5, -1, 0 }, nudge: Vec3 = .{ 0, 0, -1.999999995026201e-5 } }{};
const DU_HULL = [_]Vec3{ .{ 4, 2, 4 }, .{ 1, 2, 1 }, .{ 2, 2, 1 }, .{ 4, 1, 1 }, .{ 0, 1, 1 } };
const DU_HULL_TURN: f64 = 0.014142253478516982;
const DU_HULL_NUDGE: Vec3 = .{ -5e-5, 2.0000000005705623e-4, 0 };

/// The box and the slab of the family about du: the slab's bottom a square `HINGE_SIDE`
/// on a side, turned 45° about z, its corner X `HINGE_CORNER`, 0.005 past the top's front
/// edge (y = 0), and its two edges from X crossing that edge; the bottom's heights over
/// the top from X's by its slopes (`HINGE_CASES`) along the edge from X to +x (the hinge,
/// X to its crossing of the top's edge, both on the top within the reach) and along the
/// other edge from X, which leaves the top's tolerance before the top's edge, so the two
/// faces share X and the hinge's crossing alone.
const HINGE_BOX = [2]Vec3{ .{ 0, 0, 0 }, .{ 4, 3, 1 } };
const HINGE_CORNER: Vec3 = .{ 2, 0.005, 1 };
const HINGE_SIDE: f64 = 1;
const HINGE_THICKNESS: f64 = 0.5;
/// Each case: X's height over the top, the bottom's slopes along the hinge (from X) and
/// along the other edge, and whether refused. The planes' heights differ either way at the
/// hinge's ends (X over, its crossing under, or the other way): they cross along it,
/// refused. One sign at both ends: the hinge holds, made; so too past the angular
/// tolerance, where the hinge's crossing is off the top and the planes meet along their
/// own line.
const HINGE_CASES = [_]struct { lift: f64, along: f64, other: f64, refused: bool }{
    .{ .lift = 1.2e-5, .along = -3.1e-3, .other = 3.1e-3, .refused = true },
    .{ .lift = -1.2e-5, .along = 3.1e-3, .other = -3.1e-3, .refused = true },
    .{ .lift = 1.2e-5, .along = -1e-3, .other = 3.1e-3, .refused = false },
    .{ .lift = 1.2e-5, .along = 0, .other = 4.4e-3, .refused = false },
    .{ .lift = 1.2e-5, .along = -HINGE_PAST_ANGLE, .other = HINGE_PAST_ANGLE, .refused = false },
};
/// The family's slope past the angular tolerance. Its crossings at 3e5 lie the
/// coordinates' rounding over the slope from their place (3e-9, past `SAME_POINT`), so it
/// is moved by `MOVES` only, out to 2e3: no tie, the measure's own rounding.
const HINGE_PAST_ANGLE: f64 = 0.02;

/// The solids of find dv (the solids sessions on 9015ab26, locus), as the fuzzer drew them
/// at a zone of 1e-5: a wall with a gap of three intersection tolerances about x = 2, from
/// (0, 1, 0) to (2, 3, 3), united with a hull, both moved down 0.5; then a box, moved down
/// 1. The hull's face and the box's bottom share the box's corner and two merged vertices
/// of the wall's, at y = 1.00002 exactly, 5.5e-5 apart across the faces' line (y).
const DV_WALL_AT: Vec3 = .{ 2, 1, 0 };
const DV_WALL = [2]Vec3{ .{ 0, 1, 0 }, .{ 2, 3, 3 } };
const DV_WALL_XSECTS: f64 = 3;
const DV_WALL_NUDGE: Vec3 = .{ 2e-5, 1.9999999957367437e-5, 0 };
const DV_HULL = [_]Vec3{ .{ 0, 1, 1 }, .{ 4, 3, 4 }, .{ 1, 3, 4 }, .{ 4, 0, 0 }, .{ 0, 4, 1 } };
const DV_HULL_NUDGE: Vec3 = .{ 1e-5, 1e-5, 0 };
const DV_MOVE: Vec3 = .{ 0, 0, -0.5 };
const DV_BOX = [2]Vec3{ .{ 2, 1, 1 }, .{ 4, 4, 3 } };
const DV_BOX_MOVE: Vec3 = .{ 0, 0, -1 };
const DV_BOX_NUDGE: Vec3 = .{ -5e-6, -5e-6, 0 };
/// The family about dv: the box shifted in x (its corner nearer the wall's two vertices
/// across the line, or farther) and in y (its corner past them along the line, or short),
/// by half a zone and a zone.
const DV_BOX_SHIFTS = [_]f64{ -1e-5, -5e-6, 0, 5e-6, 1e-5 };
/// The solids of find ef (the locus_solids session on 4e969adf), as the fuzzer drew them
/// (`helpers.fuzzPlaced`, `degeneracy.fuzzHullPlaced`): a hull whose top lies at z = 3,
/// and a box over it turned 1e-6 about y, its bottom 1.9e-5 to 2.1e-5 over the top, its
/// bottom edge along y = 4 a chord of the top between two merged vertices.
const EF_HULL = [_]Vec3{ .{ 0, 3, 3 }, .{ 3, 3, 1 }, .{ 4, 4, 3 }, .{ 3, 4, 3 } };
const EF_HULL_MOVE: Vec3 = .{ 0.5, 0.5, 0 };
const EF_BOX = struct { size: Vec3 = .{ 2, 1, 1 }, lo: Vec3 = .{ 1, 3, 3 }, turn: f64 = 1e-6, nudge: Vec3 = .{ -1.999999994315657e-5, 5e-6, 2e-5 } }{};
/// The family about ef: the box turned about its bottom edge's middle on the top
/// (`EF_PIVOT`, before the nudge) by `EF_TURNS` (radians about x, across the edge: none, a
/// hair and a ten-thousandth either way; about y, along it: the slope that takes the
/// bottom past the tolerance of the top at one end of the overlap) and lifted
/// `EF_LIFTS` over it, the edge within the tolerance of the top where it crosses it.
const EF_PIVOT: Vec3 = .{ 2, 4, 3 };
const EF_ALONG: f64 = 1e-5;
const EF_ACROSS = [_]f64{ 0, 1e-6, -1e-6, 1e-4, -1e-4 };
const EF_LIFTS = [_]f64{ 1.2e-5, 1.9e-5 };
/// The chain of find eg (the locus session on 4e969adf): a hull turned at the angular
/// tolerance about (1, 2, 3) united with a box 2e-3 under the grid, then less a second
/// box, as the fuzzer drew them (`degeneracy.fuzzHullPlaced`, `helpers.fuzzPlaced`).
const EG_HULL = [_]Vec3{ .{ 2, 3, 2 }, .{ 1, 0, 0 }, .{ 3, 3, 0 }, .{ 2, 0, 1 }, .{ 4, 1, 2 }, .{ 2, 1, 0 }, .{ 1, 1, 4 }, .{ 2, 3, 3 } };
const EG_HULL_TURN: f64 = 0.014142253478516982;
const EG_HULL_MOVE: Vec3 = .{ 0, 1, 0 };
const EG_HULL_NUDGE: Vec3 = .{ -1e-5, 0, 2.0000000057109944e-5 };
const EG_BOX = struct { size: Vec3 = .{ 1, 3, 1 }, lo: Vec3 = .{ 1, 0, 1 }, nudge: Vec3 = .{ -1.9999999957367437e-5, 5e-6, -2e-3 } }{};
const EG_CUT = struct { size: Vec3 = .{ 2, 2, 4 }, lo: Vec3 = .{ 0, 2, 0 }, move: Vec3 = .{ 0, -1, 0 }, nudge: Vec3 = .{ -1e-5, 0, -1e-5 } }{};

/// The plate and the hull corners of the tests of a block lying across its own edge (the
/// audit of the later phases, 2026-11-27: audit-8-9 A2 and A3, a short edge of the hull
/// from the plate's top, `ACROSS_OFFSETS` in from the plate's edge x = 4, z = 1, to its
/// side the same under the edge, `ACROSS_SHIFTS` along it, so the edge's two paves lie
/// across it at one place along it), and the hull's two far corners, over the plate or
/// into it.
const ACROSS_PLATE = [2]Vec3{ .{ 0, 0, 0 }, .{ 4, 4, 1 } };
const ACROSS_OFFSETS = [_]f64{ 1.6e-5, 1.9e-5 };
const ACROSS_SHIFTS = [_]f64{ -5e-6, 0, 5e-6 };
const ACROSS_FAR = [_][2]Vec3{ .{ .{ 5, 1, 2 }, .{ 5, 3, 2 } }, .{ .{ 3, 1, 0.5 }, .{ 3, 3, 0.5 } } };

const Outcome = struct {
    code: ?diagnostics.Code = null,
    counts: ?@TypeOf(@as(Body, undefined).counts()) = null,
    kinds: [2]usize = .{ 0, 0 },
    points: []Vec3 = &.{},
    /// How many of `points` are vertices, the rest edges' middles and faces' planes.
    vertices: usize = 0,

    fn of(a: *const Body, b: *const Body, op: pipeline.Op, back: ?mat.Affine) !Outcome {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var made = pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .code = diag.first().?.code };
        };
        defer made.deinit();
        var report = try check.run(testing.allocator, &made, .global);
        defer report.deinit(testing.allocator);
        if (report.first()) |f| {
            std.debug.print("the checker: {f}\n", .{f});
            return error.ResultNotValid;
        }
        var points: std.ArrayList(Vec3) = .empty;
        errdefer points.deinit(testing.allocator);
        for (made.vertices.items, 0..) |v, i| if (!v.tombstone) try points.append(testing.allocator, made.point(.of(i)));
        const vertices = points.items.len;
        for (made.edges.items) |e| if (!e.flags.tombstone) try points.append(testing.allocator, made.geometry.curve(e.curve).eval((e.t0 + e.t1) / 2));
        for (made.faces.items, 0..) |face, i| {
            if (face.flags.tombstone or face.surface.kind != .plane) continue;
            const plane = made.geometry.planes.items[face.surface.index];
            var sum = vec.ZERO3;
            var n: f64 = 0;
            var loops = traverse.Loops.init(&made, types.FaceIndex.of(i));
            while (try loops.next()) |l| {
                var it = traverse.Coedges.init(&made, l);
                while (try it.next()) |c| {
                    sum = vec.add(sum, made.point(made.coedgeStart(c)));
                    n += 1;
                }
            }
            const centroid = vec.scale(sum, 1 / n);
            try points.append(testing.allocator, vec.sub(centroid, vec.scale(plane.frame.z, plane.height(centroid))));
        }
        if (back) |m| for (points.items) |*p| {
            p.* = m.point(p.*);
        };
        return .{ .counts = made.counts(), .kinds = helpers.shellKinds(&made), .points = try points.toOwnedSlice(testing.allocator), .vertices = vertices };
    }

    fn deinit(self: Outcome) void {
        testing.allocator.free(self.points);
    }

    /// Whether `other` is this outcome: one refusal, or one solid's counts and shells, each
    /// point of either within `SAME_POINT` of one of the other's.
    fn alike(self: Outcome, other: Outcome) bool {
        return self.alikeInKind(other) and covers(self.points, other.points) and covers(other.points, self.points);
    }

    /// Whether `other` is this outcome but for where its points lie.
    fn alikeInKind(self: Outcome, other: Outcome) bool {
        return self.code == other.code and std.meta.eql(self.counts, other.counts) and std.meta.eql(self.kinds, other.kinds);
    }

    fn covers(these: []const Vec3, those: []const Vec3) bool {
        for (these) |p| {
            for (those) |q| {
                if (vec.distance(p, q) <= SAME_POINT) break;
            } else return false;
        }
        return true;
    }

    pub fn format(self: Outcome, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.code) |c| return w.print("refused {s}", .{@tagName(c)});
        try w.print("made {any}, shells {any}", .{ self.counts, self.kinds });
    }
};

/// The points of `a` farther than `SAME_POINT` from every point of `b`.
fn printUnmatched(label: []const u8, a: Outcome, b: Outcome) void {
    for (a.points, 0..) |p, i| {
        for (b.points) |q| {
            if (vec.distance(p, q) <= SAME_POINT) break;
        } else std.debug.print("    {s} {s} {any}\n", .{ label, if (i < a.vertices) "vertex" else "edge's middle or face's plane", p });
    }
}

/// `move`'s affine map.
fn affineOf(move: @TypeOf(MOVES[0])) mat.Affine {
    return mat.Affine.translate(move.shift).compose(&mat.Affine.rotate(vec.normalized(move.axis).?, move.angle));
}

/// `body` moved as `move` has it.
fn moved(body: *const Body, move: @TypeOf(MOVES[0])) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return transform.transform(testing.allocator, body, &affineOf(move), .{}, &diag);
}

/// Each operation of `a` and `b`, and of `b` and `a`, moved whole by every one of `MOVES`,
/// as it is in place: made alike, point for point, or refused with one code; the union and
/// the intersection alike in kind either way round too (made with the same counts or
/// refused alike). Every case that differs is printed before the test fails.
fn expectAlikeSwappedAndMoved(a: *const Body, b: *const Body) !void {
    return expectAlikeSwappedAndMovedBy(a, b, &MOVES);
}

/// `expectAlikeSwappedAndMoved` under `moves`, the first in place.
fn expectAlikeSwappedAndMovedBy(a: *const Body, b: *const Body, moves: []const @TypeOf(MOVES[0])) !void {
    var differing: usize = 0;
    for (OPS) |op| {
        const want = [2]Outcome{ try Outcome.of(a, b, op, null), try Outcome.of(b, a, op, null) };
        defer for (want) |w| w.deinit();
        // Either way round alike in kind; the merged vertices' points are the first
        // operand's (`pave`'s vertex–vertex, its welds), within the tolerance of the other's
        if (op != .difference and !want[0].alikeInKind(want[1])) {
            std.debug.print("{s} in place: {f} one way round, {f} the other\n", .{ @tagName(op), want[0], want[1] });
            differing += 1;
        }
        for (moves[1..], 1..) |move, k| {
            var ma = try moved(a, move);
            defer ma.deinit();
            var mb = try moved(b, move);
            defer mb.deinit();
            const back = affineOf(move).inverse().?;
            for ([2]bool{ false, true }) |swapped| {
                const got = if (swapped) try Outcome.of(&mb, &ma, op, back) else try Outcome.of(&ma, &mb, op, back);
                defer got.deinit();
                const w = want[@intFromBool(swapped)];
                if (w.alike(got)) continue;
                std.debug.print("{s}, move {d}, swapped {}: want {f}, got {f}\n", .{ @tagName(op), k, swapped, w, got });
                printUnmatched("in place only:", w, got);
                printUnmatched("moved only:", got, w);
                differing += 1;
            }
        }
    }
    try testing.expectEqual(0, differing);
}

test "ties: two merged vertices at one position along two faces' line, apart across it, pair alike swapped and moved whole" {
    // The locus fuzzer's be (2026-11-19), reduced to a box: the merged vertices on the
    // hull's side and the box's bottom, sorted along the faces' line, had two at the box's
    // side at one position, 3.2e-5 apart across the line. be's fix ordered them by their
    // coordinates, which a turn changes: moved whole the two are one position to rounding
    // only, and the line's direction, its largest component made positive, can turn over
    var hull = try degeneracy.fuzzHullPlaced(&BE_HULL, vec.Z3, 0, null, vec.ZERO3, BE_HULL_NUDGE);
    defer hull.deinit();
    var wall = try helpers.box(BE_BOX[0], BE_BOX[1]);
    defer wall.deinit();
    try expectAlikeSwappedAndMoved(&hull, &wall);
}

test "ties: the family about be, the box's side and bottom edge moved by up to a zone, alike swapped and moved whole" {
    var hull = try degeneracy.fuzzHullPlaced(&BE_HULL, vec.Z3, 0, null, vec.ZERO3, BE_HULL_NUDGE);
    defer hull.deinit();
    for (BE_SHIFTS) |dx| for (BE_SHIFTS) |dy| {
        errdefer std.debug.print("the box's side moved {e}, its bottom edge {e}\n", .{ dx, dy });
        var wall = try helpers.box(vec.add(BE_BOX[0], .{ 0, dy, 0 }), vec.add(BE_BOX[1], .{ dx, 0, 0 }));
        defer wall.deinit();
        try expectAlikeSwappedAndMoved(&hull, &wall);
    };
}

/// The boxes of the tests of two faces' planes tied by how far each moves the other's face
/// (the audit of the ties, finding 4): side by side, their tops one group, the second's
/// `SIDE_TOP_LIFT` over the first's, each keeping an area of 1, so each plane moves the
/// other's top as much.
const SIDE_A = [2]Vec3{ .{ 0, 0, 0 }, .{ 1, 1, 1 } };
const SIDE_B = [2]Vec3{ .{ 1, 0, 0 }, .{ 2, 1, 1 } };
const SIDE_TOP_LIFTS = [_]f64{ 5e-6, 1e-5, 1.5e-5 };
/// The boxes of the tests of a group's plane mirrored: overlapping, their tops one group,
/// the second's `SIDE_TOP_LIFTS` over the first's, so the inner plane (the one the group's
/// points lie farther outside of) decides; and the planes they are mirrored in.
const OVER_A = [2]Vec3{ .{ 0, 0, 0 }, .{ 2, 2, 2 } };
const OVER_B = [2]Vec3{ .{ 1, 0, 0 }, .{ 3, 2, 2 } };
const MIRROR_NORMALS = [_]Vec3{ vec.X3, vec.Y3, vec.Z3 };

test "ties: two boxes side by side, their tops a hair apart and moving each other alike, take one top swapped and moved whole" {
    for (SIDE_TOP_LIFTS) |lift| {
        errdefer std.debug.print("the second top {e} over the first\n", .{lift});
        var a = try helpers.box(SIDE_A[0], SIDE_A[1]);
        defer a.deinit();
        var b = try helpers.box(SIDE_B[0], vec.add(SIDE_B[1], .{ 0, 0, lift }));
        defer b.deinit();
        try expectAlikeSwappedAndMoved(&a, &b);
    }
}

test "ties: two overlapping boxes, their tops a hair apart, take the same top mirrored as in place" {
    // The solids oracle's mirrored replay (2026-11-26, on the replay of a find of the
    // 2026-11-13 list): a wall's top and a hull's 1.5e-5 apart were one group, and the tie
    // rule takes the inner plane by the faces' outward normals, which took a plane's
    // frame's z turned by the face's sense; a mirror leaves the frames left-handed and
    // flips the senses, so each top's outward normal pointed down and the outer plane was
    // taken, the edge along the group the other operand's line, and the intersection was
    // made mirrored and refused in place (`sliver_face`). The outward normal is the
    // surface's (`in_face.outwardNormal`), turned by the sense. The union joins the front
    // and back top edges, each a run of both boxes' lines, on the line nearest the faces
    // (`simplify.hold`, 67d08801; the least record, which the mirror's reversed loops
    // numbered the other way, kept the union out of this test until the audit of order and
    // frame, 2026-11-27)
    for (SIDE_TOP_LIFTS) |lift| {
        errdefer std.debug.print("the second top {e} over the first\n", .{lift});
        var a = try helpers.box(OVER_A[0], OVER_A[1]);
        defer a.deinit();
        var b = try helpers.box(OVER_B[0], vec.add(OVER_B[1], .{ 0, 0, lift }));
        defer b.deinit();
        try expectEveryOpAlikeMirrored(&a, &b);
        try expectEveryOpAlikeMirrored(&b, &a);
    }
}

/// The intersection and the difference of `a` and `b` mirrored in each of
/// `MIRROR_NORMALS` as they are in place: made alike, point for point, mirrored back, or
/// refused with one code. A mirror rounds nothing. Every case that differs is printed
/// before the test fails.
fn expectAlikeMirrored(a: *const Body, b: *const Body) !void {
    var differing: usize = 0;
    for ([_]pipeline.Op{ .intersection, .difference }) |op| {
        const want = try Outcome.of(a, b, op, null);
        defer want.deinit();
        for (MIRROR_NORMALS) |normal| {
            var ma = try helpers.mirrored(a, normal);
            defer ma.deinit();
            var mb = try helpers.mirrored(b, normal);
            defer mb.deinit();
            const got = try Outcome.of(&ma, &mb, op, mat.Affine.mirror(normal));
            defer got.deinit();
            if (want.alike(got)) continue;
            std.debug.print("{s}, mirrored in {any}: want {f}, got {f}\n", .{ @tagName(op), normal, want, got });
            printUnmatched("in place only:", want, got);
            printUnmatched("mirrored only:", got, want);
            differing += 1;
        }
    }
    try testing.expectEqual(0, differing);
}

/// The solids of the tests of a chain of edges on two lines within the tolerance of each
/// other (the nightly of 2026-11-16, run 43773180777): a box united with a turned hull,
/// the hull's face crossing the box's top, and a plate (zone 1e-4) whose bottom lies
/// `CHAIN_PLATE_DROPS` under that top, so the hull's face crosses the two planes along two
/// lines that far apart and the result's edge along it is a chain on both.
const CHAIN_BOX = [2]Vec3{ .{ 2, 3, 2 }, .{ 4, 4, 3 } };
const CHAIN_BOX_NUDGE: Vec3 = .{ 5e-6, 2e-5, -2e-5 };
const CHAIN_HULL = [_]Vec3{ .{ 4, 3, 2 }, .{ 4, 1, 3 }, .{ 0, 2, 2 }, .{ 0, 0, 2 }, .{ 4, 1, 1 }, .{ 1, 2, 3 }, .{ 1, 3, 0 }, .{ 4, 4, 0 } };
const CHAIN_HULL_NUDGE: Vec3 = .{ 0, 1.999999989037341e-5, -1.999999989037341e-5 };
const CHAIN_PLATE = [2]Vec3{ .{ -48, -48, 3 }, .{ 52, 102, 4 } };
const CHAIN_PLATE_NUDGE: Vec3 = .{ 2e-2, 2e-4, 0 };
const CHAIN_PLATE_DROPS = [_]f64{ 5e-5, 3e-5, 1e-5, -1e-5 };

/// The box united with the hull (`CHAIN_*`).
fn chainJoined() !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const t = Tolerance.fromZone(1e-5);
    var b0 = try helpers.boxAt(t, CHAIN_BOX[0], CHAIN_BOX[1]);
    defer b0.deinit();
    var b = try helpers.moved(&b0, CHAIN_BOX_NUDGE);
    defer b.deinit();
    var h0 = try hull_mod.hull(testing.allocator, t, &CHAIN_HULL, &diag);
    defer h0.deinit();
    var place = mat.Affine.rotateAbout(@splat(2), vec.normalized(.{ 1, 2, 3 }).?, std.math.pi);
    place = mat.Affine.scaleBy(.{ 2, 2, 1 }).compose(&place);
    place = mat.Affine.translate(CHAIN_HULL_NUDGE).compose(&place);
    var h = try transform.transform(testing.allocator, &h0, &place, .{}, &diag);
    defer h.deinit();
    return helpers.sound(&b, &h, .@"union");
}

test "ties: a chain of edges on two lines within the tolerance of each other is joined alike, swapped and moved whole" {
    var joined = try chainJoined();
    defer joined.deinit();
    for (CHAIN_PLATE_DROPS) |drop| {
        errdefer std.debug.print("the plate's bottom {e} under the box's top\n", .{drop});
        var p0 = try helpers.boxAt(Tolerance.fromZone(1e-4), CHAIN_PLATE[0], CHAIN_PLATE[1]);
        defer p0.deinit();
        var plate = try helpers.moved(&p0, vec.add(CHAIN_PLATE_NUDGE, .{ 0, 0, -drop }));
        defer plate.deinit();
        try expectAlikeSwappedAndMoved(&joined, &plate);
    }
}

/// The hull and the plate of cx's tests: the plate turned `turn`, the hull lifted `lift`,
/// both mirrored in the plane x = 0 when `mirrored`.
fn cxSolids(turn: f64, lift: f64, mirrored: bool) ![2]Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var drawn_hull = try degeneracy.fuzzHullPlaced(&CX_HULL, vec.Z3, 0, null, CX_HULL_MOVE, vec.add(CX_HULL_NUDGE, .{ 0, 0, lift }));
    defer drawn_hull.deinit();
    var drawn_plate = try helpers.box(vec.sub(CX_PLATE[0], .{ 0, 0, CX_PLATE_HALF }), vec.add(CX_PLATE[1], .{ 0, 0, CX_PLATE_HALF }));
    defer drawn_plate.deinit();
    const mirror = if (mirrored) mat.Affine.mirror(vec.X3) else mat.Affine.translate(vec.ZERO3);
    const place = mirror.compose(&mat.Affine.translate(CX_PLATE_MOVE).compose(&mat.Affine.rotateAbout(CX_PLATE_MIDDLE, vec.normalized(CX_PLATE_AXIS).?, turn)));
    var hull = try transform.transform(testing.allocator, &drawn_hull, &mirror, .{}, &diag);
    errdefer hull.deinit();
    const plate = try transform.transform(testing.allocator, &drawn_plate, &place, .{}, &diag);
    return .{ hull, plate };
}

test "ties: a corner and a merged vertex nearly at one position along two faces' line, apart across it, alike swapped and moved far" {
    // The ReleaseSafe session's cx (2026-11-22): sorted along the hull's face and the
    // plate's line, the hull's corner and the vertex where the hull's edge crosses the
    // plate's edge lay 7e-10 apart along it and 2.7e-5 across. Tied to rounding, the two
    // were two places in place (D27's band 1e-13 there) and one moved to 3e5 (4e-9), so
    // the gaps differed and the union had a sliver in place only, 27 vertices against 26.
    // Their separation lies across the line within the angle: one place, wherever they are
    var solids = try cxSolids(CX_PLATE_TURNS[1], CX_HULL_LIFTS[0], false);
    defer for (&solids) |*body| body.deinit();
    try expectAlikeSwappedAndMovedBy(&solids[0], &solids[1], &FAR_MOVES);
}

test "ties: the family about cx, the plate turned, the hull lifted, mirrored, alike swapped and moved far" {
    for (CX_PLATE_TURNS) |turn| for (CX_HULL_LIFTS) |lift| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("the plate turned {e}, the hull lifted {e}, mirrored {}\n", .{ turn, lift, mirrored });
        var solids = try cxSolids(turn, lift, mirrored);
        defer for (&solids) |*body| body.deinit();
        try expectAlikeSwappedAndMovedBy(&solids[0], &solids[1], &FAR_MOVES);
    };
}

test "ties: a box's top along a flat tetrahedron's knife edge, the footprints only touching, is made alike swapped, mirrored and moved far" {
    // The audit of fixed numbers (2026-11-22): the sandwich rule refused a face within
    // the tolerance of two faces facing apart over "a region of positive area", a clipped
    // polygon's area against 0. The box's top and the tetrahedron's two faces meet along
    // the knife edge alone: no area in place, and a sliver of the coordinates' rounding
    // moved to 3e5, positive in two of the far moves, where the same solids were refused
    // `below_feature_size`. A region is one wider than the zone
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (KNIFE_DROPS) |drop| for (KNIFE_OVERS) |over| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("the box's top {e} under the bottom's plane, {e} past the knife edge, mirrored {}\n", .{ drop, over.by, mirrored });
        var drawn_tetrahedron = try hull_mod.hull(testing.allocator, Tolerance.fromZone(1e-5), &KNIFE_TETRAHEDRON, &diag);
        defer drawn_tetrahedron.deinit();
        var drawn_box = try helpers.box(vec.sub(KNIFE_BOX[0], .{ 0, 0, drop }), vec.add(KNIFE_BOX[1], .{ 0, over.by, -drop }));
        defer drawn_box.deinit();
        const place = if (mirrored) mat.Affine.mirror(vec.X3) else mat.Affine.translate(vec.ZERO3);
        var tetrahedron = try transform.transform(testing.allocator, &drawn_tetrahedron, &place, .{}, &diag);
        defer tetrahedron.deinit();
        var box = try transform.transform(testing.allocator, &drawn_box, &place, .{}, &diag);
        defer box.deinit();
        const joined = try Outcome.of(&tetrahedron, &box, .@"union", null);
        defer joined.deinit();
        try testing.expectEqual(@as(?diagnostics.Code, if (over.refused) .below_feature_size else null), joined.code);
        try expectAlikeSwappedAndMovedBy(&tetrahedron, &box, &FAR_MOVES);
    };
}

test "ties: a box's edge along the side edge of a flat tetrahedron's bottom, within reach of its two faces, is refused alike swapped, mirrored and moved far" {
    // The audit of fixed numbers (2026-11-22): the knife rule asks over which stretch of
    // a block its feet lie in both faces of a knife pair, each triangle's side clipping
    // the stretch by the exact sign of the foot's side of it. The box's edge along the
    // bottom's side edge read 0 at both ends in place, kept, and the rounding of either
    // sign moved whole: the stretch emptied in half the far moves, and the solids refused
    // in place (`below_feature_size`) were made there. Along a side to rounding is in it
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (KNIFE_SIDES) |side| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("the box's edge {e} past the side edge, its top {e} under the bottom's plane, mirrored {}\n", .{ side.by, side.drop, mirrored });
        var drawn_tetrahedron = try hull_mod.hull(testing.allocator, Tolerance.fromZone(1e-5), &KNIFE_SIDE_TETRAHEDRON, &diag);
        defer drawn_tetrahedron.deinit();
        var drawn_box = try helpers.box(vec.sub(KNIFE_SIDE_BOX[0], .{ 0, 0, side.drop }), vec.add(KNIFE_SIDE_BOX[1], .{ side.by, 0, -side.drop }));
        defer drawn_box.deinit();
        const place = if (mirrored) mat.Affine.mirror(vec.X3) else mat.Affine.translate(vec.ZERO3);
        var tetrahedron = try transform.transform(testing.allocator, &drawn_tetrahedron, &place, .{}, &diag);
        defer tetrahedron.deinit();
        var box = try transform.transform(testing.allocator, &drawn_box, &place, .{}, &diag);
        defer box.deinit();
        const joined = try Outcome.of(&tetrahedron, &box, .@"union", null);
        defer joined.deinit();
        try testing.expectEqual(@as(?diagnostics.Code, if (side.refused) .below_feature_size else null), joined.code);
        try expectAlikeSwappedAndMovedBy(&tetrahedron, &box, &FAR_MOVES);
    };
}

/// The solids of the tests of edges crossing a face within the tolerance of one another
/// (the audit of the ties, finding 6): a tetrahedron whose apex lies `APEX_LIFTS` over a
/// box's top, its three edges from the apex crossing the top steeply at slightly
/// different angles, `APEX_SPREADS` across at its base, so their crossings lie within
/// the tolerance of one another; drawn turned `quarter` quarter turns about z through the
/// top's middle and mirrored in x there when `mirrored` (the hull numbered anew).
const APEX = [_]Vec3{ .{ 2.1, 2.05, 1 }, .{ 2.1, 2.05, -1 }, .{ 2.1, 2.05, -1 }, .{ 2.1, 2.05, -1 } };
/// The base corners' directions from under the apex, of different lengths: the edges
/// cross the top at different angles.
const APEX_SPREAD = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ -0.5, 0.8, 0 }, .{ -0.45, -0.9, 0 } };
const APEX_LIFTS = [_]f64{ 3e-5, 2.5e-5, 5e-5 };
const APEX_SPREADS = [_]f64{ 0.3, 0.5 };
const APEX_BOX = [2]Vec3{ .{ 0, 0, 0 }, .{ 4, 4, 1 } };

/// That tetrahedron lifted `lift` and spread `spread`, placed by `place`.
fn apexTetrahedron(lift: f64, spread: f64, place: *const mat.Affine) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var points: [APEX.len]Vec3 = undefined;
    for (APEX, APEX_SPREAD, &points, 0..) |p, d, *q, i| q.* = place.point(vec.add(vec.addScaled(p, d, spread), .{ 0, 0, if (i == 0) lift else 0 }));
    return hull_mod.hull(testing.allocator, Tolerance.fromZone(1e-5), &points, &diag);
}

/// `quarter` quarter turns about z through the box's top's middle, then mirrored in x
/// there when `mirrored`: the box onto itself.
fn apexPlace(quarter: usize, mirrored: bool) mat.Affine {
    const turn = mat.Affine.rotateAbout(.{ 2, 2, 0 }, vec.Z3, @as(f64, @floatFromInt(quarter)) * std.math.pi / 2.0);
    if (!mirrored) return turn;
    return mat.Affine.translate(.{ 4, 0, 0 }).compose(&mat.Affine.mirror(vec.X3).compose(&turn));
}

test "ties: a tetrahedron's edges crossing a box's top within the tolerance of one another merge at the steepest's crossing, alike turned, mirrored and swapped" {
    // The audit of the ties (finding 6): edge–face took the crossings in the operands'
    // order and the edges' numbering, and the first became the merged vertex the others
    // within the tolerance shared. The apex 3e-5 over the top, its three edges crossing
    // it 1.3e-5 apart: the intersection's apex was made at whichever came first, a hull
    // drawn turned a quarter or mirrored numbering its edges otherwise. Steepest first,
    // the least uncertain crossing, as edge–edge takes its pairs nearest first
    var box = try helpers.box(APEX_BOX[0], APEX_BOX[1]);
    defer box.deinit();
    for (APEX_LIFTS) |lift| for (APEX_SPREADS) |spread| for (OPS) |op| for ([2]bool{ false, true }) |swapped| {
        var want: ?Outcome = null;
        defer if (want) |w| w.deinit();
        for (0..4) |quarter| for ([2]bool{ false, true }) |mirrored| {
            errdefer std.debug.print("lifted {e}, spread {d}, {t}, swapped {}, {d} quarter turns, mirrored {}\n", .{ lift, spread, op, swapped, quarter, mirrored });
            const place = apexPlace(quarter, mirrored);
            var tetrahedron = try apexTetrahedron(lift, spread, &place);
            defer tetrahedron.deinit();
            const got = if (swapped) try Outcome.of(&box, &tetrahedron, op, place.inverse().?) else try Outcome.of(&tetrahedron, &box, op, place.inverse().?);
            if (want) |w| {
                defer got.deinit();
                if (!w.alike(got)) {
                    std.debug.print("want {f}, got {f}\n", .{ w, got });
                    printUnmatched("unturned only:", w, got);
                    printUnmatched("turned only:", got, w);
                    return error.TestUnexpectedResult;
                }
            } else want = got;
        };
    };
}

test "ties: the tetrahedron whose edges cross a box's top within the tolerance of one another, alike swapped and moved far" {
    var box = try helpers.box(APEX_BOX[0], APEX_BOX[1]);
    defer box.deinit();
    for ([2]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("mirrored {}\n", .{mirrored});
        var tetrahedron = try apexTetrahedron(APEX_LIFTS[0], APEX_SPREADS[0], &apexPlace(0, mirrored));
        defer tetrahedron.deinit();
        try expectAlikeSwappedAndMovedBy(&tetrahedron, &box, &FAR_MOVES);
    }
}

test "ties: a pocket's wall over a vertex a zone under the face it is cut from is placed alike mirrored (find dp)" {
    // Find dp: the union's top has a vertex a zone under its plane, and the third plate's
    // wall rises from there to 2e-4 over it. The overlap rules placed the wall's upper end
    // against the top (`in_face.placeWithin`): 3e-4 from the vertex in space, beyond the
    // reach, so by the parity of the loops, exactly at the vertex's image, where its rules
    // at a vertex read the loop's direction and the plane's axes: inside in place, and the
    // wall's edge a chord of the top, the difference refused (`pinched`); outside
    // mirrored, made. A point exactly on a straight edge's image is outside, by an exact
    // test before the parity (`ray_crossing.onSegment`). The third plate dropped by a zone
    // either side of the find too
    const t = Tolerance.fromZone(DP_ZONE);
    var first = try helpers.fuzzPlaced(t, DP_FIRST.size, DP_FIRST.lo, vec.Z3, DP_FIRST.turn, DP_FIRST.move, DP_FIRST.nudge);
    defer first.deinit();
    var second = try helpers.fuzzPlaced(t, DP_SECOND.size, DP_SECOND.lo, vec.Z3, DP_SECOND.turn, DP_SECOND.move, DP_SECOND.nudge);
    defer second.deinit();
    var joined = try helpers.sound(&first, &second, .@"union");
    defer joined.deinit();
    for (DP_DROPS) |drop| {
        errdefer std.debug.print("the third plate dropped {e}\n", .{drop});
        var third = try helpers.fuzzPlaced(t, DP_THIRD.size, DP_THIRD.lo, vec.Z3, DP_THIRD.turn, DP_THIRD.move, vec.add(DP_THIRD.nudge, .{ 0, 0, -drop }));
        defer third.deinit();
        try expectAlikeMirrored(&joined, &third);
    }
}

test "ties: a hull's base 0.0085 rad off a box's top, hinged on its edge and crossing the top along it, is refused below the feature size (find du)" {
    // Find du (the solids sessions on 9015ab26, locus_solids): the hull's base is parallel
    // to the box's top within the angular tolerance; the two share the base's corner, 5.6e-5
    // over the top, and the crossing of the base's edge from it with the top's edge, 1e-5
    // under it. The paves hinged the two along that edge, which the top kept as a slit with
    // the base and a side of the hull on it, and the result's faces about it were ordered
    // by a turn of 4e-5 rad that put the base under the top: four coedges, the union
    // NotValid. The planes cross along the hinge, refused (`pave.hingedWithin`,
    // `planar_faces.refuseCrossingParallel`)
    var box = try helpers.fuzzPlaced(Tolerance.fromZone(1e-4), DU_BOX.size, DU_BOX.lo, vec.Z3, 0, DU_BOX.move, DU_BOX.nudge);
    defer box.deinit();
    var hull = try degeneracy.fuzzHullPlaced(&DU_HULL, .{ 1, 2, 3 }, DU_HULL_TURN, null, vec.ZERO3, DU_HULL_NUDGE);
    defer hull.deinit();
    for (OPS) |op| for ([2]bool{ false, true }) |swapped| {
        errdefer std.debug.print("{t}, swapped {}\n", .{ op, swapped });
        const got = if (swapped) try Outcome.of(&hull, &box, op, null) else try Outcome.of(&box, &hull, op, null);
        defer got.deinit();
        try testing.expectEqual(@as(?diagnostics.Code, .below_feature_size), got.code);
    };
}

/// The family about du's slab (`HINGE_*`), its bottom's slopes along the hinge and along
/// the other edge from X as `case` has them.
fn hingeSlab(case: @TypeOf(HINGE_CASES[0])) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const r = HINGE_SIDE / @sqrt(2.0);
    // X, then along the hinge (+x, −y), the far corner, along the other edge (−x, −y)
    const corners = [_][2]f64{ .{ 0, 0 }, .{ r, -r }, .{ 0, -2 * r }, .{ -r, -r } };
    const slopes = [_]f64{ 0, case.along * HINGE_SIDE, (case.along + case.other) * HINGE_SIDE, case.other * HINGE_SIDE };
    var points: [2 * corners.len]Vec3 = undefined;
    for (corners, slopes, 0..) |c, rise, i| {
        const z = HINGE_CORNER[2] + case.lift + rise;
        points[i] = .{ HINGE_CORNER[0] + c[0], HINGE_CORNER[1] + c[1], z };
        points[corners.len + i] = .{ HINGE_CORNER[0] + c[0], HINGE_CORNER[1] + c[1], z + HINGE_THICKNESS };
    }
    return hull_mod.hull(testing.allocator, Tolerance.fromZone(1e-5), &points, &diag);
}

test "ties: the family about du, a slab's bottom hinged on a box's top within the angular tolerance and crossing it along the hinge refused, one side of it made, alike swapped, mirrored and moved far" {
    // The slab's corner X over the top and the hinge's crossing of the top's edge under it,
    // or the other way round: the planes cross along the hinge, refused. Both over (a
    // smaller slope along the hinge, or none), the hinge holds: the slab touches the top
    // along it, made; and past the angular tolerance, where the planes meet along their
    // own line, made
    var box = try helpers.boxAt(Tolerance.fromZone(1e-5), HINGE_BOX[0], HINGE_BOX[1]);
    defer box.deinit();
    for (HINGE_CASES) |case| {
        errdefer std.debug.print("X lifted {e}, slopes {e} along the hinge and {e} along the other edge\n", .{ case.lift, case.along, case.other });
        var slab = try hingeSlab(case);
        defer slab.deinit();
        for (OPS) |op| {
            errdefer std.debug.print("{t}\n", .{op});
            const got = try Outcome.of(&slab, &box, op, null);
            defer got.deinit();
            try testing.expectEqual(@as(?diagnostics.Code, if (case.refused) .below_feature_size else null), got.code);
        }
        try expectAlikeSwappedAndMovedBy(&slab, &box, if (case.other == HINGE_PAST_ANGLE) &MOVES else &FAR_MOVES);
        try expectAlikeMirrored(&slab, &box);
    }
}

/// The wall united with the hull of find dv (`DV_*`).
fn dvJoined() !Body {
    const t = Tolerance.fromZone(1e-5);
    var wall = try degeneracy.fuzzWallPlaced(t, DV_WALL_AT, DV_WALL[0], DV_WALL[1], DV_WALL_XSECTS, DV_MOVE, DV_WALL_NUDGE);
    defer wall.deinit();
    var hull = try degeneracy.fuzzHullPlaced(&DV_HULL, vec.Z3, 0, null, DV_MOVE, DV_HULL_NUDGE);
    defer hull.deinit();
    return helpers.sound(&wall, &hull, .@"union");
}

/// The box of find dv, shifted by `shift` from where the fuzzer drew it.
fn dvBox(shift: Vec3) !Body {
    return helpers.fuzzPlaced(Tolerance.fromZone(1e-5), vec.sub(DV_BOX[1], DV_BOX[0]), DV_BOX[0], vec.Z3, 0, DV_BOX_MOVE, vec.add(DV_BOX_NUDGE, shift));
}

test "ties: a box's corner and two merged vertices at one place along a hull's face's line with the box's bottom are joined alike mirrored (find dv)" {
    // Find dv: the hull's face and the box's bottom share the box's corner and two of the
    // wall's merged vertices at one place along their line, 5.5e-5 apart across it. Ordered
    // across by the faces' normals, the corner was joined to the farther of the two in
    // place, the three a sliver triangle and the intersection refused (`sliver_face`), and
    // to the nearer mirrored, made. A place is not ordered (`planar_faces.Along.places`):
    // every pair of the three is a piece the faces may share, the sliver theirs whichever
    // way the solids lie
    var joined = try dvJoined();
    defer joined.deinit();
    var box = try dvBox(vec.ZERO3);
    defer box.deinit();
    const got = try Outcome.of(&joined, &box, .intersection, null);
    defer got.deinit();
    try testing.expectEqual(@as(?diagnostics.Code, .sliver_face), got.code);
    try expectAlikeMirrored(&joined, &box);
    try expectAlikeSwappedAndMovedBy(&joined, &box, &FAR_MOVES);
}

test "ties: the family about dv, the box's corner moved across and along the faces' line, alike swapped, mirrored and moved far" {
    var joined = try dvJoined();
    defer joined.deinit();
    for (DV_BOX_SHIFTS) |dx| for (DV_BOX_SHIFTS) |dy| {
        errdefer std.debug.print("the box shifted ({e}, {e})\n", .{ dx, dy });
        var box = try dvBox(.{ dx, dy, 0 });
        defer box.deinit();
        try expectAlikeMirrored(&joined, &box);
        try expectAlikeSwappedAndMovedBy(&joined, &box, &FAR_MOVES);
    };
}

test "ties: a box's bottom over a hull's top within the tolerance at their edge, turned along it a hair, is ordered about the edge as its corners lie, the bottom over the top (find ef)" {
    // Find ef: the box's bottom edge is a chord of the hull's top between two merged
    // vertices, the bottom 1.9e-5 to 2.1e-5 over the top (an intersection tolerance of
    // 2e-5), turned 1e-6 along the edge and not about it. Both read outside the other by
    // their corners, and the union kept the hull's top either side of the edge, the box's
    // bottom and its side: the four faces about the edge ordered by the bottom's turn from
    // the top, 1.8e-17, which put it under the top, the box's wedge taking in the hull's
    // face: four coedges, the union NotValid. Ordered as the corners lie
    // (`pipeline.pairByWedges`), the union is two solids touching along the edge
    const t = Tolerance.fromZone(1e-5);
    var box = try helpers.fuzzPlaced(t, EF_BOX.size, EF_BOX.lo, vec.Y3, EF_BOX.turn, vec.ZERO3, EF_BOX.nudge);
    defer box.deinit();
    var hull = try degeneracy.fuzzHullPlaced(&EF_HULL, vec.Z3, 0, null, EF_HULL_MOVE, vec.ZERO3);
    defer hull.deinit();
    for ([2]bool{ false, true }) |swapped| {
        errdefer std.debug.print("swapped {}\n", .{swapped});
        const got = if (swapped) try Outcome.of(&box, &hull, .@"union", null) else try Outcome.of(&hull, &box, .@"union", null);
        defer got.deinit();
        try testing.expectEqual(@as(?diagnostics.Code, null), got.code);
        try testing.expectEqual([2]usize{ 2, 0 }, got.kinds);
    }
    try expectAlikeSwappedAndMovedBy(&hull, &box, &MOVES);
    try expectAlikeMirrored(&hull, &box);
}

/// The box of the family about ef: turned `across` about x and `EF_ALONG` about y through
/// `EF_PIVOT`, then lifted `lift` and moved by the find's nudge across.
fn efBox(across: f64, lift: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var unit = try helpers.boxAt(Tolerance.fromZone(1e-5), EF_BOX.lo, vec.add(EF_BOX.lo, EF_BOX.size));
    defer unit.deinit();
    const turn: Vec3 = .{ across, EF_ALONG, 0 };
    var place = mat.Affine.rotateAbout(EF_PIVOT, vec.normalized(turn).?, vec.length(turn));
    place = mat.Affine.translate(.{ EF_BOX.nudge[0], EF_BOX.nudge[1], lift }).compose(&place);
    return transform.transform(testing.allocator, &unit, &place, .{}, &diag);
}

test "ties: the family about ef, the box's bottom turned along and across its edge on the hull's top and lifted, made sound alike swapped, mirrored and moved far" {
    // Along the edge the bottom leaves the tolerance of the top at one end of the
    // overlap; across it the bottom turns by none, a hair either way (each read against
    // its corners, over the top), or a ten-thousandth (its far corners under the top
    // where it dips, the faces crossing, read by the turn). Before the fix the turns
    // against the corners were four coedges in the union
    var hull = try degeneracy.fuzzHullPlaced(&EF_HULL, vec.Z3, 0, null, EF_HULL_MOVE, vec.ZERO3);
    defer hull.deinit();
    for (EF_ACROSS) |across| for (EF_LIFTS) |lift| {
        errdefer std.debug.print("turned {e} across the edge, lifted {e}\n", .{ across, lift });
        var box = try efBox(across, lift);
        defer box.deinit();
        for (OPS) |op| {
            errdefer std.debug.print("{t}\n", .{op});
            const got = try Outcome.of(&hull, &box, op, null);
            defer got.deinit();
            if (got.code) |code| try testing.expect(code != .edge_coedge_count);
        }
        try expectAlikeSwappedAndMovedBy(&hull, &box, &FAR_MOVES);
        try expectAlikeMirrored(&hull, &box);
    };
}

/// The hull of find eg united with its first box.
fn egJoined() !Body {
    const t = Tolerance.fromZone(1e-5);
    var hull = try degeneracy.fuzzHullPlaced(&EG_HULL, .{ 1, 2, 3 }, EG_HULL_TURN, null, EG_HULL_MOVE, EG_HULL_NUDGE);
    defer hull.deinit();
    var box = try helpers.fuzzPlaced(t, EG_BOX.size, EG_BOX.lo, vec.Z3, 0, vec.ZERO3, EG_BOX.nudge);
    defer box.deinit();
    return helpers.sound(&hull, &box, .@"union");
}

test "ties: a hull's face at the angular tolerance to a box's top, turned from it about their edge against where its corners lie, is ordered about the edge as they lie (find eg)" {
    // Find eg: in the union of the hull and the first box, cut by the second, a face of
    // the hull and the box's top share an edge, parallel within the angular tolerance,
    // each face's corners all on one side of the other's plane, and their turn about the
    // edge, 3.7e-3, the other way. The classification read them by their corners, the
    // order about the edge by the turn: four coedges, NotValid. Ordered as the corners
    // lie (`pipeline.pairByWedges`), made
    var joined = try egJoined();
    defer joined.deinit();
    var cut = try helpers.fuzzPlaced(Tolerance.fromZone(1e-5), EG_CUT.size, EG_CUT.lo, vec.Z3, 0, EG_CUT.move, EG_CUT.nudge);
    defer cut.deinit();
    for (OPS) |op| {
        errdefer std.debug.print("{t}\n", .{op});
        const got = try Outcome.of(&joined, &cut, op, null);
        defer got.deinit();
        try testing.expectEqual(@as(?diagnostics.Code, null), got.code);
    }
    // Out to 2e3: the hull's faces at the angular tolerance to the boxes' cross them where
    // the coordinates' rounding over that slope moves the crossings past `SAME_POINT`
    // farther out (2e-9 at 3e5)
    try expectAlikeSwappedAndMovedBy(&joined, &cut, &MOVES);
    try expectAlikeMirrored(&joined, &cut);
}

/// Each operation of `a` and `b` mirrored in each of `MIRROR_NORMALS` as it is in place:
/// made alike, point for point, mirrored back, or refused with one code (`expectAlikeMirrored`
/// with the union too). Every case that differs is printed before the test fails.
fn expectEveryOpAlikeMirrored(a: *const Body, b: *const Body) !void {
    var differing: usize = 0;
    for (OPS) |op| {
        const want = try Outcome.of(a, b, op, null);
        defer want.deinit();
        for (MIRROR_NORMALS) |normal| {
            var ma = try helpers.mirrored(a, normal);
            defer ma.deinit();
            var mb = try helpers.mirrored(b, normal);
            defer mb.deinit();
            const got = try Outcome.of(&ma, &mb, op, mat.Affine.mirror(normal));
            defer got.deinit();
            if (want.alike(got)) continue;
            std.debug.print("{s}, mirrored in {any}: want {f}, got {f}\n", .{ @tagName(op), normal, want, got });
            differing += 1;
        }
    }
    try testing.expectEqual(0, differing);
}

/// Two boxes touching along the line x = y = 1, z 0..2, at `zone`, united: one body of two
/// solids (the edge matrix's `touchingPair`).
fn probeTouchingPair(zone: f64) !Body {
    var left = try helpers.boxAt(Tolerance.fromZone(zone), .{ 0, 0, 0 }, .{ 1, 1, 2 });
    defer left.deinit();
    var right = try helpers.boxAt(Tolerance.fromZone(zone), .{ 1, 1, 0 }, .{ 2, 2, 2 });
    defer right.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return pipeline.boolean(testing.allocator, &left, &right, .@"union", .{}, &diag, null);
}

/// A box whose face lies on y = 1 + `off`, turned by `PROBE_CUTTER_TURN` about the line
/// x = y = 1 (the edge matrix's `turnedCutter`).
fn probeCutter(zone: f64, off: f64) !Body {
    var b = try helpers.boxAt(Tolerance.fromZone(zone), .{ -2, -0.5 + off, -0.5 }, .{ 4, 1 + off, 2.5 });
    defer b.deinit();
    return helpers.turned(&b, .{ 1, 1, 0 }, vec.Z3, PROBE_CUTTER_TURN);
}

test "ties: a shell's probe point at a face's reach to rounding says nothing, a wedge on a plate made alike mirrored and swapped" {
    // The edge matrix run mirrored (the audit of order and frame, 2026-11-27): the union of
    // a plate and a wedge turned 1e-5 on its face was made in place and refused mirrored
    // (`at_tolerance`, "a point on a face's plane or not"): the result's overlap rules count
    // the wedge's shell at the centroid of a triangle of its first face, which the mirror's
    // triangulation put 2e-5 to rounding off the plate's face
    const x = Tolerance.fromZone(PROBE_ZONE).xsect;
    var plate = try helpers.boxAt(Tolerance.fromZone(PROBE_ZONE), PROBE_PLATE[0], PROBE_PLATE[1]);
    defer plate.deinit();
    for (PROBE_RIDGE_TURNS) |turn| for (PROBE_RIDGE_LIFTS) |lift| for ([_]bool{ false, true }) |drawn_mirrored| {
        errdefer std.debug.print("the wedge turned {e}, lifted {d} tolerances, drawn mirrored {}\n", .{ turn, lift, drawn_mirrored });
        var wedge = try degeneracy.ridgePrism(&degeneracy.RIDGE_WEDGE, turn, drawn_mirrored, lift * x);
        defer wedge.deinit();
        try expectEveryOpAlikeMirrored(&plate, &wedge);
        try expectAlikeSwappedAndMovedBy(&plate, &wedge, &FAR_MOVES);
    };
}

test "ties: a shell's probe point at a face's boundary to rounding says nothing, two solids touching along a line cut alike swapped and mirrored" {
    // The edge matrix run swapped (the audit of order and frame, 2026-11-27): two boxes
    // touching along a line, intersected with a box turned 3π/4 about it 1.5 tolerances
    // off, were refused one way round (`at_tolerance`, "a point on a face's boundary or
    // not") and made the other: the shell counted first, and its face's centroid, follow
    // the operands' order
    for (PROBE_CUTTER_ZONES) |zone| for (PROBE_CUTTER_OFFS) |off| {
        errdefer std.debug.print("zone {e}, the cutter {d} tolerances off\n", .{ zone, off });
        var pair = try probeTouchingPair(PROBE_ZONE);
        defer pair.deinit();
        var cutter = try probeCutter(zone, off * Tolerance.merge(Tolerance.fromZone(PROBE_ZONE), Tolerance.fromZone(zone)).xsect);
        defer cutter.deinit();
        try expectAlikeSwappedAndMovedBy(&pair, &cutter, &FAR_MOVES);
        try expectEveryOpAlikeMirrored(&pair, &cutter);
    };
}

test "ties: two paves of one edge across it at one place along it come only from an operand below its minimum feature size, refused alike swapped, moved and mirrored" {
    // The audit of the later phases (2026-11-27), audit-8-9 A2 and A3 and audit-3 item 5:
    // an edge's paves sorted by their place along its merged ends' chord, a block's side
    // read from its chord, a short block collapsed by `simplify` only after it was decided.
    // Two paves of the plate's edge more than the tolerance apart, both within reach of
    // the edge, are two features of the other operand within twice the reach of each other:
    // an edge's crossings with it weld into one, a crossing of an edge from a vertex there
    // is that vertex's, and any other pair is refused before the paves by the operands'
    // minimum feature size (`pipeline.featureSize`), whose limit grows with the features'
    // gaps as their reach does; only the edge's own gap, a chained operand's, reaches
    // farther than the other operand's precondition counts (the edge matrix's gapped
    // solid, clean moved, mirrored and swapped). Here the nearest such pair, a hull's
    // edge 2.3e-5 to 2.7e-5 long from the plate's top to its side across the edge: refused
    // `below_feature_size` whatever the order, move or mirror
    for (ACROSS_OFFSETS) |offset| for (ACROSS_SHIFTS) |shift| for (ACROSS_FAR) |far| {
        errdefer std.debug.print("offset {e}, shifted {e}, far corners {any}\n", .{ offset, shift, far });
        const corners = [_]Vec3{ .{ ACROSS_PLATE[1][0] - offset, 2, ACROSS_PLATE[1][2] }, .{ ACROSS_PLATE[1][0], 2 + shift, ACROSS_PLATE[1][2] - offset }, far[0], far[1] };
        var hull = try degeneracy.fuzzHullPlaced(&corners, vec.Z3, 0, null, vec.ZERO3, vec.ZERO3);
        defer hull.deinit();
        var plate = try helpers.box(ACROSS_PLATE[0], ACROSS_PLATE[1]);
        defer plate.deinit();
        for (OPS) |op| {
            const outcome = try Outcome.of(&plate, &hull, op, null);
            defer outcome.deinit();
            try testing.expectEqual(@as(?diagnostics.Code, .below_feature_size), outcome.code);
        }
        try expectAlikeSwappedAndMoved(&plate, &hull);
        try expectEveryOpAlikeMirrored(&plate, &hull);
    };
}
