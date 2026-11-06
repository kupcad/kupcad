//! Extrusions of the sketch faces: the counts, the checker, the bounds, and every face's
//! outward normal pointing away from the material (what the checker's orientation rules
//! do not yet test).

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("primitives.zig");
const sweep = @import("sweep.zig");
const bbox = @import("../measure/bbox.zig");
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);

fn expectValid(body: *const Body) !void {
    var report = try check.run(testing.allocator, body, .geometric);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try f.format(&w);
        std.debug.print("checker: {s}\n", .{w.buffered()});
    }
    try testing.expect(report.ok());
}

fn expectCounts(body: *const Body, vertices: usize, edges: usize, faces: usize, loops: usize) !void {
    const c = body.counts();
    try testing.expectEqual(vertices, c.vertices);
    try testing.expectEqual(edges, c.edges);
    try testing.expectEqual(faces, c.faces);
    try testing.expectEqual(loops, c.loops);
}

fn expectVec(expected: Vec3, actual: Vec3, t: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], t);
}

/// Every face's outward normal at the middle of its UV box points away from `inside`, a
/// point of the material, except the faces of `hole_center`'s hole, which point toward it.
fn expectOutward(body: *const Body, inside: Vec3, hole_center: ?Vec3) !void {
    for (body.faces.items) |f| {
        if (f.flags.tombstone) continue;
        const s = body.geometry.surface(f.surface);
        const u = (f.uv_box.min[0] + f.uv_box.max[0]) / 2.0;
        const v = (f.uv_box.min[1] + f.uv_box.max[1]) / 2.0;
        const p = s.eval(u, v);
        const n = vec.scale(s.normal(u, v), if (f.same_sense) @as(f64, 1) else -1);
        var away = vec.dot(n, vec.sub(p, inside)) > 0;
        if (hole_center) |h| {
            // A face of the hole: nearer the hole's axis than the outside is
            const d = vec.sub(p, h);
            if (@sqrt(d[0] * d[0] + d[1] * d[1]) < 4.0 and @abs(n[2]) < 0.5) away = vec.dot(n, .{ d[0], d[1], 0 }) < 0;
        }
        try testing.expect(away);
    }
}

test "extrude: a square is a box, a circle a cylinder, each outward" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 2, 3, false, &diag);
    defer sq.deinit();
    var box = try sweep.extrude(testing.allocator, &sq, .{ 0, 0, 4 }, .{}, &diag);
    defer box.deinit();
    try expectCounts(&box, 8, 12, 6, 6);
    try expectValid(&box);
    const bb = try bbox.bodyBounds(&box);
    try expectVec(.{ 0, 0, 0 }, bb.min, 1e-12);
    try expectVec(.{ 2, 3, 4 }, bb.max, 1e-12);
    try expectOutward(&box, .{ 1, 1.5, 2 }, null);
    try testing.expectEqual(@as(usize, 6), box.geometry.planes.items.len);

    var ci = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer ci.deinit();
    var cyl = try sweep.extrude(testing.allocator, &ci, .{ 0, 0, 5 }, .{}, &diag);
    defer cyl.deinit();
    try expectCounts(&cyl, 4, 6, 4, 4);
    try expectValid(&cyl);
    const cb = try bbox.bodyBounds(&cyl);
    try expectVec(.{ -2, -2, 0 }, cb.min, 1e-12);
    try expectVec(.{ 2, 2, 5 }, cb.max, 1e-12);
    try expectOutward(&cyl, .{ 0, 0, 2.5 }, null);
    try testing.expectEqual(@as(usize, 1), cyl.geometry.cylinders.items.len);
    for (cyl.coedges.items) |c| {
        const on_side = cyl.face(cyl.loop(c.loop).face).surface.kind == .cylinder;
        try testing.expectEqual(on_side, !c.pcurve.isNone());
    }
}

test "extrude: a plate with a hole has the hole through it; downward and askew sweeps stay outward" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]vec.Vec2{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_]vec.Vec2{ .{ -2, -2 }, .{ -2, 2 }, .{ 2, 2 }, .{ 2, -2 } };
    var plate = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer plate.deinit();
    var solid = try sweep.extrude(testing.allocator, &plate, .{ 0, 0, 3 }, .{}, &diag);
    defer solid.deinit();
    try expectCounts(&solid, 16, 24, 10, 12);
    try expectValid(&solid);
    try expectOutward(&solid, .{ 6, 6, 1.5 }, .{ 0, 0, 0 });

    // Downward: the same solid below the plane
    var down = try sweep.extrude(testing.allocator, &plate, .{ 0, 0, -3 }, .{}, &diag);
    defer down.deinit();
    try expectCounts(&down, 16, 24, 10, 12);
    try expectValid(&down);
    const db = try bbox.bodyBounds(&down);
    try expectVec(.{ -10, -10, -3 }, db.min, 1e-12);
    try expectVec(.{ 10, 10, 0 }, db.max, 1e-12);
    try expectOutward(&down, .{ 6, 6, -1.5 }, .{ 0, 0, 0 });

    // Askew: a circle's side is an extrusion surface, a square's are planes
    var ci = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer ci.deinit();
    var skew = try sweep.extrude(testing.allocator, &ci, .{ 1, 0, 4 }, .{}, &diag);
    defer skew.deinit();
    try expectCounts(&skew, 4, 6, 4, 4);
    try expectValid(&skew);
    try testing.expectEqual(@as(usize, 2), skew.geometry.extrusions.items.len);
    try expectOutward(&skew, .{ 0.5, 0, 2 }, null);

    // Refusals: no rise, a solid as a profile
    try testing.expectError(error.InvalidInput, sweep.extrude(testing.allocator, &plate, .{ 1, 0, 0 }, .{}, &diag));
    try testing.expectError(error.InvalidInput, sweep.extrude(testing.allocator, &solid, .{ 0, 0, 1 }, .{}, &diag));
    try testing.expectError(error.InvalidInput, sweep.extrude(testing.allocator, &plate, .{ 0, 0, 0 }, .{}, &diag));
}
