//! Sketch booleans and the even-odd fill: counts, the checker, and areas against closed
//! forms, on squares and circles, and the fills of nested and self-crossing outlines.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const mass = @import("../measure/mass.zig");
const boolean = @import("boolean.zig");
const offset_mod = @import("offset.zig");
const test_bodies = @import("../construct/test_bodies.zig");
const Vec2 = vec.Vec2;

const tol = Tolerance.fromZone(1e-5);
const PI = std.math.pi;

fn areaOf(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).area;
}

fn expectCounts(body: *const Body, vertices: usize, edges: usize, faces: usize, loops: usize) !void {
    const c = body.counts();
    try testing.expectEqual(vertices, c.vertices);
    try testing.expectEqual(edges, c.edges);
    try testing.expectEqual(faces, c.faces);
    try testing.expectEqual(loops, c.loops);
}

fn moved(sheet: *const Body, dx: f64, dy: f64, diag: *Diagnostics) !Body {
    return transform.transform(testing.allocator, sheet, &mat.Affine.translate(.{ dx, dy, 0 }), .{}, diag);
}

test "sketch booleans: two squares overlapping at a corner" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try primitives.square(testing.allocator, tol, 2, 2, false, &diag);
    defer a.deinit();
    var b = try moved(&a, 1, 1, &diag);
    defer b.deinit();

    var u = try boolean.boolean(testing.allocator, &.{ &a, &b }, .@"union", .{}, &diag);
    defer u.deinit();
    try expectCounts(&u, 8, 8, 1, 1);
    try testing.expectApproxEqRel(@as(f64, 7), try areaOf(&u), 1e-12);

    var d = try boolean.boolean(testing.allocator, &.{ &a, &b }, .difference, .{}, &diag);
    defer d.deinit();
    try expectCounts(&d, 6, 6, 1, 1);
    try testing.expectApproxEqRel(@as(f64, 3), try areaOf(&d), 1e-12);

    var x = try boolean.boolean(testing.allocator, &.{ &a, &b }, .intersection, .{}, &diag);
    defer x.deinit();
    try expectCounts(&x, 4, 4, 1, 1);
    try testing.expectApproxEqRel(@as(f64, 1), try areaOf(&x), 1e-12);

    // Apart: a union of two faces, an empty intersection
    var far = try moved(&a, 5, 0, &diag);
    defer far.deinit();
    var two = try boolean.boolean(testing.allocator, &.{ &a, &far }, .@"union", .{}, &diag);
    defer two.deinit();
    try expectCounts(&two, 8, 8, 2, 2);
    try testing.expectEqual(@as(usize, 2), two.counts().shells);
    // A difference that cuts a plate in two: two shells, and extruded, two solids
    var plate = try primitives.square(testing.allocator, tol, 10, 10, false, &diag);
    defer plate.deinit();
    var bar = try primitives.square(testing.allocator, tol, 2, 20, false, &diag);
    defer bar.deinit();
    var bar_across = try moved(&bar, 4, -5, &diag);
    defer bar_across.deinit();
    var halves = try boolean.boolean(testing.allocator, &.{ &plate, &bar_across }, .difference, .{}, &diag);
    defer halves.deinit();
    try testing.expectEqual(@as(usize, 2), halves.counts().shells);
    const sweep = @import("../construct/sweep.zig");
    var blocks = try sweep.extrude(testing.allocator, &halves, .{ 0, 0, 1 }, .{}, &diag);
    defer blocks.deinit();
    try testing.expectEqual(@as(usize, 2), blocks.counts().shells);
    const step_write = @import("../io/step_write.zig");
    const text = try step_write.write(testing.allocator, &.{&blocks});
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "=MANIFOLD_SOLID_BREP("));
    try testing.expectApproxEqRel(@as(f64, 80), (try mass.mass(&blocks, .{}, &diag)).volume, 1e-12);
    var none = try boolean.boolean(testing.allocator, &.{ &a, &far }, .intersection, .{}, &diag);
    defer none.deinit();
    try testing.expect(none.isEmpty());
    try testing.expectEqual(@import("../topology/body.zig").Kind.sheet, none.kind);
}

test "sketch booleans: a hole cut, filled back, and a batch of three" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var plate = try primitives.square(testing.allocator, tol, 10, 10, false, &diag);
    defer plate.deinit();
    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    var hole = try moved(&disc, 5, 5, &diag);
    defer hole.deinit();
    var pierced = try boolean.boolean(testing.allocator, &.{ &plate, &hole }, .difference, .{}, &diag);
    defer pierced.deinit();
    try expectCounts(&pierced, 6, 6, 1, 2);
    try testing.expectApproxEqRel(100 - PI * 4, try areaOf(&pierced), 1e-12);
    // The hole's arcs run clockwise: filled back, the plate is whole again
    var filled = try boolean.boolean(testing.allocator, &.{ &pierced, &hole }, .@"union", .{}, &diag);
    defer filled.deinit();
    try expectCounts(&filled, 4, 4, 1, 1);
    try testing.expectApproxEqRel(@as(f64, 100), try areaOf(&filled), 1e-12);
    // Three overlapping discs along a line, united and intersected
    var left = try moved(&disc, 1, 0, &diag);
    defer left.deinit();
    var middle = try moved(&disc, 2, 0, &diag);
    defer middle.deinit();
    var right = try moved(&disc, 3, 0, &diag);
    defer right.deinit();
    var chain = try boolean.boolean(testing.allocator, &.{ &left, &middle, &right }, .@"union", .{}, &diag);
    defer chain.deinit();
    try testing.expectEqual(@as(usize, 1), chain.counts().faces);
    var core = try boolean.boolean(testing.allocator, &.{ &left, &middle, &right }, .intersection, .{}, &diag);
    defer core.deinit();
    try testing.expectEqual(@as(usize, 1), core.counts().faces);
    // The lens of the two outer discs, two apart with radius 2: 8π/3 − 2√3
    try testing.expectApproxEqRel(8 * PI / 3.0 - 2 * @sqrt(3.0), try areaOf(&core), 1e-12);
}

test "sketch booleans: an arc tangent to a line at a shared vertex keeps the faces between them" {
    // A round offset's arc arrives at (1, 1) tangent to the other sheet's edge along
    // y = 1: both leave the vertex westward, the arc curving north. Their order about the
    // vertex once fell across the ±π seam of an angle, and the faces between them were
    // lost from the union and the intersection. The identities hold, and the intersection
    // is what sampling the two regions gives.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const a0 = [_]Vec2{ .{ 1, 2 }, .{ 3, 2 }, .{ 1, 2 }, .{ 6, 2 }, .{ 4, 4 } };
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{&a0}, &diag);
    defer sheet.deinit();
    var grown = try offset_mod.offset(testing.allocator, &sheet, 1, .round, 2, .{}, &diag);
    defer grown.deinit();
    const b0 = [_]Vec2{ .{ 3, 5 }, .{ 1, 2 }, .{ 1, 6 }, .{ 1, 4 } };
    const b1 = [_]Vec2{ .{ 6, 5 }, .{ 4, 1 }, .{ 4, 3 }, .{ 6, 2 } };
    const b2 = [_]Vec2{ .{ 1, 1 }, .{ 0, 1 }, .{ 4, 3 } };
    var other = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &b0, &b1, &b2 }, &diag);
    defer other.deinit();
    var joined = try boolean.boolean(testing.allocator, &.{ &grown, &other }, .@"union", .{}, &diag);
    defer joined.deinit();
    var common = try boolean.boolean(testing.allocator, &.{ &grown, &other }, .intersection, .{}, &diag);
    defer common.deinit();
    var rest = try boolean.boolean(testing.allocator, &.{ &grown, &other }, .difference, .{}, &diag);
    defer rest.deinit();
    const ag = try areaOf(&grown);
    const ao = try areaOf(&other);
    try testing.expectApproxEqAbs(ag + ao, (try areaOf(&joined)) + (try areaOf(&common)), 1e-9);
    try testing.expectApproxEqAbs(ag - (try areaOf(&common)), try areaOf(&rest), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.964), try areaOf(&common), 0.02);
}

test "even-odd fill: nested outlines, an island in a hole, a bow tie, and two letters" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const hole = [_]Vec2{ .{ 2, 2 }, .{ 8, 2 }, .{ 8, 8 }, .{ 2, 8 } };
    const island = [_]Vec2{ .{ 4, 4 }, .{ 6, 4 }, .{ 6, 6 }, .{ 4, 6 } };
    var nested = try boolean.evenOdd(testing.allocator, tol, &.{ &outer, &hole, &island }, &diag);
    defer nested.deinit();
    try expectCounts(&nested, 12, 12, 2, 3);
    try testing.expectApproxEqRel(@as(f64, 100 - 36 + 4), try areaOf(&nested), 1e-12);

    const bow = [_]Vec2{ .{ 0, 0 }, .{ 2, 2 }, .{ 2, 0 }, .{ 0, 2 } };
    var tie = try boolean.evenOdd(testing.allocator, tol, &.{&bow}, &diag);
    defer tie.deinit();
    try expectCounts(&tie, 5, 6, 2, 2);
    try testing.expectApproxEqRel(@as(f64, 2), try areaOf(&tie), 1e-12);

    // Two outlines side by side are two faces, whichever way each runs
    const left = [_]Vec2{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const right = [_]Vec2{ .{ 3, 0 }, .{ 3, 2 }, .{ 5, 2 }, .{ 5, 0 } };
    var word = try boolean.evenOdd(testing.allocator, tol, &.{ &left, &right }, &diag);
    defer word.deinit();
    try expectCounts(&word, 8, 8, 2, 2);
    try testing.expectApproxEqRel(@as(f64, 8), try areaOf(&word), 1e-12);
}

test "sketch booleans: three edges within a degree of each other at one vertex keep their order" {
    // Two slivers sharing an edge: at the origin, three half-edges leave within 0.6° of
    // one another. Ordered by curvature as near-tangent (both zero), the two lines were
    // neither less than the other, the sort put them anyhow, and the cycles came out
    // wrong; lines are ordered by the exact turn between their ends
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const lower = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 0.1 } };
    const upper = [_]Vec2{ .{ 0, 0 }, .{ 10, 0.1 }, .{ 10, 0.2 } };
    var a = try primitives.polygon(testing.allocator, tol, &lower, &diag);
    defer a.deinit();
    var b = try primitives.polygon(testing.allocator, tol, &upper, &diag);
    defer b.deinit();
    var u = try boolean.boolean(testing.allocator, &.{ &a, &b }, .@"union", .{}, &diag);
    defer u.deinit();
    try testing.expectApproxEqRel(@as(f64, 1), try areaOf(&u), 1e-12);
    try testing.expectEqual(@as(usize, 1), u.counts().faces);
    try testing.expectEqual(@as(usize, 3), u.counts().edges);
    var i = try boolean.boolean(testing.allocator, &.{ &a, &b }, .intersection, .{}, &diag);
    defer i.deinit();
    try testing.expect(i.isEmpty());
}

test "sketch booleans: a lens beside two arcs rising either way from one lowest point is a hole, and the areas add up" {
    // The fuzzer's find (2026-11-12): in the first sheet, the lens below the chord from
    // (5, 2) to (6, 2) lies inside the third ring's region, and the ray west from its
    // leftmost vertex first meets (4, 2), the lowest point of two arcs (about (4, 3) and
    // (4, 4)), one rising east and one west. Their directions there are level and opposite;
    // the tie rule took them for two tangent the same way and chose by bend, the west
    // one: the lens was nested in the plane, a face of its own over the big face (two
    // shells overlapping, which no checker rule sees), and every boolean with the second
    // sheet missed A(P) + A(Q) = A(P ∪ Q) + A(P ∩ Q) by the lens's area
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p = try test_bodies.ringSheet(testing.allocator, tol, &.{
        &.{ .{ .p = .{ 6, 2 } }, .{ .p = .{ 6, 2 }, .bulge = -1, .ccw = false }, .{ .p = .{ 5, 2 } } },
        &.{ .{ .p = .{ 2, 4 }, .bulge = 1, .ccw = false }, .{ .p = .{ 5, 3 }, .bulge = -1, .ccw = false }, .{ .p = .{ 4, 2 }, .bulge = -1, .ccw = false } },
        &.{ .{ .p = .{ 1, 2 }, .bulge = 1, .ccw = false }, .{ .p = .{ 0, 2 }, .bulge = -0.5, .ccw = false }, .{ .p = .{ 2, 0 } }, .{ .p = .{ 1, 1 } }, .{ .p = .{ 6, 6 }, .bulge = 1, .ccw = false }, .{ .p = .{ 1, 0 } }, .{ .p = .{ 0, 4 } }, .{ .p = .{ 1, 4 } } },
    }, &diag);
    defer p.deinit();
    // The lens is a hole: five faces, six loops
    try testing.expectEqual(@as(usize, 5), p.counts().faces);
    try testing.expectEqual(@as(usize, 6), p.counts().loops);
    var q = try test_bodies.ringSheet(testing.allocator, tol, &.{
        &.{ .{ .p = .{ 3, 6 }, .bulge = 1, .ccw = false }, .{ .p = .{ 3, 0 } }, .{ .p = .{ 3, 1 }, .bulge = -1 } },
        &.{ .{ .p = .{ 1, 2 }, .bulge = 0.5, .ccw = false }, .{ .p = .{ 6, 6 } }, .{ .p = .{ 6, 0 }, .bulge = -1 }, .{ .p = .{ 6, 2 }, .bulge = 1 }, .{ .p = .{ 2, 2 } }, .{ .p = .{ 0, 1 } }, .{ .p = .{ 5, 3 } }, .{ .p = .{ 3, 4 } } },
        &.{ .{ .p = .{ 3, 6 } }, .{ .p = .{ 0, 5 } }, .{ .p = .{ 3, 5 } }, .{ .p = .{ 0, 4 } }, .{ .p = .{ 6, 5 }, .bulge = -0.5, .ccw = false }, .{ .p = .{ 1, 4 }, .bulge = -1, .ccw = false }, .{ .p = .{ 6, 0 }, .bulge = 0.5, .ccw = false } },
    }, &diag);
    defer q.deinit();
    const ap = try areaOf(&p);
    const aq = try areaOf(&q);
    // P re-overlaid alone is itself
    var alone = try boolean.boolean(testing.allocator, &.{&p}, .@"union", .{}, &diag);
    defer alone.deinit();
    try testing.expectApproxEqAbs(ap, try areaOf(&alone), 1e-9);
    var areas: [3]f64 = undefined;
    for ([_]boolean.Op{ .@"union", .intersection, .difference }, &areas) |op, *area| {
        var r = try boolean.boolean(testing.allocator, &.{ &p, &q }, op, .{}, &diag);
        defer r.deinit();
        area.* = try areaOf(&r);
    }
    try testing.expectApproxEqAbs(ap + aq, areas[0] + areas[1], 1e-9);
    try testing.expectApproxEqAbs(ap - areas[1], areas[2], 1e-9);
}

test "even-odd fill: a sliver far from the origin is a face of its area, and the checker finds it wound as it is" {
    // Slivers 9e6 out, their areas about the world's origin summed from terms of 3e13.
    // The first's cycle summed to -0.002, not 0.0015, and was a hole of nothing; the
    // second's loop, sampled by the checker (its UV the world's, the plane's frame at the
    // origin), to -0.0117, not 0.0001, and was found wound backwards. Each summed about a
    // point of its own
    const slivers = [_]struct { at: Vec2, apex: Vec2, area: f64 }{
        .{ .at = .{ 9000001.35, 3000003.15 }, .apex = .{ 0.5, 0.153 }, .area = 0.0015 },
        .{ .at = .{ 9e6, 3e6 }, .apex = .{ 0.5, 0.1502 }, .area = 0.0001 },
    };
    for (slivers) |s| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        errdefer std.debug.print("sliver at ({d}, {d}): {f}\n", .{ s.at[0], s.at[1], &diag });
        const sliver = [_]Vec2{ s.at, vec.add2(s.at, .{ 1, 0.3 }), vec.add2(s.at, s.apex) };
        var sheet = try boolean.evenOdd(testing.allocator, tol, &.{&sliver}, &diag);
        defer sheet.deinit();
        try expectCounts(&sheet, 3, 3, 1, 1);
        // The apex where its coordinates round it, 9.3e-10 at most
        try testing.expectApproxEqAbs(s.area, try areaOf(&sheet), 1e-9);
        var report = try @import("../topology/check.zig").run(testing.allocator, &sheet, .global);
        defer report.deinit(testing.allocator);
        if (report.first()) |f| std.debug.print("checker: {f}\n", .{f});
        try testing.expect(report.ok());
    }
}
