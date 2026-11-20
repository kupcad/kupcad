//! The edge-case matrix (Leo, 2026-11-16): the configurations the solids fuzzer's finds
//! came from, drawn on purpose and in full. Nearly every find was two features of two
//! operands placed at a boundary of the tolerance (the reach, the minimum feature size,
//! the rounding band about either) in an orientation where one decision was made in two
//! places; the fuzzer reaches such a placement by chance, a family here walks its ladder.
//! Each family places two solids by one feature pair and steps their distance in
//! intersection tolerances (`DISTANCES`), the angle between the features (`ANGLES`) and
//! the second operand's zone (`ZONES`: equal, and ten times coarser). Every case runs the
//! fuzzer's own oracles (`oracle_test.zig`): the three operations made and sound or
//! refused by design, the identities, membership, the operands the other way round, and
//! the step under two rigid moves. A solid drawn below the minimum feature size must be
//! refused as an operand. Failures are counted and listed, family by family, so one run
//! shows them all.
//!
//! The fast tier (a ladder's values on either side of each boundary) runs with the suite;
//! `-Dedge-matrix=true` runs every value, as the nightly does.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const Affine = @import("../math/mat.zig").Affine;
const hull_mod = @import("../construct/hull.zig");
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const check = @import("../topology/check.zig");
const pipeline = @import("pipeline.zig");
const helpers = @import("pipeline_test.zig");
const oracle = @import("oracle_test.zig");
const drawn = @import("degeneracy_test.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

/// Every value of every ladder, not the fast tier's (`-Dedge-matrix=true`).
const FULL: bool = @import("test_paths").edge_matrix_full;
/// The first operand's zone; the second's is it or ten times it (`ZONES`).
const ZONE = 1e-5;
/// Distances in intersection tolerances (of the two operands' merged tolerance): the reach
/// (1) and the minimum feature size (2) straddled, 1 itself (to rounding: refused or
/// decided, never failed), and the values past them the finds sat at.
const DISTANCES = [_]f64{ 0, 0.5, 0.9, 1, 1.1, 1.25, 1.5, 1.9, 2.1, 2.5, 3 };
const FAST_DISTANCES = [_]f64{ 0.9, 1.1, 2.1 };
/// Angles between the features, in radians: none, a hair, the finds' 4e-5, the angular
/// tolerance (1 − cos 0.01414 = 1e-4) straddled, the shallow 0.007 and a plain 0.3.
const ANGLES = [_]f64{ 0, 1e-6, 4e-5, 1e-3, 0.007, 0.0141, 0.0143, 0.3 };
const FAST_ANGLES = [_]f64{ 0, 4e-5 };
/// The second operand's zone over the first's.
const ZONES = [_]f64{ 1, 10 };
const FAST_ZONES = [_]f64{10};
/// Thicknesses of a thin feature in intersection tolerances: below the minimum feature
/// size (refused as an operand) and past it.
const THICKNESSES = [_]f64{ 1.5, 1.9, 2.1, 2.5, 3 };
const FAST_THICKNESSES = [_]f64{ 1.9, 2.1 };
/// The two rigid moves each case is run under again: a plain one, and one far out and
/// turned about a skew axis.
const MOVES = [_]struct { axis: Vec3, angle: f64, shift: Vec3 }{
    .{ .axis = vec.Z3, .angle = std.math.pi / 2.0, .shift = .{ 0.5, -1, 2 } },
    .{ .axis = .{ 1, 2, 3 }, .angle = 0.3, .shift = .{ 1e3, -2e3, 500 } },
};
/// The fast tier's move: the far, turned one.
const FAST_MOVES = MOVES[1..];
/// How far from the origin a case's solids reach, at most, before a move.
const REACH = 10;
/// The walls a difference of two plates leaves, in intersection tolerances: under the
/// reach, at it, the finds' 1.25 and 2 (ar: 2.5e-4 and 4e-4 at 2e-4), and values off the
/// ladder's multiples, which meet no limit exactly (sums and halves of these do: refused at
/// the tolerance to rounding, by design)
const WALLS = [_]f64{ 0.5, 1, 1.25, 1.6, 2, 2.3, 3 };
const FAST_WALLS = [_]f64{1.25};
/// How far the second plate's top stands over the first's, in intersection tolerances:
/// within reach (one lid, merged) and past it.
const LIDS = [_]f64{ -1.1, -0.5, 0, 0.5, 0.9, 1.1 };
const FAST_LIDS = [_]f64{0.5};
/// The plates' size (ar's: 100 by 150), and how far they reach from the origin.
const PLATE: Vec3 = .{ 100, 150, 2 };
const PLATE_REACH = 200;
/// How far a face's corner lies off its own plane, in its zone (a merged vertex's gap).
const CORNER_GAPS = [_]f64{ 0, 0.5, 0.9 };
const FAST_CORNER_GAPS = [_]f64{0.9};
/// Slopes of a face crossing another within the angular tolerance (0.0141 at it).
const SLOPES = [_]f64{ 1e-3, 0.007, 0.0141 };
const FAST_SLOPES = [_]f64{0.007};

/// Heights in tolerances of a face over another in one plane with it, and in-plane
/// offsets in tolerances of an edge from a corner (find ba): together past the tolerance
/// in 3D and within it in the plane, or within both, or past both.
const HEIGHTS = [_]f64{ -0.97, -0.5, 0.5, 0.9, 0.97, 1.03 };
const FAST_HEIGHTS = [_]f64{0.97};
/// The height in tolerances over the notch's outer corner, the plate turned about y.
const OUTER = [_]f64{ 0.5, 0.9, 0.97, 1.03 };
const FAST_OUTER = [_]f64{0.9};
const OFFSETS = [_]f64{ -0.5, 0.15, 0.3, 0.5, 0.97 };
const FAST_OFFSETS = [_]f64{ 0.15, 0.3 };
/// Turns of a face about the line two solids touch along (find bb): along one solid's
/// face, into each solid's wedge, across the gaps between them.
const TURNS = [_]f64{ 0, 0.3, std.math.pi / 4.0, std.math.pi / 2.0 - 0.3, std.math.pi / 2.0, 2.0, 3 * std.math.pi / 4.0 };
const FAST_TURNS = [_]f64{ 0.3, std.math.pi / 4.0 };
/// Widths in tolerances of a narrow face, and its tilt past the angular tolerance
/// (step 2's probe, 2026-11-18): coplanar with another by distance, not by angle.
const NARROW = [_]f64{ 3, 6, 15 };
const FAST_NARROW = [_]f64{6};
const TILTS = [_]f64{ 0.003, 0.02, 0.1 };
const FAST_TILTS = [_]f64{0.02};
/// Gaps in tolerances between two boxes side by side, their tops merged or not.
const SIDE_GAPS = [_]f64{ -0.5, 0, 0.5, 1.1 };
const FAST_SIDE_GAPS = [_]f64{0.5};
const TOP_STEPS = [_]f64{ -0.9, 0, 0.5, 0.9, 1.1 };
const FAST_TOP_STEPS = [_]f64{0.9};
/// Mirrored or not; the fast tier's as drawn.
const BOTH = [_]bool{ false, true };
const FAST_BOTH = [_]bool{false};
/// Turns of a hull's top from a plate's top about a line in both (find bl), either way: a
/// hair, plain shallow ones, the angular tolerance straddled with the solids fuzzer's own
/// turn at it (1 − cos of it the tolerance less 1.4e-14), and past it.
const SHALLOW_TURNS = [_]f64{ 1e-6, 1e-3, 0.005, 0.0141, drawn.TURN_AT_ANGLE, 0.0143, 0.02 };
const FAST_SHALLOW_TURNS = [_]f64{drawn.TURN_AT_ANGLE};
/// The fast tier's heights in tolerances of that top's corners over the plate's top: the
/// find's (under it, within reach) and past the reach.
const FAST_SHALLOW_OVER = [_]f64{ -0.9, -1.1 };
/// How far in tolerances those corners lie inside the plate's side: as the fuzzer drew
/// them (null: 0.028 inside at the tolerance turn), on the side's edge, and within reach
/// of it and past it either way.
const SHALLOW_INSIDE = [_]?f64{ null, -1.1, -0.5, 0, 0.5, 1.1 };
const FAST_SHALLOW_INSIDE = [_]?f64{null};
/// The zone of the slab whose edge lies off its top's plane (finds bn and the hinge
/// window, the targeted review's lead 1: `degeneracy_test.lippedSlabTurned`), the solids
/// fuzzer's plates', and of what meets it.
const LIP_ZONE = 1e-4;
/// How far that edge lies over its top's plane, in intersection tolerances (under it when
/// negative), and the turns of the plate that cut the slab (bn's, either way, and none:
/// the top 2.7e-7 rad off level).
const LIPS = [_]f64{ 0.9, 0.5, -0.5, -0.9 };
const FAST_LIPS = [_]f64{0.9};
const LIP_TURNS = [_]f64{ 0, 1e-6, -1e-6 };
const FAST_LIP_TURNS = [_]f64{0};
/// Heights in tolerances of a face over that slab's top's plane (or its bottom's): under
/// it, in it, within the tolerance of it, between the tolerance and a merged vertex's
/// reach (the hinge window: 1.05), and past both; and heights over the edge itself, which
/// with the edge's own reach the same marks one plane further (0.15 over an edge 0.9 over
/// the plane is the window again).
const LIP_LIFTS = [_]f64{ -1.1, -0.5, 0, 0.5, 0.9, 1.05, 1.1, 1.5 };
const FAST_LIP_LIFTS = [_]f64{ 0.9, 1.1 };
const LIP_OVER_EDGE = [_]f64{ -0.5, 0, 0.15, 0.6, 0.85, 1.1, 1.25 };
const FAST_LIP_OVER_EDGE = [_]f64{0.15};
/// Offsets in tolerances across that edge, in the top's plane, of a box's side along it or
/// an upright edge through it, and of a box's corner from its end.
const LIP_ACROSS = [_]f64{ -1.5, -1.1, -0.5, 0, 0.5, 1.1, 1.5 };
const FAST_LIP_ACROSS = [_]f64{0.5};
const LIP_FROM_END = [_]f64{ -0.5, 0, 0.5 };
const FAST_LIP_FROM_END = [_]f64{0};
/// Turns of a prism's face about its ridge from the face of the other solid the ridge
/// lies in (the targeted review's lead 2, `classify.wedgeSide` and `pipeline.pairByWedges`),
/// either way: a hair, plain shallow ones, the angular tolerance straddled with the
/// fuzzer's turn at it, and past it; the turns two prisms take together; and a strip's,
/// 1e-3 wide, its far edge within the tolerance of the face (0.018 at a tolerance of
/// 2e-5) or past it.
const RIDGE_TURNS = [_]f64{ 1e-5, 1e-3, 0.005, 0.0141, drawn.TURN_AT_ANGLE, 0.0143, 0.02 };
const FAST_RIDGE_TURNS = [_]f64{drawn.TURN_AT_ANGLE};
const RIDGE_PAIR_TURNS = [_]f64{ 0, 0.005, -0.005, drawn.TURN_AT_ANGLE, -drawn.TURN_AT_ANGLE, 0.02, -0.02 };
const FAST_RIDGE_PAIR_TURNS = [_]f64{ drawn.TURN_AT_ANGLE, -drawn.TURN_AT_ANGLE };
const STRIP_TURNS = [_]f64{ 0.015, 0.018, 0.021, 0.03 };
const FAST_STRIP_TURNS = [_]f64{0.018};
/// How far the ridge is lifted off that face, in tolerances: on it, within reach either
/// way, and past it.
const RIDGE_LIFTS = [_]f64{ -1.1, -0.9, -0.5, 0, 0.5, 0.9, 1.1 };
const FAST_RIDGE_LIFTS = [_]f64{0.5};
/// The wall of find bp, the solids fuzzer's (`fuzz_test.GapShape`): a box from y and z 1
/// to 4 less a cavity `WALL_INSET` in from its faces and `WALL_DEPTH` deep, which leaves a
/// wall about the plane x = `WALL_AT`; its thicknesses in tolerances (past the minimum
/// feature size, bp's 3 among them), and its zone and the plate's.
const WALL_AT = 2;
const WALL_DEPTH = 1.5;
const WALL_INSET = 0.25;
const WALL_ZONE = 1e-4;
const WALL_GAPS = [_]f64{ 2.1, 2.5, 3, 4 };
const FAST_WALL_GAPS = [_]f64{3};
/// Where the side of the plate joined to that wall lies from the wall's middle plane, in
/// tolerances (bp's 1: inside a wall 3 thick, half a tolerance from its outer face); and
/// how far the hull that meets the two is nudged along x and z, within the tolerance and
/// clear of it (bp's 0.25 and -1).
const WALL_PLATE_SIDES = [_]f64{ -2.5, -1.6, -1.1, -0.5, 0, 0.5, 1, 1.1, 1.6, 2.5 };
const FAST_WALL_PLATE_SIDES = [_]f64{1.1};
const WALL_HULL_ALONG = [_]f64{ 0, 0.25, 1.1, 5 };
const FAST_WALL_HULL_ALONG = [_]f64{1.1};
const WALL_HULL_UP = [_]f64{ -1.1, -1, -0.5, 0, 0.5, 1.1, 5 };
const FAST_WALL_HULL_UP = [_]f64{-1.1};
/// bp's hull, as the fuzzer drew it.
const WALL_HULL = [_]Vec3{ .{ 3, 4, 2 }, .{ 2, 2, 4 }, .{ 0, 4, 4 }, .{ 3, 4, 3 }, .{ 0, 3, 0 }, .{ 1, 4, 3 }, .{ 3, 1, 2 } };

fn pick(full: []const f64, fast: []const f64) []const f64 {
    return if (FULL) full else fast;
}

fn distances() []const f64 {
    return if (FULL) &DISTANCES else &FAST_DISTANCES;
}
fn angles() []const f64 {
    return if (FULL) &ANGLES else &FAST_ANGLES;
}
fn zones() []const f64 {
    return if (FULL) &ZONES else &FAST_ZONES;
}
fn moves() []const @TypeOf(MOVES[0]) {
    return if (FULL) &MOVES else FAST_MOVES;
}
fn walls() []const f64 {
    return if (FULL) &WALLS else &FAST_WALLS;
}
fn lids() []const f64 {
    return if (FULL) &LIDS else &FAST_LIDS;
}
fn cornerGaps() []const f64 {
    return if (FULL) &CORNER_GAPS else &FAST_CORNER_GAPS;
}
fn slopes() []const f64 {
    return if (FULL) &SLOPES else &FAST_SLOPES;
}
fn thicknesses() []const f64 {
    return if (FULL) &THICKNESSES else &FAST_THICKNESSES;
}
fn both() []const bool {
    return if (FULL) &BOTH else &FAST_BOTH;
}

/// The cases of one family: how many ran, and how each ended.
const Tally = struct {
    family: []const u8,
    /// How far the family's solids reach from the origin, at most, before a move.
    reach: f64 = REACH,
    cases: usize = 0,
    made: usize = 0,
    refused: usize = 0,
    unbuilt: usize = 0,
    failed: usize = 0,
    /// The refusals by their code, printed with the full tier's summary: a refusal grown
    /// common shows which decision turns cases away
    codes: std.EnumArray(diagnostics.Code, usize) = .initFill(0),

    /// Fails the test when any case did, after the family's summary.
    fn finish(self: *const Tally) !void {
        if (FULL or self.failed > 0) {
            std.debug.print("edge matrix, {s}: {d} cases, {d} made, {d} refused, {d} not built, {d} failed\n", .{ self.family, self.cases, self.made, self.refused, self.unbuilt, self.failed });
            for (std.enums.values(diagnostics.Code)) |code| if (self.codes.get(code) > 0) std.debug.print("  refused {t}: {d}\n", .{ code, self.codes.get(code) });
        }
        if (self.failed > 0) return error.EdgeMatrixFailed;
    }
};

const Outcome = union(enum) { made, refused: diagnostics.Code };

/// One case: `a` and `b` (null when either could not be built: a construction refusing a
/// solid is no case), `thin` when one is drawn below the minimum feature size. Its
/// failure is counted and printed with `name`, never returned.
fn run(tally: *Tally, name: []const u8, a: anyerror!Body, b: anyerror!Body, thin: bool) !void {
    tally.cases += 1;
    var first = a catch |err| {
        // The second was built already
        if (b) |built| {
            var second = built;
            second.deinit();
        } else |_| {}
        if (err == error.OutOfMemory) return err;
        tally.unbuilt += 1;
        return;
    };
    defer first.deinit();
    var second = b catch |err| {
        if (err == error.OutOfMemory) return err;
        tally.unbuilt += 1;
        return;
    };
    defer second.deinit();
    const outcome = step(&first, &second, thin, tally.reach) catch |err| {
        if (err == error.OutOfMemory) return err;
        tally.failed += 1;
        std.debug.print("edge matrix FAILED, {s}: {s}: {t}\n", .{ tally.family, name, err });
        return;
    };
    switch (outcome) {
        .made => tally.made += 1,
        .refused => |code| {
            tally.refused += 1;
            tally.codes.getPtr(code).* += 1;
        },
    }
}

/// The fuzzer's step on `a` and `b`, then the step under each of `MOVES`.
fn step(a: *const Body, b: *const Body, thin: bool, reach: f64) !Outcome {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var results: [3]Body = undefined;
    var shifts: [3]f64 = undefined;
    var gaps: [3]f64 = undefined;
    var made: usize = 0;
    defer for (results[0..made]) |*r| r.deinit();
    for (oracle.OPS) |op| {
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        results[made] = pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, &report) catch |err| {
            try oracle.clean(err);
            // A solid below the minimum feature size is refused as an operand, never later
            if (thin and report.failed_in != null and report.failed_in.? != .operands) {
                std.debug.print("a solid below the minimum feature size refused at {t}, not as an operand\n", .{report.failed_in.?});
                return error.ThinOperandTaken;
            }
            return .{ .refused = if (diag.first()) |f| f.code else .unclassified };
        };
        made += 1;
        if (thin) return error.ThinOperandTaken;
        shifts[made - 1] = report.shift;
        gaps[made - 1] = report.max_gap;
        try oracle.expectSolid(&results[made - 1], &diag);
        try helpers.expectReportFits(&report, a, b, &results[made - 1], op);
    }
    try oracle.expectStep(a, b, &results, shifts, gaps, &diag);
    for (moves()) |m| {
        const move = Affine.translate(m.shift).compose(&Affine.rotate(vec.normalized(m.axis).?, m.angle));
        for (oracle.OPS, &results) |op, *result| {
            const steps = [_]oracle.Step{.{ .other = b.*, .op = op }};
            try oracle.expectMovedWhole(a, &steps, result, &move, vec.length(m.shift) + reach, &diag);
        }
    }
    return .made;
}

/// The intersection tolerance of operands at zones `ZONE` and `ZONE · ratio`.
fn xsectOf(ratio: f64) f64 {
    return Tolerance.merge(Tolerance.fromZone(ZONE), Tolerance.fromZone(ZONE * ratio)).xsect;
}

/// The box from `lo` to `hi` at `zone`, turned by `angle` about `axis` through `pivot`.
fn tiltedBox(zone: f64, lo: Vec3, hi: Vec3, pivot: Vec3, axis: Vec3, angle: f64) !Body {
    var b = try helpers.boxAt(Tolerance.fromZone(zone), lo, hi);
    if (angle == 0) return b;
    defer b.deinit();
    return helpers.turned(&b, pivot, axis, angle);
}

fn hullOf(zone: f64, points: []const Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return hull_mod.hull(testing.allocator, Tolerance.fromZone(zone), points, &diag);
}

/// The signed ladder: each distance below and above (0 once).
fn signedLadder(buffer: []f64) []const f64 {
    var n: usize = 0;
    for (distances()) |d| {
        buffer[n] = d;
        n += 1;
        if (d == 0) continue;
        buffer[n] = -d;
        n += 1;
    }
    return buffer[0..n];
}

test "edge matrix: a face along a face, a hair off parallel, at the tolerance's boundaries" {
    // A box's bottom over another's top, d intersection tolerances above (or into it),
    // turned about x through a line over the overlap: it straddles the reach where it tilts
    // (finds ab, ac, ah, m)
    var tally: Tally = .{ .family = "face along face" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for (signedLadder(&buffer)) |d| for (angles()) |angle| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        const h = 1 + d * x;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances, {e} rad", .{ ratio, d, angle }), helpers.boxAt(Tolerance.fromZone(ZONE), .{ 0, 0, 0 }, .{ 2, 2, 1 }), tiltedBox(ZONE * ratio, .{ 1, 1, h }, .{ 3, 3, 2 }, .{ 1.5, 1.5, h }, vec.X3, angle), false);
    };
    try tally.finish();
}

test "edge matrix: an edge along an edge, above it or beside it, at a shallow angle" {
    // A box's bottom edge along another's top edge, d tolerances above it or d into it
    // sideways, turned about z through the edge's middle: parallel edges, then crossings at
    // a shallow angle where they run within the tolerance for xsect / sin θ (finds t, u, af)
    var tally: Tally = .{ .family = "edge along edge" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for (signedLadder(&buffer)) |d| for (angles()) |angle| for ([_]bool{ false, true }) |beside| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        const lo: Vec3 = if (beside) .{ 2 - d * x, 0.5, 1 } else .{ 2, 0.5, 1 + d * x };
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances {s}, {e} rad", .{ ratio, d, if (beside) "beside" else "above", angle }), helpers.boxAt(Tolerance.fromZone(ZONE), .{ 0, 0, 0 }, .{ 2, 2, 1 }), tiltedBox(ZONE * ratio, lo, vec.add(lo, .{ 2, 1, 1 }), .{ lo[0], 1, lo[2] }, vec.Z3, angle), false);
    };
    try tally.finish();
}

test "edge matrix: a face along a plate a few tolerances thick, or crossing it" {
    // A plate t tolerances thick and a box whose bottom lies inside it, just over it or
    // well past it, turned about x: lying along the thin feature or crossing it (finds j,
    // the sandwich)
    var tally: Tally = .{ .family = "face along a thin plate" };
    for (zones()) |ratio| for (thicknesses()) |t| for ([_]f64{ 0.5, 1.5, 2.5 }) |at| for (angles()) |angle| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        const h = at * t * x / 2;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances thick, bottom at {d} of it, {e} rad", .{ ratio, t, at / 2, angle }), helpers.boxAt(Tolerance.fromZone(ZONE), .{ 0, 0, 0 }, .{ 4, 4, t * x }), tiltedBox(ZONE * ratio, .{ 1, 1, h }, .{ 3, 3, h + 1 }, .{ 2, 2, h }, vec.X3, angle), t < 2);
    };
    try tally.finish();
}

test "edge matrix: a face along a flat tetrahedron's knife edges" {
    // A tetrahedron g tolerances thick (its opposite edges that far apart, its faces
    // meeting at about g · xsect rad), and a box's top at a height through it, turned about
    // x: a face lying along the knife edges, within the zone of both its faces. Whole over
    // the tetrahedron, or its side cutting it on a diagonal, leaving pieces only in the
    // thin part about one knife edge (finds ag, h, n)
    var tally: Tally = .{ .family = "face along knife edges" };
    for (zones()) |ratio| for (thicknesses()) |g| for ([_]f64{ -0.6, -0.25, 0, 0.25, 0.6 }) |at| for (angles()) |angle| for ([_]bool{ false, true }) |cut| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        const half = g * x / 2;
        const points = [_]Vec3{ .{ 1, 2, -half }, .{ 3, 2, -half }, .{ 2, 1, half }, .{ 2, 3, half } };
        const h = at * g * x;
        const top = if (cut) diagonalTop(ZONE * ratio, h, angle) else tiltedBox(ZONE * ratio, .{ 0, 0, h - 1 }, .{ 4, 4, h }, .{ 2, 2, h }, vec.X3, angle);
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances thick, top at {d} of it, {e} rad{s}", .{ ratio, g, at, angle, if (cut) ", cut on a diagonal" else "" }), hullOf(ZONE, &points), top, g < 2);
    };
    try tally.finish();
}

/// A box whose top is at `h`, tilted `angle` about x, toward +x of a side turned 0.6 rad
/// about z through (2.4, 2): over the knife tetrahedron only past that diagonal, away from
/// its thick middle, as find ag's hull's top covered a corner of its section.
fn diagonalTop(zone: f64, h: f64, angle: f64) !Body {
    var tilted = try tiltedBox(zone, .{ 2.4, -2, h - 1 }, .{ 6, 6, h }, .{ 2.4, 2, h }, vec.X3, angle);
    defer tilted.deinit();
    return helpers.turned(&tilted, .{ 2.4, 2, h }, vec.Z3, 0.6);
}

test "edge matrix: an apex near a face, an edge, a corner and an edge's end" {
    // A tetrahedron's apex d tolerances over (or into) a box: over its top's middle, over
    // an edge, over a corner, and over an edge 1.5 tolerances from its end, in the end's
    // strip (finds i, k, l, the strip)
    var tally: Tally = .{ .family = "apex near a feature" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for (signedLadder(&buffer)) |d| for ([_][]const u8{ "face", "edge", "corner", "strip" }) |where| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        const over: [2]f64 = if (std.mem.eql(u8, where, "face")) .{ 1, 1 } else if (std.mem.eql(u8, where, "edge")) .{ 2, 1 } else if (std.mem.eql(u8, where, "corner")) .{ 2, 2 } else .{ 2, 2 - 1.5 * x };
        const apex: Vec3 = .{ over[0], over[1], 2 + d * x };
        const points = [_]Vec3{ apex, .{ over[0] - 1, over[1] - 1, 3 }, .{ over[0] + 1, over[1] - 1, 3 }, .{ over[0], over[1] + 1, 3 } };
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances over a {s}", .{ ratio, d, where }), helpers.boxAt(Tolerance.fromZone(ZONE), .{ 0, 0, 0 }, .{ 2, 2, 2 }), hullOf(ZONE * ratio, &points), false);
    };
    try tally.finish();
}

test "edge matrix: a face at a hollow box's thin wall, inside it or past it" {
    // A box with a void, its wall toward -x w tolerances thick, and a box whose +x face
    // lies d tolerances from the void's side, turned about y: a face lying in or along a
    // thin wall with a void behind it (finds q, the cavity's side)
    var tally: Tally = .{ .family = "face at a hollow box's wall" };
    for (zones()) |ratio| for (thicknesses()) |w| for ([_]f64{ -1.1, -0.5, 0, 0.5, 1.1 }) |d| for (angles()) |angle| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        const face = w * x + d * x;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, wall {d} tolerances, face {d} from the void, {e} rad", .{ ratio, w, d, angle }), hollow(w * x), tiltedBox(ZONE * ratio, .{ -1, 1.5, 1.5 }, .{ face, 2.5, 2.5 }, .{ face, 2, 2 }, vec.Y3, angle), w < 2);
    };
    try tally.finish();
}

/// A box (0, 0, 0)–(4, 4, 4) with a void, its wall toward -x `wall` thick.
fn hollow(wall: f64) !Body {
    var outer = try helpers.boxAt(Tolerance.fromZone(ZONE), .{ 0, 0, 0 }, .{ 4, 4, 4 });
    defer outer.deinit();
    var inner = try helpers.boxAt(Tolerance.fromZone(ZONE), .{ wall, 1, 1 }, .{ 3, 3, 3 });
    defer inner.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return pipeline.boolean(testing.allocator, &outer, &inner, .difference, .{}, &diag, null);
}

test "edge matrix: a face along a solid whose vertices carry gaps" {
    // A box at the coarser zone whose top's front corners lie a fraction of the zone under
    // its plane, each carrying that gap, its edges' lines in place (what a chain's merges
    // leave), and a finer box's bottom d tolerances over that top, turned about x, its
    // edges crossing the gapped edge: the face pair in one plane by the corners' reach, the
    // edges' crossing measured against the tolerance alone (find af)
    var tally: Tally = .{ .family = "face along a gapped solid" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for ([_]f64{ 0.5, 0.9 }) |miss| for (signedLadder(&buffer)) |d| for (angles()) |angle| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        const h = 1 + d * x;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, gaps {d} of the zone, {d} tolerances, {e} rad", .{ ratio, miss, d, angle }), gapped(ZONE * ratio, miss), tiltedBox(ZONE, .{ 0.5, -0.5, h }, .{ 1.5, 1, h + 1 }, .{ 1, 0, h }, vec.X3, angle), false);
    };
    try tally.finish();
}

/// The box (0, 0, 0)–(2, 2, 1) at `zone`, its top's corners at y = 0 moved `miss` of the
/// zone down and given that gap; refused when the checker does not pass it.
fn gapped(zone: f64, miss: f64) !Body {
    var body = try helpers.boxAt(Tolerance.fromZone(zone), .{ 0, 0, 0 }, .{ 2, 2, 1 });
    errdefer body.deinit();
    const gap = miss * zone;
    for (body.vertices.items) |*v| {
        const p = &body.geometry.points.items[@backingInt(v.point)];
        if (p[1] != 0 or p[2] != 1) continue;
        p[2] -= gap;
        v.gap = gap;
    }
    var report = try check.run(testing.allocator, &body, .global);
    defer report.deinit(testing.allocator);
    if (report.first() != null) return error.NotBuilt;
    return body;
}

test "edge matrix: a notch's apex at the edge of a face at an angle to it" {
    // A prism whose front is notched down to d tolerances under a plate's top edge, the
    // plate against that front at the coarser zone and turned about its edge: the plate's
    // top and the front at an angle, sharing merged vertices, the apex off the others' line
    // by its depth, within its reach or past it (find ai)
    var tally: Tally = .{ .family = "notch apex at an edge" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for (signedLadder(&buffer)) |d| for (angles()) |angle| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, apex {d} tolerances under the edge, {e} rad", .{ ratio, d, angle }), helpers.notchedPrism(Tolerance.fromZone(ZONE), 1 - d * x), tiltedBox(ZONE * ratio, .{ 0, 0, 0.5 }, .{ 10, 5, 1 }, .{ 0, 0, 1 }, vec.X3, angle), false);
    };
    try tally.finish();
}

test "edge matrix: plates nudged against each other, a difference leaving thin walls under one lid" {
    // A plate 100 by 150 and one at the coarser zone nudged by w tolerances along x and y
    // and its top l tolerances over the first's: the difference an L-shaped wall w thick
    // along two sides under a lid the tops merged into, across the whole plate (finds ar:
    // the checker's own fans called it inside out; at: a face at the other's plane by its
    // reach to rounding, made one way round, refused the other)
    var tally: Tally = .{ .family = "plates nudged", .reach = PLATE_REACH };
    for (zones()) |ratio| for (walls()) |wx| for (walls()) |wy| for (lids()) |l| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, walls {d} and {d} tolerances, lid {d}", .{ ratio, wx, wy, l }), helpers.boxAt(Tolerance.fromZone(ZONE), .{ 0, 0, 0 }, PLATE), helpers.boxAt(Tolerance.fromZone(ZONE * ratio), .{ wx * x, -wy * x, -1 }, vec.add(PLATE, .{ 1, -wy * x, l * x })), false);
    };
    try tally.finish();
}

test "edge matrix: a face crossing another within the angle, a corner of it off its own plane" {
    // A pyramid whose bottom crosses a box's top at a slope within the angular tolerance,
    // its plane d tolerances over the top at the near corner, which lies g of its zone
    // above that plane (a merged vertex's gap): the piece the top cuts off at the corner
    // lies within the zone of it all over, the corner past the tolerance or not (find as)
    var tally: Tally = .{ .family = "corner off its plane" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for (signedLadder(&buffer)) |d| for (cornerGaps()) |g| for (slopes()) |slope| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, plane {d} tolerances over, corner {d} of the zone off, slope {d}", .{ ratio, d, g, slope }), cornerPyramid(d * x, g * ZONE, slope), helpers.boxAt(Tolerance.fromZone(ZONE * ratio), .{ -5, -5, -6 }, .{ 5, 5, 0 }), false);
    };
    try tally.finish();
}

/// The pyramid of find as at `ZONE`: its bottom's plane `over` above z = 0 at x = 0 and
/// falling at `slope`, its corner at x = 0 `off` above that plane (within the zone, the
/// plane the bottom's two triangles share), its apex 2 up.
fn cornerPyramid(over: f64, off: f64, slope: f64) !Body {
    const z = struct {
        fn at(o: f64, s: f64, x: f64) f64 {
            return o - s * x;
        }
    };
    const points = [_]Vec3{ .{ 0, 0, z.at(over, slope, 0) + off }, .{ 2, -1, z.at(over, slope, 2) }, .{ 2, 1, z.at(over, slope, 2) }, .{ 4, 0, z.at(over, slope, 4) }, .{ 2, 0, 2 } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // The bottom's far triangle first, its plane the record the near one shares
    return primitives.polyhedron(testing.allocator, Tolerance.fromZone(ZONE), &points, &.{ .{ 1, 2, 3 }, .{ 0, 2, 1 }, .{ 4, 0, 1 }, .{ 4, 1, 3 }, .{ 4, 3, 2 }, .{ 4, 2, 0 } }, &diag);
}

test "edge matrix: faces in one plane, an edge within reach of a corner in the plane, past it across" {
    // An L-shaped slab's top and a plate's bottom h tolerances over the notch's inner
    // corner and o over its outer one (one plane, the plate turned about y a hair), the
    // plate's back edge e tolerances inside the slab's notch edge in that plane: each
    // corner within the tolerance of the edge in the plane and past it in 3D, or within
    // both, or past both (find ba: the outer corner on the edge, the inner one off it
    // across and on it in the plane, which the imprint's overlay welded)
    var tally: Tally = .{ .family = "faces in one plane, a corner across" };
    for (zones()) |ratio| for (pick(&HEIGHTS, &FAST_HEIGHTS)) |h| for (pick(&OUTER, &FAST_OUTER)) |o| for (pick(&OFFSETS, &FAST_OFFSETS)) |e| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        // Turned about y through the inner corner (3, 2), the outer one 3 along x: a turn
        // by θ lowers the plane by 3·θ there
        const angle = (h - o) * x / 3;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances over the inner corner, {d} over the outer, edge {d} tolerances in", .{ ratio, h, o, e }), lSlab(ZONE), tiltedBox(ZONE * ratio, .{ -1, -3, h * x }, .{ 7, 2 - e * x, 1 }, .{ 3, 2, h * x }, vec.Y3, angle), false);
    };
    try tally.finish();
}

/// The L-shaped slab of find ba: its top at z = 0, (0, 0)–(6, 4) less the notch (3, 2)–(6, 4).
fn lSlab(zone: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outline = try primitives.polygon(testing.allocator, Tolerance.fromZone(zone), &.{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 2 }, .{ 3, 2 }, .{ 3, 4 }, .{ 0, 4 } }, &diag);
    defer outline.deinit();
    var raised = try sweep.extrude(testing.allocator, &outline, .{ 0, 0, 1 }, .{}, &diag);
    defer raised.deinit();
    return helpers.moved(&raised, .{ 0, 0, -1 });
}

test "edge matrix: two solids touching along a line, a face turned about that line" {
    // Two boxes touching along x = y = 1 (one body, two solids, an edge of each there)
    // and a box whose face is turned by φ about that line and moved d tolerances off it:
    // along a box's face, into either box's wedge, across the gaps between them (find bb,
    // the seams reading one solid's wedge where the operand's material is both's)
    var tally: Tally = .{ .family = "solids touching along a line" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for (pick(&TURNS, &FAST_TURNS)) |phi| for (signedLadder(&buffer)) |d| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, turned {d}, {d} tolerances off the line", .{ ratio, phi, d }), touchingPair(ZONE), turnedCutter(ZONE * ratio, phi, d * x), false);
    };
    try tally.finish();
}

/// Two boxes touching along the line x = y = 1, z 0..2, united: one body of two solids.
fn touchingPair(zone: f64) !Body {
    var left = try helpers.boxAt(Tolerance.fromZone(zone), .{ 0, 0, 0 }, .{ 1, 1, 2 });
    defer left.deinit();
    var right = try helpers.boxAt(Tolerance.fromZone(zone), .{ 1, 1, 0 }, .{ 2, 2, 2 });
    defer right.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return pipeline.boolean(testing.allocator, &left, &right, .@"union", .{}, &diag, null);
}

/// A box whose top-in-y face lies on y = 1 + `off` from x = -2 to 4, z -0.5..2.5 (past the
/// line's ends, so that a union joining the boxes leaves them touching nowhere else, no
/// pinch to refuse first), turned by `phi` about the line x = y = 1.
fn turnedCutter(zone: f64, phi: f64, off: f64) !Body {
    var b = try helpers.boxAt(Tolerance.fromZone(zone), .{ -2, -0.5 + off, -0.5 }, .{ 4, 1 + off, 2.5 });
    if (phi == 0) return b;
    defer b.deinit();
    return helpers.turned(&b, .{ 1, 1, 0 }, vec.Z3, phi);
}

test "edge matrix: a narrow face tilted past the angle, within reach of a face across its width" {
    // A prism along x whose top is w tolerances wide, tilted by θ past the angular
    // tolerance, its low edge d tolerances over a box's top: by distance the narrow top is
    // in the box's plane, by angle it is not (step 2's inventory: classify asks one plane
    // by the angle where the paves decided it by distance)
    var tally: Tally = .{ .family = "narrow face past the angle" };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    for (zones()) |ratio| for (pick(&NARROW, &FAST_NARROW)) |w| for (pick(&TILTS, &FAST_TILTS)) |tilt| for (signedLadder(&buffer)) |d| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances wide, tilted {d}, {d} tolerances over", .{ ratio, w, tilt, d }), narrowPrism(ZONE, w * x, tilt, d * x), helpers.boxAt(Tolerance.fromZone(ZONE * ratio), .{ -1, -1, -1 }, .{ 3, 1, 0 }), false);
    };
    try tally.finish();
}

/// A prism from x = 0 to 2 whose top is `width` wide, rising across y at `tilt` from its
/// low edge `over` above z = 0, its sides falling 1 to a base wider by 0.5 each side.
fn narrowPrism(zone: f64, width: f64, tilt: f64, over: f64) !Body {
    const top_y = width * @cos(tilt);
    const top_z = over + width * @sin(tilt);
    var points: [8]Vec3 = undefined;
    for ([_]f64{ 0, 2 }, 0..) |px, i| {
        points[4 * i + 0] = .{ px, 0, over };
        points[4 * i + 1] = .{ px, top_y, top_z };
        points[4 * i + 2] = .{ px, top_y + 0.5, over - 1 };
        points[4 * i + 3] = .{ px, -0.5, over - 1 };
    }
    return hullOf(zone, &points);
}

test "edge matrix: two boxes side by side, one's top a step over the other's and tilted" {
    // Two boxes side by side s tolerances apart (or into each other), the second's top t
    // tolerances over the first's and turned about x: the union's tops one face where the
    // paves took them in one plane, which simplify decides again on the result (step 2's
    // inventory: sameDomain)
    var tally: Tally = .{ .family = "tops side by side" };
    for (zones()) |ratio| for (pick(&SIDE_GAPS, &FAST_SIDE_GAPS)) |s| for (pick(&TOP_STEPS, &FAST_TOP_STEPS)) |t| for (angles()) |angle| {
        const x = xsectOf(ratio);
        var name: [160]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {d} tolerances apart, top {d} tolerances over, {e} rad", .{ ratio, s, t, angle }), helpers.boxAt(Tolerance.fromZone(ZONE), .{ 0, 0, 0 }, .{ 2, 2, 1 }), tiltedBox(ZONE * ratio, .{ 2 + s * x, 0, 0 }, .{ 4, 2, 1 + t * x }, .{ 3, 1, 1 + t * x }, vec.X3, angle), false);
    };
    try tally.finish();
}

test "edge matrix: a hull's top shallow to a plate's top, its corners about the plate's top" {
    // The solids fuzzer's hull turned about y, its top's corners on the line x = 2 lifted d
    // tolerances over a plate's top (under it when negative), 0.028 inside the plate's side
    // at the tolerance turn or s tolerances inside it: the two tops parallel within the angular
    // tolerance and not in one plane meet along the corners' line, the planes' own line
    // somewhere beside it; past the angle, along their own (find bl: the seam there passed
    // over as parallel, a ray's sample either side of the top)
    var tally: Tally = .{ .family = "top shallow to a top", .reach = PLATE_REACH };
    var buffer: [2 * DISTANCES.len]f64 = undefined;
    const x = xsectOf(10);
    for (pick(&SHALLOW_TURNS, &FAST_SHALLOW_TURNS)) |turn| for ([_]f64{ 1, -1 }) |sign| for (if (FULL) signedLadder(&buffer) else &FAST_SHALLOW_OVER) |d| for (both()) |mirrored| for (if (FULL) &SHALLOW_INSIDE else &FAST_SHALLOW_INSIDE) |inside| {
        if (!FULL and sign < 0) continue;
        var buffer_name: [200]u8 = undefined;
        var name: std.Io.Writer = .fixed(&buffer_name);
        try name.print("turned {e}, corners {d} tolerances over{s}", .{ sign * turn, d, if (mirrored) ", mirrored" else "" });
        if (inside) |s| try name.print(", {d} tolerances inside the plate's side", .{s});
        try run(&tally, name.buffered(), shallowHull(sign * turn, d * x, mirrored, if (inside) |s| s * x else null), drawn.shallowPlate(), false);
    };
    try tally.finish();
}

/// Find bl's hull turned by `turn` about y through the fuzzer's grid middle, its top's
/// corners on the line x = 2 (which the turn lowers by 2 (1 − cos) and takes 2 sin along
/// x) `over` above z = 4, the plate's top, and `inside` past x = 2, the plate's side (as
/// the fuzzer nudged them when null). Mirrored in y or not.
fn shallowHull(turn: f64, over: f64, mirrored: bool, inside: ?f64) !Body {
    var points = drawn.SHALLOW_HULL;
    if (mirrored) for (&points) |*p| {
        p[1] = 3 - p[1];
    };
    return drawn.fuzzHullPlaced(&points, vec.Y3, turn, null, .{ 0, 0.5, 0 }, .{ if (inside) |s| s - 2 * @sin(turn) else 2e-5, 0, over + 2 * (1 - @cos(turn)) });
}

/// A slab whose edge lies off its top's plane: how far in tolerances, the turn of the
/// plate that cut it, mirrored in y or not.
const Slab = struct {
    lip: f64,
    turn: f64,
    mirrored: bool,

    /// The tolerance of the slab and of what meets it.
    const X = Tolerance.fromZone(LIP_ZONE).xsect;

    /// One case: the slab and `shape` against it, named by `what`.
    fn run(self: Slab, tally: *Tally, shape: drawn.LipShape, comptime what: []const u8, args: anytype) !void {
        var buffer: [240]u8 = undefined;
        var name: std.Io.Writer = .fixed(&buffer);
        try name.print("edge {d} tolerances over, cut at {e}{s}: ", .{ self.lip, self.turn, if (self.mirrored) ", mirrored" else "" });
        try name.print(what, args);
        try matrixRun(tally, name.buffered(), drawn.lippedSlabTurned(self.lip * X, self.turn, self.mirrored), drawn.lipOperand(shape, self.lip * X, self.mirrored), false);
    }
};

const matrixRun = run;

/// Every slab of the tier, each first cut from its hull as a case of its own (`tally`'s:
/// the hull and the plate under the oracle, where a slab only failing to be made would
/// count as not built), into `buffer`.
fn slabs(tally: *Tally, buffer: *[LIPS.len * LIP_TURNS.len * BOTH.len]Slab) ![]const Slab {
    var n: usize = 0;
    for (pick(&LIPS, &FAST_LIPS)) |lip| for (pick(&LIP_TURNS, &FAST_LIP_TURNS)) |turn| for (both()) |mirrored| {
        buffer[n] = .{ .lip = lip, .turn = turn, .mirrored = mirrored };
        n += 1;
        var name: [200]u8 = undefined;
        try run(tally, try std.fmt.bufPrint(&name, "edge {d} tolerances over, cut at {e}{s}: the hull under the plate", .{ lip, turn, if (mirrored) ", mirrored" else "" }), drawn.lippedHull(mirrored), drawn.lipCutter(lip * Slab.X, turn), false);
    };
    return buffer[0..n];
}

/// The heights in tolerances over a plane of the faces met with a slab whose edge is
/// `lip` over that plane: `LIP_LIFTS`, and `LIP_OVER_EDGE` over the edge, each once.
fn lipLifts(lip: f64, buffer: *[LIP_LIFTS.len + LIP_OVER_EDGE.len]f64) []const f64 {
    var n: usize = 0;
    for (pick(&LIP_LIFTS, &FAST_LIP_LIFTS)) |l| {
        buffer[n] = l;
        n += 1;
    }
    over: for (pick(&LIP_OVER_EDGE, &FAST_LIP_OVER_EDGE)) |l| {
        for (buffer[0..n]) |had| if (@abs(had - (lip + l)) < 1e-9) continue :over;
        buffer[n] = lip + l;
        n += 1;
    }
    return buffer[0..n];
}

test "edge matrix: a box on the top of a slab whose edge lies off the top's plane" {
    // A slab cut from a hull by a plate whose top came within the tolerance of one of the
    // hull's edges: the edge kept on its own line (D28), l tolerances off the top's plane.
    // A box over the whole top, inside it clear of the edge, or across the edge (its sides
    // crossing it, no corner of the slab under it), its bottom h tolerances over the
    // plane: in the top's plane, on the edge and past the plane (parallel faces that share
    // only the edge: finds bn and the hinge window), or clear of both
    var tally: Tally = .{ .family = "box on a top with an edge off its plane" };
    var slab_buffer: [LIPS.len * LIP_TURNS.len * BOTH.len]Slab = undefined;
    var lift_buffer: [LIP_LIFTS.len + LIP_OVER_EDGE.len]f64 = undefined;
    const feet = [_]struct { name: []const u8, foot: [2][2]f64 }{ .{ .name = "across the edge", .foot = drawn.FOOT_ACROSS }, .{ .name = "over the top", .foot = drawn.FOOT_COVER }, .{ .name = "inside the top", .foot = drawn.FOOT_INSIDE } };
    for (try slabs(&tally, &slab_buffer)) |slab| for (if (FULL) &feet else feet[0..1]) |foot| for (lipLifts(slab.lip, &lift_buffer)) |h| {
        try slab.run(&tally, .{ .on_top = .{ .foot = foot.foot, .lift = h * Slab.X } }, "a box {s}, its bottom {d} tolerances over the plane", .{ foot.name, h });
    };
    try tally.finish();
}

test "edge matrix: a box through, along or at the end of a slab's edge that lies off its top's plane" {
    // The same slabs and a box through the top (a side along the edge or an upright edge
    // through it, o tolerances inside it or outside, the box either side), a box's bottom
    // edge along the edge h tolerances over it, a box's corner at the edge's end, and a
    // wedge's edge down onto the edge or against it from beside: edge–edge and
    // vertex–edge against the edge's own line, a section along the top's boundary
    // (the targeted review's lead 1: `pave.alongBoundary`, `in_face.placeWithin`)
    var tally: Tally = .{ .family = "box at an edge off its top's plane" };
    var slab_buffer: [LIPS.len * LIP_TURNS.len * BOTH.len]Slab = undefined;
    const z = drawn.LIP_Z;
    const x = Slab.X;
    for (try slabs(&tally, &slab_buffer)) |slab| {
        for (pick(&LIP_ACROSS, &FAST_LIP_ACROSS)) |o| for (both()) |outside| {
            const lo: f64 = if (outside) o * x - 1 else o * x;
            const side: []const u8 = if (outside) "outside" else "inside";
            try slab.run(&tally, .{ .by_edge = .{ .{ -0.5, lo, 1.5 }, .{ 0.5, lo + 1, 3 } } }, "a box through the top {s}, its side {d} tolerances in from the edge", .{ side, o });
            if (FULL) try slab.run(&tally, .{ .by_edge = .{ .{ 0, lo, 1.5 }, .{ 1, lo + 1, 3 } } }, "a box through the top {s}, its upright edge {d} tolerances in from the edge", .{ side, o });
        };
        if (!FULL) continue;
        for (LIP_ACROSS) |o| for (BOTH) |outside| for (LIP_OVER_EDGE) |h| {
            const lo: f64 = if (outside) o * x - 1 else o * x;
            try slab.run(&tally, .{ .by_edge = .{ .{ -0.5, lo, z + h * x }, .{ 0.5, lo + 1, 3 } } }, "a box {s}, its bottom edge {d} tolerances in from the edge and {d} over it", .{ if (outside) "outside" else "inside", o, h });
        };
        try slab.run(&tally, .{ .box = .{ .{ 1, -1, 1.5 }, .{ 2, 1.5, 3 } } }, "a box through the top across the edge", .{});
        for (LIP_FROM_END) |o| {
            try slab.run(&tally, .{ .by_end = .{ .{ -1, -1, 1.5 }, .{ o * x, o * x, 3 } } }, "a box through the slab, its upright edge {d} tolerances past the edge's end", .{o});
            for (LIP_OVER_EDGE) |h| {
                try slab.run(&tally, .{ .by_end = .{ .{ -1, -1, z + h * x }, .{ o * x, o * x, 3 } } }, "a box beside the slab, its corner {d} tolerances past the edge's end and {d} over it", .{ o, h });
                try slab.run(&tally, .{ .by_end = .{ .{ o * x, o * x, z + h * x }, .{ 1, 1, 3 } } }, "a box over the top, its corner {d} tolerances past the edge's end and {d} over it", .{ o, h });
            }
        }
        for (LIP_ACROSS) |h| try slab.run(&tally, .{ .wedge = drawn.wedgeOver(h * x) }, "a wedge's edge {d} tolerances over the edge", .{h});
        for (LIP_FROM_END) |o| {
            const d = o * x;
            try slab.run(&tally, .{ .wedge = .{ .{ -0.5, d, z }, .{ 0.5, d, z }, .{ -0.5, d - 0.5, z + 0.3 }, .{ 0.5, d - 0.5, z + 0.3 }, .{ -0.5, d - 0.5, z - 0.3 }, .{ 0.5, d - 0.5, z - 0.3 } } }, "a wedge's edge against the edge from beside, {d} tolerances in", .{o});
        }
    }
    try tally.finish();
}

test "edge matrix: a box against the one corner of a slab's bottom that lies off the bottom's plane" {
    // The same slabs' bottoms, one corner of each l tolerances off the bottom's plane: a
    // box under the whole bottom, or with a corner of its own at that corner under the
    // slab or beside it, its top h tolerances over the plane (into the slab); and a box
    // through the bottom there, an upright edge o tolerances from the corner (vertex–face
    // and vertex–vertex with a single corner off its plane, `pave.blocksInside`)
    var tally: Tally = .{ .family = "box at a corner off its bottom's plane" };
    var slab_buffer: [LIPS.len * LIP_TURNS.len * BOTH.len]Slab = undefined;
    var lift_buffer: [LIP_LIFTS.len + LIP_OVER_EDGE.len]f64 = undefined;
    const c = drawn.BOTTOM_CORNER;
    const feet = [_]struct { name: []const u8, foot: [2][2]f64 }{ .{ .name = "under the whole bottom", .foot = drawn.FOOT_COVER }, .{ .name = "under the slab, a corner at the corner", .foot = .{ .{ c[0], c[1] - 1 }, .{ c[0] + 1, c[1] } } }, .{ .name = "beside the slab, a corner at the corner", .foot = .{ .{ c[0] - 1, c[1] }, .{ c[0], c[1] + 1 } } } };
    for (try slabs(&tally, &slab_buffer)) |slab| {
        for (if (FULL) &feet else feet[0..1]) |foot| for (lipLifts(slab.lip, &lift_buffer)) |h| {
            try slab.run(&tally, .{ .under = .{ .foot = foot.foot, .lift = h * Slab.X } }, "a box {s}, its top {d} tolerances over the plane", .{ foot.name, h });
        };
        if (!FULL) continue;
        for (LIP_ACROSS) |o| {
            const d = o * Slab.X;
            try slab.run(&tally, .{ .box = .{ .{ c[0] + d, c[1] - 1, 0 }, .{ c[0] + 1, c[1] + d, 1.5 } } }, "a box through the bottom under the slab, its upright edge {d} tolerances from the corner", .{o});
            try slab.run(&tally, .{ .box = .{ .{ c[0] - 1, c[1] + d, 0 }, .{ c[0] + d, c[1] + 1, 1.5 } } }, "a box through the bottom beside the slab, its upright edge {d} tolerances from the corner", .{o});
        }
    }
    try tally.finish();
}

test "edge matrix: a prism's ridge in a face, its face beside shallow to that face" {
    // A prism whose ridge lies along z in the face y = 0 of a plate, of a box whose edge
    // runs along the ridge (under the shallow face) or of a box beside it, lifted l
    // tolerances off that face, its face from the ridge turned by θ from the plate's:
    // rising from it (the solids touch along the ridge) or dipping into it, within the
    // angular tolerance (parallel by angle, hinged at the ridge) or past it. A wedge, a
    // block notched down to the ridge (a concave edge there), and a wedge whose shallow
    // face is a strip 1e-3 wide, in the plate's plane by its far edge's distance or not
    // (the targeted review's lead 2: `classify.wedgeSide` takes "in one plane" from the
    // angle, `pipeline.pairByWedges` orders the faces about the ridge)
    var tally: Tally = .{ .family = "ridge in a face, shallow to it" };
    const others = [_]struct { name: []const u8, lo: Vec3, hi: Vec3 }{ .{ .name = "a plate", .lo = .{ -5, -2, -1 }, .hi = .{ 5, 0, 3 } }, .{ .name = "a box under the shallow face", .lo = .{ 0, -2, -1 }, .hi = .{ 5, 0, 3 } }, .{ .name = "a box beside the ridge", .lo = .{ -5, -2, -1 }, .hi = .{ 0, 0, 3 } } };
    const prisms = [_]struct { name: []const u8, profile: []const vec.Vec2, turns: []const f64 }{ .{ .name = "wedge", .profile = &drawn.RIDGE_WEDGE, .turns = pick(&RIDGE_TURNS, &FAST_RIDGE_TURNS) }, .{ .name = "notched block", .profile = &drawn.RIDGE_NOTCHED, .turns = pick(&RIDGE_TURNS, &FAST_RIDGE_TURNS) }, .{ .name = "strip", .profile = &drawn.RIDGE_STRIPPED, .turns = pick(&STRIP_TURNS, &FAST_STRIP_TURNS) } };
    for (zones()) |ratio| for (if (FULL) &others else others[0..1]) |other| for (if (FULL) &prisms else prisms[0..1]) |prism| for (prism.turns) |turn| for ([_]f64{ 1, -1 }) |sign| for (pick(&RIDGE_LIFTS, &FAST_RIDGE_LIFTS)) |l| for (both()) |mirrored| {
        const x = xsectOf(ratio);
        var name: [240]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, {s}, a {s} turned {e}, its ridge {d} tolerances off{s}", .{ ratio, other.name, prism.name, sign * turn, l, if (mirrored) ", mirrored" else "" }), helpers.boxAt(Tolerance.fromZone(ZONE * ratio), other.lo, other.hi), drawn.ridgePrism(prism.profile, sign * turn, mirrored, l * x), false);
    };
    try tally.finish();
}

test "edge matrix: two wedges ridge to ridge, their facing faces shallow to each other" {
    // A wedge under y = 0 and one over it, their ridges along z, the upper lifted l
    // tolerances, each turned about its ridge: the facing faces apart with a gap between
    // (touching along the ridge), in one plane, or crossing, within the angular tolerance
    // of each other or past it (lead 2: both faces of an edge parallel by angle)
    var tally: Tally = .{ .family = "wedges ridge to ridge" };
    const x = xsectOf(1);
    for (pick(&RIDGE_PAIR_TURNS, &FAST_RIDGE_PAIR_TURNS)) |under| for (pick(&RIDGE_PAIR_TURNS, &FAST_RIDGE_PAIR_TURNS)) |over| for (pick(&RIDGE_LIFTS, &FAST_RIDGE_LIFTS)) |l| {
        var name: [200]u8 = undefined;
        try run(&tally, try std.fmt.bufPrint(&name, "the lower turned {e}, the upper {e}, {d} tolerances over", .{ under, over, l }), drawn.ridgePrism(&drawn.RIDGE_WEDGE_UNDER, under, false, 0), drawn.ridgePrism(&drawn.RIDGE_WEDGE, over, false, l * x), false);
    };
    try tally.finish();
}

test "edge matrix: a keel in a face, both its faces shallow to that face" {
    // A prism whose two lower faces meet at a ridge in a plate's face y = 0, lifted l
    // tolerances, each rising from the plate's or dipping into it by its own turn: both
    // faces of the edge parallel to the plate's by angle, or one, or neither (lead 2:
    // `classify.wedgeSide` with both faces "in the fragment's plane")
    var tally: Tally = .{ .family = "keel in a face" };
    for (zones()) |ratio| for (pick(&RIDGE_PAIR_TURNS, &FAST_RIDGE_PAIR_TURNS)) |left| for (pick(&RIDGE_PAIR_TURNS, &FAST_RIDGE_PAIR_TURNS)) |right| for (pick(&RIDGE_LIFTS, &FAST_RIDGE_LIFTS)) |l| {
        // Level on either side the ridge is no corner of the profile
        if (left == 0 or right == 0) continue;
        const x = xsectOf(ratio);
        var name: [200]u8 = undefined;
        const profile = [_]vec.Vec2{ .{ 0, 0 }, .{ 3, 3 * @tan(right) }, .{ 3, 1 }, .{ -3, 1 }, .{ -3, 3 * @tan(left) } };
        try run(&tally, try std.fmt.bufPrint(&name, "zone ×{d}, left {e}, right {e}, {d} tolerances over", .{ ratio, left, right, l }), helpers.boxAt(Tolerance.fromZone(ZONE * ratio), .{ -5, -2, -1 }, .{ 5, 0, 3 }), drawn.ridgePrism(&profile, 0, false, l * x), false);
    };
    try tally.finish();
}

test "edge matrix: a plate joined to a thin wall, its side inside the wall, met by a hull" {
    // The solids fuzzer's wall g tolerances thick (a box less a cavity) and a plate through
    // the cavity whose side lies p tolerances from the wall's middle plane: inside the
    // wall, in its outer face's plane, or past it. The two under the oracle, then their
    // union met by a hull nudged along x and z (find bp: the plate's side half a tolerance
    // inside the outer face of a wall 3 thick, 2.5 from the cavity's; a fragment of the
    // hull's with seams on both sides)
    var tally: Tally = .{ .family = "plate joined to a thin wall", .reach = PLATE_REACH };
    const x = Tolerance.fromZone(WALL_ZONE).xsect;
    for (pick(&WALL_GAPS, &FAST_WALL_GAPS)) |g| for (pick(&WALL_PLATE_SIDES, &FAST_WALL_PLATE_SIDES)) |p| for (both()) |mirrored| {
        var name: [240]u8 = undefined;
        const flipped: []const u8 = if (mirrored) ", mirrored" else "";
        try run(&tally, try std.fmt.bufPrint(&name, "wall {d} tolerances, plate's side {d} from its middle{s}: the plate and the wall", .{ g, p, flipped }), wallPlate(p * x, mirrored), thinWall(g * x, mirrored), false);
        for (pick(&WALL_HULL_ALONG, &FAST_WALL_HULL_ALONG)) |along| for (pick(&WALL_HULL_UP, &FAST_WALL_HULL_UP)) |up| {
            try run(&tally, try std.fmt.bufPrint(&name, "wall {d} tolerances, plate's side {d} from its middle{s}: a hull nudged {d} along and {d} up", .{ g, p, flipped, along, up }), plateOnWall(g * x, p * x, mirrored), wallHull(along * x, up * x, mirrored), false);
        };
    };
    try tally.finish();
}

/// Find bp's wall, `gap` thick about the plane x = `WALL_AT` (the fuzzer's
/// `fuzz_test.GapShape`, nudged as bp's), mirrored in y about the wall's middle or not.
fn thinWall(gap: f64, mirrored: bool) !Body {
    const t = Tolerance.fromZone(WALL_ZONE);
    var outer = try helpers.boxAt(t, .{ WALL_AT - WALL_DEPTH - WALL_INSET, 1, 1 }, .{ WALL_AT + gap / 2, 4, 4 });
    defer outer.deinit();
    var cavity = try helpers.boxAt(t, .{ WALL_AT - WALL_DEPTH, 1 + WALL_INSET, 1 + WALL_INSET }, .{ WALL_AT - gap / 2, 4 - WALL_INSET, 4 - WALL_INSET });
    defer cavity.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var wall = try pipeline.boolean(testing.allocator, &outer, &cavity, .difference, .{}, &diag, null);
    defer wall.deinit();
    return helpers.moved(&wall, .{ 0, 0, if (mirrored) 5e-5 else -5e-5 });
}

/// Find bp's plate, its side `side` past the plane x = `WALL_AT`, placed as the fuzzer
/// placed it; mirrored in y about the wall's middle (y = 2.5) or not.
fn wallPlate(side: f64, mirrored: bool) !Body {
    return helpers.fuzzPlaced(Tolerance.fromZone(WALL_ZONE), .{ 50, 100, 1 }, .{ -48, if (mirrored) -97 else 2, 1 }, vec.Z3, 0, .{ 0, 0, 0.5 }, .{ side, if (mirrored) -5e-5 else 5e-5, 0 });
}

/// The union of that plate and that wall, the first operand of find bp's failing step.
fn plateOnWall(gap: f64, side: f64, mirrored: bool) !Body {
    var plate = try wallPlate(side, mirrored);
    defer plate.deinit();
    var wall = try thinWall(gap, mirrored);
    defer wall.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return pipeline.boolean(testing.allocator, &plate, &wall, .@"union", .{}, &diag, null);
}

/// Find bp's hull, nudged by `along` in x and `up` in z, mirrored as the wall is.
fn wallHull(along: f64, up: f64, mirrored: bool) !Body {
    var points = WALL_HULL;
    if (mirrored) for (&points) |*p| {
        p[1] = 5 - p[1];
    };
    return drawn.fuzzHullPlaced(&points, vec.Z3, 0, null, .{ 0, if (mirrored) 1 else -1, 0 }, .{ along, 0, up });
}
