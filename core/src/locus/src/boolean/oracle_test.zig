//! The solid booleans' oracles, one set for every driver of them: the solids fuzzer's
//! chains (`fuzz_test.zig`) and the edge-case matrix (`matrix_test.zig`). A step is the
//! three operations of two operands, each result sound (`expectSolid`) and its report
//! fitting it; then the volume identities, membership where it is clear and the operands
//! the other way round (`expectStep`); a chain under one rigid move (`expectMovedWhole`).
//! A refusal by design is clean (`clean`); the general path failing on valid operands is a
//! find, whichever driver drew them.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const mass = @import("../measure/mass.zig");
const tessellate = @import("../mesh/tessellate.zig");
const transform = @import("../construct/transform.zig");
const Affine = @import("../math/mat.zig").Affine;
const overlap = @import("../query/overlap.zig");
const distance_mod = @import("../query/distance.zig");
const FaceIndex = @import("../query/index.zig").FaceIndex;
const point_in_body = @import("../query/point_in_body.zig");
const pipeline = @import("pipeline.zig");
const tests = @import("pipeline_test.zig");
const Diagnostics = diagnostics.Diagnostics;
const Op = pipeline.Op;

/// How close the booleans' identities must hold beyond the welding: the overlay welds
/// vertices and arcs within the zone, which moves a boundary by up to the zone, so a
/// result's area may differ from its operands' own by the zone times their perimeters;
/// this is the rounding on top.
pub const IDENTITY_CLOSE = 1e-9;
/// A measure's rounding where a move takes it, in ulps of the distance times the area:
/// mass sums terms that size (as D27 reckons, 64).
pub const MOVE_ROUNDING_ULPS = 64;
/// Points each boolean step checks membership at (`expectMembership`).
const MEMBERSHIP_POINTS = 24;
/// How far a membership point keeps from both operands' boundaries, in intersection
/// tolerances beyond the step's largest gap: a result's faces lie within the tolerance of
/// the operands' (D28: a plane holds its group's faces within it, a merged vertex is within
/// it and its gap of what it merged), and a point is classified within the zone.
const MEMBERSHIP_CLEAR = 4;

/// The operations of a step, in the order `expectStep` takes their results.
pub const OPS = [3]Op{ .@"union", .intersection, .difference };

/// A boolean step of a chain: its other operand and the operation the chain kept.
pub const Step = struct { other: Body, op: Op };

/// The plane a chain is mirrored in (`expectMirrored`): x = 0, exact (a coordinate's sign
/// flips, and nothing rounds).
const MIRROR_NORMAL = vec.Vec3{ 1, 0, 0 };

/// A refusal by design is clean; the general path failing on valid planar operands
/// (`NotValid`, `IntersectionFailed`) is a find, and out of memory is the harness's own.
pub fn clean(err: anyerror) anyerror!void {
    switch (err) {
        error.OutOfMemory, error.NotValid, error.IntersectionFailed => return err,
        else => {},
    }
}

/// A solid passes every rule of the checker and the overlap rules.
pub fn expectSolid(body: *const Body, diag: *Diagnostics) !void {
    var report = try check.run(testing.allocator, body, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        std.debug.print("the checker: {f}\n", .{f});
        return error.ResultNotValid;
    }
    overlap.check(testing.allocator, body, .{}, diag) catch |err| {
        // The rule that failed, before the warnings the result carries
        if (diag.first()) |f| std.debug.print("the overlap rules: {f}\n", .{f});
        return err;
    };
}

pub fn solidVolume(body: *const Body, diag: *Diagnostics) !f64 {
    return (try mass.mass(body, .{}, diag)).volume;
}

/// The step's results checked together (`results` the union, the intersection and the
/// difference of `a` and `b`, `shifts` and `gaps` their reports'): the volume identities,
/// to the slab of faces closer than the intersection tolerance and what the reports say
/// the faces moved (D28); membership where it is clear; the operands the other way round.
pub fn expectStep(a: *const Body, b: *const Body, results: *const [3]Body, shifts: [3]f64, gaps: [3]f64, diag: *Diagnostics) !void {
    const ma = try mass.mass(a, .{}, diag);
    const mb = try mass.mass(b, .{}, diag);
    const va = ma.volume;
    const vb = mb.volume;
    const vu = try solidVolume(&results[0], diag);
    const vi = try solidVolume(&results[1], diag);
    const vd = try solidVolume(&results[2], diag);
    // Faces closer than the intersection tolerance are one plane: the slab between them,
    // at most the tolerance times the smaller operand's area, may count either way
    const close = IDENTITY_CLOSE * @max(va + vb, 1) + tolerance.Tolerance.merge(a.tol, b.tol).xsect * @min(ma.area, mb.area);
    errdefer std.debug.print("volumes: a {d}, b {d}, union {d}, intersection {d}, difference {d}\n", .{ va, vb, vu, vi, vd });
    try testing.expectApproxEqAbs(va + vb, vu + vi, close + shifts[0] + shifts[1]);
    try testing.expectApproxEqAbs(va - vi, vd, close + shifts[1] + shifts[2]);
    try expectMembership(a, b, results, @max(gaps[0], gaps[1], gaps[2]), diag);
    try expectSwapped(a, b, results[0..2], shifts[0..2], close, diag);
}

/// The operands the other way round (the research review's item 19): B ∪ A and B ∩ A have
/// the counts and shells of A ∪ B and A ∩ B (`results`), and their area and volume to the
/// slab of faces closer than the tolerance (`close`) and both ways' shifts. A refusal the
/// other way round is a find: the paves decide pairs, not orders.
fn expectSwapped(a: *const Body, b: *const Body, results: []const Body, shifts: []const f64, close: f64, diag: *Diagnostics) !void {
    for ([_]Op{ .@"union", .intersection }, results, shifts) |op, *forward, shift| {
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        var swapped = try pipeline.boolean(testing.allocator, b, a, op, .{}, diag, &report);
        defer swapped.deinit();
        errdefer std.debug.print("{s} the other way round: {any}, shells {any}; forward {any}, shells {any}\n", .{ @tagName(op), swapped.counts(), tests.shellKinds(&swapped), forward.counts(), tests.shellKinds(forward) });
        try testing.expectEqual(forward.counts(), swapped.counts());
        try testing.expectEqual(tests.shellKinds(forward), tests.shellKinds(&swapped));
        const m = try mass.mass(forward, .{}, diag);
        const ms = try mass.mass(&swapped, .{}, diag);
        const slack = close + shift + report.shift;
        errdefer std.debug.print("{s} the other way round: area {d}, volume {d}; forward {d}, {d}\n", .{ @tagName(op), ms.area, ms.volume, m.area, m.volume });
        try testing.expectApproxEqAbs(m.volume, ms.volume, slack);
        try testing.expectApproxEqAbs(m.area, ms.area, slack + forward.tol.xsect * m.area);
    }
}

/// Membership where it is clear (research/li-chen-egc.md §4, Shapiro's set-membership
/// classification): at a point farther than `MEMBERSHIP_CLEAR` intersection tolerances and
/// the step's largest gap from both operands' boundaries, the union, the intersection and
/// the difference (`results`, in that order) each hold the point exactly when their
/// operation on its membership in the operands says so, and none has it on its boundary.
/// The volume identities hold for a result whose pieces are wrongly placed but sized
/// right; this does not. The points from a skewed sequence, every other one over the
/// overlap of the operands' boxes (where both hold points), the rest over both boxes;
/// their distances to the operands' boundaries exact on their meshes (planar faces mesh
/// exactly); a classification refused (every ray met an edge) skips its point.
pub fn expectMembership(a: *const Body, b: *const Body, results: *const [3]Body, gap: f64, diag: *Diagnostics) !void {
    const fault = (try membershipFault(a, b, results, gap, diag)) orelse return;
    const p = fault.p;
    std.debug.print("membership at ({d}, {d}, {d}), {d} clear: a {s}, b {s}; union {s}, intersection {s}, difference {s}\n", .{ p[0], p[1], p[2], fault.clear, @tagName(fault.places[0]), @tagName(fault.places[1]), @tagName(fault.places[2]), @tagName(fault.places[3]), @tagName(fault.places[4]) });
    return error.MembershipDisagrees;
}

/// A point where membership disagrees (`expectMembership`): where it is, how far it keeps
/// from the operands' boundaries, and its place in a, b and the three results.
const MembershipFault = struct { p: vec.Vec3, clear: f64, places: [5]point_in_body.Place };

fn membershipFault(a: *const Body, b: *const Body, results: *const [3]Body, gap: f64, diag: *Diagnostics) !?MembershipFault {
    const clear = MEMBERSHIP_CLEAR * tolerance.Tolerance.merge(a.tol, b.tol).xsect + gap;
    var meshes: [2]tessellate.Mesh = undefined;
    var meshed: usize = 0;
    defer for (meshes[0..meshed]) |*m| m.deinit(testing.allocator);
    var indexes: [5]FaceIndex = undefined;
    var indexed: usize = 0;
    defer for (indexes[0..indexed]) |*x| x.deinit(testing.allocator);
    for ([_]*const Body{ a, b }) |operand| {
        meshes[meshed] = try tessellate.tessellate(testing.allocator, operand, .{}, .{}, diag);
        meshed += 1;
    }
    for ([_]*const Body{ a, b, &results[0], &results[1], &results[2] }) |body| {
        indexes[indexed] = try FaceIndex.build(testing.allocator, body, diag);
        indexed += 1;
    }
    const both = indexes[0].box.merge(indexes[1].box);
    var common: geometry.Box3 = undefined;
    for (0..3) |c| {
        common.min[c] = @max(indexes[0].box.min[c], indexes[1].box.min[c]);
        common.max[c] = @min(indexes[0].box.max[c], indexes[1].box.max[c]);
    }
    for (0..MEMBERSHIP_POINTS) |i| {
        const box = if (i % 2 == 0 and !common.isEmpty()) common else both;
        const span = box.size();
        const k: f64 = @floatFromInt(i);
        const p: vec.Vec3 = .{ box.min[0] + @mod(k * 0.618 + 0.21, 1) * span[0], box.min[1] + @mod(k * 0.382 + 0.13, 1) * span[1], box.min[2] + @mod(k * 0.7549 + 0.37, 1) * span[2] };
        if (distanceToMesh(&meshes[0], p) <= clear or distanceToMesh(&meshes[1], p) <= clear) continue;
        var places: [5]point_in_body.Place = undefined;
        var refused = false;
        for (&places, 0..) |*place, j| {
            const body = switch (j) {
                0 => a,
                1 => b,
                else => &results[j - 2],
            };
            place.* = point_in_body.classify(testing.allocator, body, &indexes[j], p, .{}, diag) catch |err| {
                try clean(err);
                refused = true;
                break;
            };
        }
        if (refused) continue;
        const in_a = places[0] == .inside;
        const in_b = places[1] == .inside;
        const want = [3]bool{ in_a or in_b, in_a and in_b, in_a and !in_b };
        var agrees = true;
        for (places) |place| agrees = agrees and place != .boundary;
        for (want, places[2..]) |w, place| agrees = agrees and w == (place == .inside);
        if (!agrees) return .{ .p = p, .clear = clear, .places = places };
    }
    return null;
}

/// The distance from `p` to the nearest triangle of `mesh`.
fn distanceToMesh(mesh: *const tessellate.Mesh, p: vec.Vec3) f64 {
    var nearest = std.math.inf(f64);
    for (mesh.triangles) |t| {
        const corners = [3]vec.Vec3{ mesh.positions[t[0]], mesh.positions[t[1]], mesh.positions[t[2]] };
        nearest = @min(nearest, vec.distance(p, distance_mod.closestOnTriangle(p, corners)));
    }
    return nearest;
}

/// The chain again with its first solid and every other operand under the rigid `move`
/// (§9.2's invariance of measures): the same counts and shells as the chain's `result`,
/// its area and volume to the slab the identities allow and the rounding where the move
/// took them (`reach`: how far from the origin the moved solids lie, at most). A step the
/// moved chain refuses is clean: a distance near the tolerance moves by a rounding, at
/// most onto the refused side (D27); a failure is a find.
pub fn expectMovedWhole(first: *const Body, steps: []const Step, result: *const Body, move: *const Affine, reach: f64, diag: *Diagnostics) !void {
    var moved = transform.transform(testing.allocator, first, move, .{}, diag) catch |err| return refusedMove(err);
    defer moved.deinit();
    for (steps) |step| {
        var other = transform.transform(testing.allocator, &step.other, move, .{}, diag) catch |err| return refusedMove(err);
        defer other.deinit();
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        var next = pipeline.boolean(testing.allocator, &moved, &other, step.op, .{}, diag, &report) catch |err| return clean(err);
        defer next.deinit();
        try expectSolid(&next, diag);
        try tests.expectReportFits(&report, &moved, &other, &next, step.op);
        std.mem.swap(Body, &moved, &next);
    }
    errdefer std.debug.print("moved whole: {any}, shells {any}; the chain's: {any}, shells {any}\n", .{ moved.counts(), tests.shellKinds(&moved), result.counts(), tests.shellKinds(result) });
    try testing.expectEqual(result.counts(), moved.counts());
    try testing.expectEqual(tests.shellKinds(result), tests.shellKinds(&moved));
    try expectSameMeasures(result, &moved, reach, diag);
}

/// The area and volume of `moved` (a chain's `result` replayed moved) the result's, to the
/// slab the identities allow and the rounding where the move took them (`reach`).
fn expectSameMeasures(result: *const Body, moved: *const Body, reach: f64, diag: *Diagnostics) !void {
    const m = try mass.mass(result, .{}, diag);
    const mm = try mass.mass(moved, .{}, diag);
    const close = IDENTITY_CLOSE * @max(m.volume, 1) + result.tol.xsect * m.area + MOVE_ROUNDING_ULPS * std.math.floatEps(f64) * reach * @max(m.area, 1);
    errdefer std.debug.print("moved: area {d}, volume {d}; the chain's: area {d}, volume {d}\n", .{ mm.area, mm.volume, m.area, m.volume });
    try testing.expectApproxEqAbs(m.area, mm.area, close);
    try testing.expectApproxEqAbs(m.volume, mm.volume, close);
}

/// The chain again with its first solid and every other operand mirrored in x = 0: a
/// mirror rounds nothing, so every step the chain made is made again (sound, its report
/// fitting) and the result's area and volume are the chain's (`expectSameMeasures`, the
/// slab the identities allow). Unlike a rigid move's replay (`expectMovedWhole`), a
/// refusal is a find: no distance moved, so none crossed the tolerance (D27).
pub fn expectMirrored(first: *const Body, steps: []const Step, result: *const Body, reach: f64, diag: *Diagnostics) !void {
    var mirrored = (try mirroredChain(first, steps, diag)) orelse return;
    defer mirrored.deinit();
    try expectSameMeasures(result, &mirrored, reach, diag);
}

/// The chain's step after `steps` refused (`other`, `op`), mirrored as `expectMirrored`
/// has it: refused again, the steps before it made.
pub fn expectMirroredRefused(first: *const Body, steps: []const Step, other: *const Body, op: Op, diag: *Diagnostics) !void {
    var mirrored = (try mirroredChain(first, steps, diag)) orelse return;
    defer mirrored.deinit();
    var other_mirrored = (try mirroredOperand(other, diag)) orelse return;
    defer other_mirrored.deinit();
    var made = pipeline.boolean(testing.allocator, &mirrored, &other_mirrored, op, .{}, diag, null) catch |err| return clean(err);
    made.deinit();
    std.debug.print("mirrored: the {s} the chain refused was made\n", .{@tagName(op)});
    return error.MirrorMade;
}

/// `first` mirrored through `steps`, each step made and sound; null when the mirror of an
/// operand is refused (a size the checker refuses either way, cleanly).
fn mirroredChain(first: *const Body, steps: []const Step, diag: *Diagnostics) !?Body {
    var mirrored = (try mirroredOperand(first, diag)) orelse return null;
    errdefer mirrored.deinit();
    for (steps, 0..) |step, i| {
        var other = (try mirroredOperand(&step.other, diag)) orelse {
            mirrored.deinit();
            return null;
        };
        defer other.deinit();
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        errdefer std.debug.print("mirrored: step {d}, the {s}: {any}\n", .{ i, @tagName(step.op), diag.first() });
        var next = try pipeline.boolean(testing.allocator, &mirrored, &other, step.op, .{}, diag, &report);
        defer next.deinit();
        try expectSolid(&next, diag);
        try tests.expectReportFits(&report, &mirrored, &other, &next, step.op);
        std.mem.swap(Body, &mirrored, &next);
    }
    return mirrored;
}

fn mirroredOperand(body: *const Body, diag: *Diagnostics) !?Body {
    return transform.transform(testing.allocator, body, &Affine.mirror(MIRROR_NORMAL), .{}, diag) catch |err| {
        try clean(err);
        return null;
    };
}

/// A move refused (a solid past the tolerance's reach once moved) ends the check cleanly.
fn refusedMove(err: anyerror) anyerror!void {
    if (err == error.OutOfMemory) return err;
}

test "Fuzz solids: membership finds a union of the right volume misplaced, which the identities pass" {
    // Two boxes overlapping at a corner, their three booleans; then the union moved a
    // quarter along x: every volume the same, so the identities hold, but points of the
    // operands it no longer covers are found outside it
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try @import("../construct/primitives.zig").box(testing.allocator, tolerance.Tolerance.fromZone(1e-5), 2, 2, 2, false, &diag);
    defer a.deinit();
    var b = try transform.transform(testing.allocator, &a, &Affine.translate(.{ 1, 1, 1 }), .{}, &diag);
    defer b.deinit();
    var results: [3]Body = undefined;
    var made: usize = 0;
    defer for (results[0..made]) |*r| r.deinit();
    for (OPS) |op| {
        results[made] = try pipeline.boolean(testing.allocator, &a, &b, op, .{}, &diag, null);
        made += 1;
    }
    try expectMembership(&a, &b, &results, 0, &diag);
    var moved = try transform.transform(testing.allocator, &results[0], &Affine.translate(.{ 0.25, 0, 0 }), .{}, &diag);
    std.mem.swap(Body, &results[0], &moved);
    moved.deinit();
    const fault = (try membershipFault(&a, &b, &results, 0, &diag)).?;
    // A point of a the union no longer covers
    try testing.expectEqual(.inside, fault.places[0]);
    try testing.expectEqual(.outside, fault.places[2]);
}
