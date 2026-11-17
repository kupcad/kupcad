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
const check = @import("../topology/check.zig");
const pipeline = @import("pipeline.zig");
const helpers = @import("pipeline_test.zig");
const oracle = @import("oracle_test.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

/// Every value of every ladder, not the fast tier's (`-Dedge-matrix=full`).
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
