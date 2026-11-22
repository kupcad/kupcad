const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("primitives.zig");
const transform = @import("transform.zig");
const bbox = @import("../topology/bbox.zig");
const body_json = @import("../io/body_json.zig");
const pipeline = @import("../boolean/pipeline.zig");
const overlap = @import("../query/overlap.zig");
const Affine = mat.Affine;
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);
/// How high over a box's top a second box rests in the tests of a union scaled: within the
/// intersection tolerance (the union holds its bottom's outline in the first box's top, up
/// to that far off its plane, with no gap), and the factors it is scaled by.
const STACK_LIFTS = [_]f64{ 1e-5, 1.5e-5, 1.9e-5 };
const STACK_SCALES = [_]f64{ 2, 3, 0.5 };
/// A tetrahedron on the unit right triangle, its apex `LOW_RISE` over (0.3, 0.3): sound
/// (past twice the intersection tolerance), and the factors along z that bring it under the
/// tolerance (its sides then in its base's plane) or keep it past.
const LOW_RISE: f64 = 5e-5;
const LOW_SQUASH_THIN = [_]f64{ 0.3, 0.38 };
const LOW_SQUASH_APART = [_]f64{0.5};
/// A C-shaped sheet whose slit is `C_SLIT` across (past the zone), and the factors across
/// the slit that close it under the zone or keep it open.
const C_SLIT: f64 = 3e-5;
const C_SQUASH_SHUT = [_]f64{0.25};
const C_SQUASH_OPEN = [_]f64{0.8};

fn expectVec(expected: Vec3, actual: Vec3, t: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], t);
}

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

test "transform: a box moved, turned and scaled keeps its topology and moves its bounds" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer b.deinit();
    var moved = try transform.transform(testing.allocator, &b, &Affine.translate(.{ 10, 0, -1 }), .{}, &diag);
    defer moved.deinit();
    try testing.expectEqual(b.counts(), moved.counts());
    try expectValid(&moved);
    const mbox = try bbox.bodyBounds(&moved);
    try expectVec(.{ 10, 0, -1 }, mbox.min, 1e-12);
    try expectVec(.{ 12, 3, 3 }, mbox.max, 1e-12);
    // The input is untouched
    const obox = try bbox.bodyBounds(&b);
    try expectVec(.{ 0, 0, 0 }, obox.min, 0);

    var turned = try transform.transform(testing.allocator, &b, &Affine.rotate(vec.Z3, std.math.pi / 2.0), .{}, &diag);
    defer turned.deinit();
    try expectValid(&turned);
    const tbox = try bbox.bodyBounds(&turned);
    try expectVec(.{ -3, 0, 0 }, tbox.min, 1e-12);
    try expectVec(.{ 0, 2, 4 }, tbox.max, 1e-12);

    var scaled = try transform.transform(testing.allocator, &b, &Affine.scaleBy(.{ 2, 2, 2 }), .{}, &diag);
    defer scaled.deinit();
    try expectValid(&scaled);
    const sbox = try bbox.bodyBounds(&scaled);
    try expectVec(.{ 4, 6, 8 }, sbox.max, 1e-12);
    // Edge ranges scaled with the lines' parameter
    var longest: f64 = 0;
    for (scaled.edges.items) |e| longest = @max(longest, e.t1 - e.t0);
    try testing.expectApproxEqAbs(@as(f64, 8), longest, 1e-12);
}

test "transform: a cylinder scaled keeps its pcurves lifting; a stretch is refused, a box's is exact" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var c = try primitives.cylinder(testing.allocator, tol, 2, 5, false, &diag);
    defer c.deinit();
    var scaled = try transform.transform(testing.allocator, &c, &Affine.scaleBy(.{ 3, 3, 3 }), .{}, &diag);
    defer scaled.deinit();
    try expectValid(&scaled);
    try testing.expectApproxEqAbs(@as(f64, 6), scaled.geometry.cylinders.items[0].r, 1e-12);
    const sbox = try bbox.bodyBounds(&scaled);
    try expectVec(.{ -6, -6, 0 }, sbox.min, 1e-12);
    try expectVec(.{ 6, 6, 15 }, sbox.max, 1e-12);
    // A turned, moved and scaled cylinder, all at once
    const all = Affine.translate(.{ 1, 2, 3 }).compose(&Affine.rotate(vec.normalized(.{ 1, 1, 0 }).?, 0.4)).compose(&Affine.scaleBy(.{ 0.5, 0.5, 0.5 }));
    var any = try transform.transform(testing.allocator, &c, &all, .{}, &diag);
    defer any.deinit();
    try expectValid(&any);

    try testing.expectError(error.NotRepresentable, transform.transform(testing.allocator, &c, &Affine.scaleBy(.{ 2, 1, 1 }), .{}, &diag));
    try testing.expectError(error.InvalidInput, transform.transform(testing.allocator, &c, &Affine.scaleBy(.{ 0, 1, 1 }), .{}, &diag));

    var b = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer b.deinit();
    var stretched = try transform.transform(testing.allocator, &b, &Affine.scaleBy(.{ 2, 1, 0.5 }), .{}, &diag);
    defer stretched.deinit();
    try expectValid(&stretched);
    const bx = try bbox.bodyBounds(&stretched);
    try expectVec(.{ 4, 3, 2 }, bx.max, 1e-12);
}

test "transform: a mirror flips every sense, keeps the body valid, and undoes itself" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var c = try primitives.cylinder(testing.allocator, tol, 2, 5, false, &diag);
    defer c.deinit();
    const mirror = Affine.mirror(vec.X3);
    var m = try transform.transform(testing.allocator, &c, &mirror, .{}, &diag);
    defer m.deinit();
    try expectValid(&m);
    for (m.faces.items) |f| try testing.expect(!f.same_sense);
    for (c.faces.items) |f| try testing.expect(f.same_sense);
    try testing.expectEqual(@as(f64, -1), m.geometry.cylinders.items[0].frame.sign());
    const mbox = try bbox.bodyBounds(&m);
    try expectVec(.{ -2, -2, 0 }, mbox.min, 1e-12);
    try expectVec(.{ 2, 2, 5 }, mbox.max, 1e-12);
    // Mirrored again: the original, byte for byte (an axis mirror is exact)
    var back = try transform.transform(testing.allocator, &m, &mirror, .{}, &diag);
    defer back.deinit();
    const before = try body_json.dump(testing.allocator, &c);
    defer testing.allocator.free(before);
    const after = try body_json.dump(testing.allocator, &back);
    defer testing.allocator.free(after);
    errdefer {
        var la = std.mem.splitScalar(u8, before, '\n');
        var lb = std.mem.splitScalar(u8, after, '\n');
        var n: usize = 0;
        while (la.next()) |x| : (n += 1) {
            const y = lb.next() orelse break;
            if (!std.mem.eql(u8, x, y)) {
                std.debug.print("line {d}:\n  before: {s}\n  after:  {s}\n", .{ n, x, y });
                break;
            }
        }
    }
    try testing.expectEqualStrings(before, after);
    // A mirrored sheet too
    var sq = try primitives.square(testing.allocator, tol, 2, 1, false, &diag);
    defer sq.deinit();
    var msq = try transform.transform(testing.allocator, &sq, &Affine.mirror(vec.Y3), .{}, &diag);
    defer msq.deinit();
    try expectValid(&msq);
    const qbox = try bbox.bodyBounds(&msq);
    try expectVec(.{ 0, -1, 0 }, qbox.min, 1e-12);
}

test "transform: the cancel flag is honoured before any work" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b = try primitives.box(testing.allocator, tol, 1, 1, 1, false, &diag);
    defer b.deinit();
    var flag = std.atomic.Value(bool).init(true);
    try testing.expectError(error.Canceled, transform.transform(testing.allocator, &b, &Affine.identity, .{ .cancel = &flag }, &diag));
    try testing.expectEqual(@as(usize, 0), diag.failures());
}

test "transform: every face keeps its attribute through a move, a turn, a scale and a mirror" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 1, 2, 3, false, &diag);
    defer box.deinit();
    for (box.faces.items, 0..) |*f, i| f.attribute = @intCast(i + 1);
    const moves = [_]Affine{ Affine.translate(.{ 1, 2, 3 }), Affine.rotate(vec.normalized(.{ 1, 1, 0 }).?, 0.4), Affine.scaleBy(.{ 2, 2, 2 }), Affine.mirror(vec.X3) };
    for (moves) |affine| {
        var moved = try transform.transform(testing.allocator, &box, &affine, .{}, &diag);
        defer moved.deinit();
        try testing.expectEqual(box.faces.items.len, moved.faces.items.len);
        for (box.faces.items, moved.faces.items) |a, b| try testing.expectEqual(a.attribute, b.attribute);
    }
}

/// Box `size` placed with its least corner at `at`.
fn boxAt(at: Vec3, size: Vec3, diag: *Diagnostics) !Body {
    var b = try primitives.box(testing.allocator, tol, size[0], size[1], size[2], false, diag);
    defer b.deinit();
    return transform.transform(testing.allocator, &b, &Affine.translate(at), .{}, diag);
}

test "transform: a union with a box resting within the tolerance, scaled, keeps every relation at the scaled tolerance" {
    // A uniform scale multiplies every gap by its factor and kept the body's tolerance: the
    // union holds the upper box's bottom outline in the lower's top up to the intersection
    // tolerance off its plane with no gap, and scaled by 2 those edges lay 3e-5 off it
    // against 2e-5 (`edge_off_surface`). OCCT's BRepTools_TrsfModification scales every
    // tolerance with the shape: so the scaled body's
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try boxAt(.{ 0, 0, 0 }, .{ 2, 2, 2 }, &diag);
    defer a.deinit();
    for (STACK_LIFTS) |lift| {
        var b = try boxAt(.{ 1, 0, 2 + lift }, .{ 2, 2, 2 - lift }, &diag);
        defer b.deinit();
        var joined = try pipeline.boolean(testing.allocator, &a, &b, .@"union", .{}, &diag, null);
        defer joined.deinit();
        for (STACK_SCALES) |k| {
            errdefer std.debug.print("lift {e}, scale {d}: {any}\n", .{ lift, k, diag.first() });
            var scaled = try transform.transform(testing.allocator, &joined, &Affine.scaleBy(.{ k, k, k }), .{}, &diag);
            defer scaled.deinit();
            try expectValid(&scaled);
            try testing.expectApproxEqRel(k * tol.zone, scaled.tol.zone, 1e-12);
            try testing.expectApproxEqRel(k * tol.xsect, scaled.tol.xsect, 1e-12);
        }
    }
}

/// The low tetrahedron's points, its triangles wound outward.
const LOW_TRIANGLES = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 } };

test "transform: a stretch that brings a solid's faces within the tolerance of each other is refused below the feature size" {
    // A non-uniform scale keeps the body's tolerance and changes distances unevenly: a
    // tetrahedron 5e-5 high squashed to 1.5e-5 has its sides in its base's plane, faces on
    // each other, which every operation making a solid refuses (`overlap.refuseMade`)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0.3, 0.3, LOW_RISE } };
    var low = try primitives.polyhedron(testing.allocator, tol, &points, &LOW_TRIANGLES, &diag);
    defer low.deinit();
    for (LOW_SQUASH_THIN) |k| {
        errdefer std.debug.print("squash {d}\n", .{k});
        try testing.expectError(error.Degenerate, transform.transform(testing.allocator, &low, &Affine.scaleBy(.{ 1, 1, k }), .{}, &diag));
        try testing.expectEqual(.below_feature_size, diag.first().?.code);
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
    }
    for (LOW_SQUASH_APART) |k| {
        var squashed = try transform.transform(testing.allocator, &low, &Affine.scaleBy(.{ 1, 1, k }), .{}, &diag);
        defer squashed.deinit();
        try expectValid(&squashed);
        try overlap.check(testing.allocator, &squashed, .{}, &diag);
    }
}

test "transform: a stretch that closes a sheet's slit under the zone is refused, as the overlay's sheets cannot be" {
    // A sheet is otherwise always the overlay's, which keeps its edges past the zone; a
    // stretch across a slit 3e-5 wide to a quarter left it 7.5e-6, edges of one sheet
    // within the zone that a later overlay would weld shut without a word
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // The slit's end askew, so that no squash makes it an edge shorter than a sheet's
    const c = [_]vec.Vec2{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 1 }, .{ 0.5, 1 }, .{ 0.6, 1 + C_SLIT }, .{ 2, 1 + C_SLIT }, .{ 2, 2 }, .{ 0, 2 } };
    var sheet = try primitives.polygon(testing.allocator, tol, &c, &diag);
    defer sheet.deinit();
    for (C_SQUASH_SHUT) |k| {
        errdefer std.debug.print("squash {d}: {any}\n", .{ k, diag.first() });
        // Its slit's corners within the zone of each other (`vertices_too_close`), or its
        // edges (`below_feature_size`), whichever is found first
        try testing.expectError(error.Degenerate, transform.transform(testing.allocator, &sheet, &Affine.scaleBy(.{ 1, k, 1 }), .{}, &diag));
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
    }
    for (C_SQUASH_OPEN) |k| {
        var squashed = try transform.transform(testing.allocator, &sheet, &Affine.scaleBy(.{ 1, k, 1 }), .{}, &diag);
        defer squashed.deinit();
        try overlap.check(testing.allocator, &squashed, .{}, &diag);
    }
}
