//! The first three phases alone on two boxes overlapping at a corner, `a` from 0 to 2 on
//! each axis and `b` from 1 to 3, whose answers are counted by hand: the paves (merged
//! vertices, crossings, section segments), the fragments each face splits into, and their
//! classes; and on two boxes sharing a plane, the coplanar pairs and the same-domain
//! classes.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const mat = @import("../math/mat.zig");
const in_face = @import("../query/in_face.zig");
const pave = @import("pave.zig");
const imprint = @import("imprint.zig");
const classify = @import("classify.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
/// Where each run of the paves is; the refusal test reads it.
var stage: pave.Stage = .vertex_vertex;

fn box(lo: Vec3, hi: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var unit = try primitives.box(testing.allocator, tol, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], false, &diag);
    defer unit.deinit();
    return transform.transform(testing.allocator, &unit, &mat.Affine.translate(lo), .{}, &diag);
}

/// The face of `body` facing along `normal`.
fn facing(body: *const Body, normal: Vec3) u32 {
    for (body.faces.items, 0..) |f, i| {
        if (f.flags.tombstone) continue;
        if (vec.dot(in_face.outwardNormal(body, types.FaceIndex.of(i), .{ 0, 0 }), normal) > 0.5) return @intCast(i);
    }
    unreachable;
}

test "paves: two boxes at a corner, sixteen vertices and six crossings, two section segments on each notched face" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    // Each of the three edges of `b` from its corner inside `a` leaves through a face of
    // `a`, and each of `a`'s from its corner inside `b` enters through a face of `b`
    try testing.expectEqual(@as(usize, 16 + 6), p.points.items.len);
    var crossings: usize = 0;
    for (p.owners.items) |o| crossings += @intFromBool(o == 0);
    try testing.expectEqual(@as(usize, 6), crossings);
    // Every edge of `a` from (2, 2, 2) has one crossing inside it, at its middle
    var split: usize = 0;
    for (p.edge_paves[0]) |list| {
        if (list.items.len == 3) {
            split += 1;
            try testing.expectApproxEqAbs(@as(f64, 0.5), list.items[1].s, 1e-12);
        } else try testing.expectEqual(@as(usize, 2), list.items.len);
    }
    try testing.expectEqual(@as(usize, 3), split);
    // The faces of `a` at x, y, z = 2 each take two segments of `b`'s faces; the others none
    for ([_]Vec3{ vec.X3, vec.Y3, vec.Z3 }) |n| {
        try testing.expectEqual(@as(usize, 2), p.sections[0][facing(&a, n)].items.len);
        try testing.expectEqual(@as(usize, 0), p.sections[0][facing(&a, vec.neg(n))].items.len);
        try testing.expectEqual(@as(usize, 2), p.sections[1][facing(&b, vec.neg(n))].items.len);
    }
    try testing.expectEqual(@as(usize, 0), p.coplanar.items.len);

    // Imprinted: the three notched faces of each box in two, the rest whole
    var fragments = try imprint.run(testing.allocator, &p, .{}, &diag);
    defer fragments.deinit();
    try testing.expectEqual(@as(usize, 2 * (3 + 3 * 2)), fragments.items.items.len);
    // Classified: of each box, the three unit squares inside the other
    var stats: classify.Stats = .{};
    const classes = try classify.run(testing.allocator, &p, &fragments, .{}, true, &diag, &stats);
    defer testing.allocator.free(classes);
    var inside = [2]usize{ 0, 0 };
    for (fragments.items.items, classes) |f, c| {
        try testing.expect(c.class == .inside or c.class == .outside);
        inside[f.operand] += @intFromBool(c.class == .inside);
    }
    try testing.expectEqual([2]usize{ 3, 3 }, inside);
}

test "paves: boxes on one plane pair their faces there, and the shared part is the same domain" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 1, 0 }, .{ 3, 3, 1 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    // Tops with tops and bottoms with bottoms; no side lies in another's plane
    try testing.expectEqual(@as(usize, 2), p.coplanar.items.len);
    var fragments = try imprint.run(testing.allocator, &p, .{}, &diag);
    defer fragments.deinit();
    var stats: classify.Stats = .{};
    const classes = try classify.run(testing.allocator, &p, &fragments, .{}, true, &diag, &stats);
    defer testing.allocator.free(classes);
    // Each top and bottom: the shared unit square, on the other's face facing the same way
    var same: usize = 0;
    for (classes) |c| {
        try testing.expect(c.class != .on_opposite);
        same += @intFromBool(c.class == .on_same);
        // A coincident piece names the face it lies on
        try testing.expectEqual(c.class == .on_same, c.partner != classify.NONE);
    }
    try testing.expectEqual(@as(usize, 4), same);
}

test "paves: a box resting on another meets it face to face, the same domain facing the other way" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    var b = try box(.{ 0.5, 0.5, 1 }, .{ 1.5, 1.5, 2 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.coplanar.items.len);
    // The resting box's corners lie on the top's face, inside it
    try testing.expectEqual(@as(usize, 16), p.points.items.len);
    var fragments = try imprint.run(testing.allocator, &p, .{}, &diag);
    defer fragments.deinit();
    var stats: classify.Stats = .{};
    const classes = try classify.run(testing.allocator, &p, &fragments, .{}, true, &diag, &stats);
    defer testing.allocator.free(classes);
    var opposite: usize = 0;
    for (classes) |c| opposite += @intFromBool(c.class == .on_opposite);
    // The square under the resting box, and the resting box's bottom
    try testing.expectEqual(@as(usize, 2), opposite);
}

test "paves: boxes overlapping along four edges have four common blocks; at a corner none" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 1, 0, 0 }, .{ 3, 2, 2 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage);
    defer p.deinit();
    // Each of the four edges along x where y and z are 0 or 2: from x = 1 to 2 in both
    try testing.expectEqual(@as(usize, 4), p.common.items.len);
    for (p.common.items) |block| {
        try testing.expectApproxEqAbs(@as(f64, 1), vec.distance(p.point(block.vertices[0]), p.point(block.vertices[1])), 1e-12);
    }
    var c = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer c.deinit();
    var q = try pave.run(testing.allocator, &a, &c, tol, .{}, &diag, &stage);
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.common.items.len);
}

test "paves: an edge whose shrunk range is under twice the tolerance is not split, but refused" {
    // A slab three intersection tolerances thick, cut through the middle of its height:
    // each vertical edge would be split a tolerance and a half from either end
    const xsect = tol.xsect;
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 3 * xsect });
    defer a.deinit();
    var b = try box(.{ 0.25, 0.25, 1.5 * xsect }, .{ 2, 2, 1 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.TooSmallEdge, pave.run(testing.allocator, &a, &b, tol, .{}, &diag, &stage));
    const f = diag.first().?;
    try testing.expectEqual(diagnostics.Code.edge_too_short, f.code);
    try testing.expectEqual(diagnostics.EntityKind.edge, f.entity.kind);
    // Refused in the class that would have split it, which the finding names
    try testing.expectEqual(pave.Stage.edge_face, stage);
    try testing.expect(std.mem.indexOf(u8, f.label, "(edge–face)") != null);
}
