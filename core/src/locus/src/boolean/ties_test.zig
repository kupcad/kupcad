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
const pipeline = @import("pipeline.zig");
const helpers = @import("pipeline_test.zig");
const degeneracy = @import("degeneracy_test.zig");
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

/// What a boolean of two solids gives: a refusal's code, or the made solid's counts and
/// its shells' kinds, the solid checked sound.
const Outcome = struct {
    code: ?diagnostics.Code = null,
    counts: ?@TypeOf(@as(Body, undefined).counts()) = null,
    kinds: [2]usize = .{ 0, 0 },

    fn of(a: *const Body, b: *const Body, op: pipeline.Op) !Outcome {
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
        return .{ .counts = made.counts(), .kinds = helpers.shellKinds(&made) };
    }
};

/// `body` moved as `move` has it.
fn moved(body: *const Body, move: @TypeOf(MOVES[0])) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const affine = mat.Affine.translate(move.shift).compose(&mat.Affine.rotate(vec.normalized(move.axis).?, move.angle));
    return transform.transform(testing.allocator, body, &affine, .{}, &diag);
}

/// Each operation of `a` and `b`, and of `b` and `a`, moved whole by every one of `MOVES`,
/// as it is in place: made alike or refused with one code; the union and the intersection
/// alike either way round too. Every case that differs is printed before the test fails.
fn expectAlikeSwappedAndMoved(a: *const Body, b: *const Body) !void {
    var differing: usize = 0;
    for (OPS) |op| {
        const want = [2]Outcome{ try Outcome.of(a, b, op), try Outcome.of(b, a, op) };
        if (op != .difference and !std.meta.eql(want[0], want[1])) {
            std.debug.print("{s} in place: {any} one way round, {any} the other\n", .{ @tagName(op), want[0], want[1] });
            differing += 1;
        }
        for (MOVES[1..], 1..) |move, k| {
            var ma = try moved(a, move);
            defer ma.deinit();
            var mb = try moved(b, move);
            defer mb.deinit();
            for ([2]bool{ false, true }) |swapped| {
                const got = if (swapped) try Outcome.of(&mb, &ma, op) else try Outcome.of(&ma, &mb, op);
                if (std.meta.eql(want[@intFromBool(swapped)], got)) continue;
                std.debug.print("{s}, move {d}, swapped {}: want {any}, got {any}\n", .{ @tagName(op), k, swapped, want[@intFromBool(swapped)], got });
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
