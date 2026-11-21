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

/// How far the box's side (x) and its bottom edge's line (y) are moved in the family about
/// be: the two ends across the faces' line 3.2e-5 apart in the find, closer and farther by
/// half a zone and a zone.
const BE_SHIFTS = [_]f64{ -1e-5, 0, 1e-5 };

/// What a boolean of two solids gives: a refusal's code, or the made solid's counts, its
/// shells' kinds and its points (each vertex; each edge's curve at the middle of its range,
/// which a joined edge's line decides; each planar face's corners' centroid on its plane,
/// which the plane a group of faces takes decides, its vertices staying within their
/// gaps of it), moved back by the move the operands took, the solid checked sound.
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
        for (MOVES[1..], 1..) |move, k| {
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
