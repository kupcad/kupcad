//! The sheet overlap rule: sound sheets pass (a square, a plate with a hole, two squares
//! apart, a sketch boolean's result, the fuzzer's lens sheet as it is built now); a face
//! over another, each in a shell of its own, which the checker passes, fails; so do two
//! faces facing opposite ways. A face whose rings touch where it has no vertex, which the
//! checker passes, fails as not simple; the same touch at a vertex, as a boolean makes it,
//! passes.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const types = @import("../topology/types.zig");
const check = @import("../topology/check.zig");
const sew = @import("../construct/sew.zig");
const primitives = @import("../construct/primitives.zig");
const test_bodies = @import("../construct/test_bodies.zig");
const boolean = @import("boolean.zig");
const overlap = @import("overlap.zig");
const Vec2 = vec.Vec2;
const mat = @import("../math/mat.zig");
const transform = @import("../construct/transform.zig");

const tol = Tolerance.fromZone(1e-5);

fn expectSound(sheet: *const Body) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try overlap.check(testing.allocator, sheet, &diag);
}

test "sheet overlap: a square, a plate with a hole, two squares apart and a boolean's result lie over nothing twice" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var square = try primitives.square(testing.allocator, tol, 4, 4, false, &diag);
    defer square.deinit();
    try expectSound(&square);
    var plate = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } }, &.{ .{ 1, 1 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 2 } } }, &diag);
    defer plate.deinit();
    try expectSound(&plate);
    var apart = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, &.{ .{ 3, 0 }, .{ 4, 0 }, .{ 4, 1 }, .{ 3, 1 } } }, &diag);
    defer apart.deinit();
    try expectSound(&apart);
    var circle = try primitives.circle(testing.allocator, tol, 1.5, &diag);
    defer circle.deinit();
    var joined = try boolean.boolean(testing.allocator, &.{ &square, &circle }, .@"union", .{}, &diag);
    defer joined.deinit();
    try expectSound(&joined);
    // The fuzzer's sheet whose lens lay over its big face until 56b83c22
    var lens_sheet = try test_bodies.ringSheet(testing.allocator, tol, &.{
        &.{ .{ .p = .{ 6, 2 } }, .{ .p = .{ 6, 2 }, .bulge = -1, .ccw = false }, .{ .p = .{ 5, 2 } } },
        &.{ .{ .p = .{ 2, 4 }, .bulge = 1, .ccw = false }, .{ .p = .{ 5, 3 }, .bulge = -1, .ccw = false }, .{ .p = .{ 4, 2 }, .bulge = -1, .ccw = false } },
        &.{ .{ .p = .{ 1, 2 }, .bulge = 1, .ccw = false }, .{ .p = .{ 0, 2 }, .bulge = -0.5, .ccw = false }, .{ .p = .{ 2, 0 } }, .{ .p = .{ 1, 1 } }, .{ .p = .{ 6, 6 }, .bulge = 1, .ccw = false }, .{ .p = .{ 1, 0 } }, .{ .p = .{ 0, 4 } }, .{ .p = .{ 1, 4 } } },
    }, &diag);
    defer lens_sheet.deinit();
    try expectSound(&lens_sheet);
}

/// A sheet of square faces on z = 0, each a face of its own: `[x, y, side, up]`, a face
/// facing down when `up` is 0 (its loop counter-clockwise seen from below).
fn squares(faces: []const [4]f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.Builder.init(testing.allocator, tol, .sheet, &diag);
    defer b.deinit();
    errdefer b.body.deinit();
    const edges = try testing.allocator.alloc([4]sew.EdgeSpec, faces.len);
    defer testing.allocator.free(edges);
    const loops = try testing.allocator.alloc([1]sew.LoopSpec, faces.len);
    defer testing.allocator.free(loops);
    const specs = try testing.allocator.alloc(sew.FaceSpec, faces.len);
    defer testing.allocator.free(specs);
    for (faces, edges, loops, specs) |f, *e, *l, *spec| {
        const up = f[3] != 0;
        var corners: [4]types.VertexIndex = undefined;
        const at = [4]Vec2{ .{ f[0], f[1] }, .{ f[0] + f[2], f[1] }, .{ f[0] + f[2], f[1] + f[2] }, .{ f[0], f[1] + f[2] } };
        for (&corners, 0..) |*v, k| {
            const p = at[if (up) k else 3 - k];
            v.* = try b.vertex(.{ p[0], p[1], 0 });
        }
        for (0..4) |k| e[k] = try b.straight(corners[k], corners[(k + 1) % 4]);
        l.* = .{.{ .edges = e }};
        // The world plane, either way up
        const facing = try b.facingPlane(if (up) geometry.Frame.world else geometry.Frame.init(vec.ZERO3, vec.X3, vec.neg(vec.Z3)), &.{});
        const plane = b.body.geometry.surface(facing.surface).plane;
        var box = geometry.Box2.empty;
        for (at) |p| box.grow(plane.project(.{ p[0], p[1], 0 }));
        spec.* = .{ .surface = facing.surface, .same_sense = facing.same_sense, .loops = l, .uv_box = box };
    }
    return b.finish(specs, .sheet);
}

test "sheet overlap: a face over another, each in a shell of its own, passes the checker and fails this rule" {
    var over = try squares(&.{ .{ 0, 0, 4, 1 }, .{ 1, 1, 1, 1 } });
    defer over.deinit();
    try testing.expectEqual(@as(usize, 2), over.counts().shells);
    var report = try check.run(testing.allocator, &over, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.NotValid, overlap.check(testing.allocator, &over, &diag));
    try testing.expectEqual(.faces_overlap, diag.first().?.code);
    try testing.expectEqual(@as(f64, 2), diag.first().?.measured);
}

test "sheet overlap: two faces apart facing opposite ways fail it" {
    var opposite = try squares(&.{ .{ 0, 0, 1, 1 }, .{ 3, 0, 1, 0 } });
    defer opposite.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.NotValid, overlap.check(testing.allocator, &opposite, &diag));
    try testing.expectEqual(.faces_overlap, diag.first().?.code);
}

/// A 4 by 4 square face with a hole, the circle of radius 1 about `(2, 3 - drop)`, run
/// clockwise from its vertices at its east and west points: at `drop = 0` its rim touches
/// the square's top side at `(2, 4)`, where neither ring has a vertex.
fn squareWithHole(drop: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.Builder.init(testing.allocator, tol, .sheet, &diag);
    defer b.deinit();
    errdefer b.body.deinit();
    var corners: [4]types.VertexIndex = undefined;
    for (&corners, [4]Vec2{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } }) |*v, p| v.* = try b.vertex(.{ p[0], p[1], 0 });
    var outer: [4]sew.EdgeSpec = undefined;
    for (0..4) |k| outer[k] = try b.straight(corners[k], corners[(k + 1) % 4]);
    const c: vec.Vec3 = .{ 2, 3 - drop, 0 };
    const east = try b.vertex(vec.add(c, .{ 1, 0, 0 }));
    const west = try b.vertex(vec.add(c, .{ -1, 0, 0 }));
    // Clockwise seen from above: the circle's frame turned over
    const circle = b.interner.circle(testing.allocator, &b.body.geometry, .{ .c = c, .x = vec.X3, .y = vec.neg(vec.Y3), .r = 1 }) catch |e| return b.fail(e);
    const hole = [2]sew.EdgeSpec{
        .{ .start = east, .end = west, .curve = circle, .t0 = 0, .t1 = std.math.pi },
        .{ .start = west, .end = east, .curve = circle, .t0 = std.math.pi, .t1 = 2 * std.math.pi },
    };
    const plane = try b.plane(geometry.Frame.world, &.{});
    const specs = [1]sew.FaceSpec{.{ .surface = plane, .loops = &.{ .{ .edges = &outer }, .{ .edges = &hole } }, .uv_box = .{ .min = .{ 0, 0 }, .max = .{ 4, 4 } } }};
    return b.finish(&specs, .sheet);
}

test "sheet overlap: a hole touching its face's side where neither ring has a vertex passes the checker and fails as not simple" {
    // The nightly's find (2026-11-16, run 43773180777, locus) left a face whose rings
    // touched where it had no vertex; the checker passed it and the mesher was the first
    // to refuse. The sheet's own overlay finds the touch (coincidence first) and the
    // point it makes is no vertex of the sheet. Within the zone, the same; a hole a
    // hair more than the zone below, sound
    for ([_]f64{ 0, 0.5 * tol.zone }) |drop| {
        var touching = try squareWithHole(drop);
        defer touching.deinit();
        var report = try check.run(testing.allocator, &touching, .global);
        defer report.deinit(testing.allocator);
        try testing.expect(report.ok());
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.NotValid, overlap.check(testing.allocator, &touching, &diag));
        try testing.expectEqual(.not_simple, diag.first().?.code);
        try testing.expectEqual(@as(f64, 1), diag.first().?.measured);
    }
    var clear = try squareWithHole(2 * tol.zone);
    defer clear.deinit();
    try expectSound(&clear);
}

test "sheet overlap: a circle cut from a square touching its side leaves a vertex at the touch, and passes" {
    // The touch as the boolean makes it: the face's rings meet at a vertex of both, where
    // the arcs and the side stay within the zone of each other for √(2·r·zone) on either
    // side (a nearness rule would have taken that for a fault)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var square = try primitives.square(testing.allocator, tol, 4, 4, false, &diag);
    defer square.deinit();
    var disc0 = try primitives.circle(testing.allocator, tol, 1, &diag);
    defer disc0.deinit();
    var disc = try transform.transform(testing.allocator, &disc0, &mat.Affine.translate(.{ 2, 3, 0 }), .{}, &diag);
    defer disc.deinit();
    var cut = try boolean.boolean(testing.allocator, &.{ &square, &disc }, .difference, .{}, &diag);
    defer cut.deinit();
    var at_touch: usize = 0;
    for (cut.vertices.items) |v| {
        if (v.tombstone) continue;
        at_touch += @intFromBool(vec.distance(cut.geometry.points.items[@backingInt(v.point)], .{ 2, 4, 0 }) <= tol.zone);
    }
    try testing.expectEqual(@as(usize, 1), at_touch);
    try expectSound(&cut);
}
