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
const check = @import("../topology/check.zig");
const tessellate = @import("../mesh/tessellate.zig");
const Vec2 = vec.Vec2;

const tol = Tolerance.fromZone(1e-5);
const PI = std.math.pi;
/// The last of the points along the curved side of the shallow-curve test.
const LAST_ALONG: usize = 40;
/// Discs whose arcs a narrow strip cuts in pieces of a sweep below any angular slack: the
/// radius and the strip's width, the piece's sweep their quotient (5e-10, 5e-11, 5e-10 rad).
const WIDE_DISCS = [_][2]f64{ .{ 1e5, 5e-5 }, .{ 1e6, 5e-5 }, .{ 1e6, 5e-4 } };
/// How far the disc and the strip are moved along x together.
const WIDE_SHIFTS = [_]f64{ 0, 3e5 };
/// How close the moved faces' areas come to the closed form, by the measure's own rounding.
const WIDE_MOVED_CLOSE: f64 = 1e-3;
/// How far the strip reaches either side of the disc's top.
const STRIP_REACH: f64 = 1;
/// The most rings and points `drawnSheet` takes.
const MOST_RINGS: usize = 4;
const MOST_DRAWN: usize = 32;

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

test "even-odd fill: a side of points along a shallow curve keeps every point within the zone of the sheet's edges" {
    // A side drawn as 40 points 0.01 apart along y = -x²/230, each 4.3e-7 off the line
    // through its neighbours: each within the zone of the line from the side's start to
    // the next point for the first 23, so the pieces merged, a point at a time, into one
    // edge the twelfth point was 6.3 zones off. Merged while every point passed stays
    // within the zone, an edge spans nine pieces (its middle points 0.87 zones off; a
    // tenth would leave them 1.09 off): five edges along the side
    var outline: [LAST_ALONG + 3]Vec2 = undefined;
    for (0..LAST_ALONG + 1) |k| {
        const x = @as(f64, @floatFromInt(k)) * 0.01;
        outline[k] = .{ x, -x * x / 230 };
    }
    outline[LAST_ALONG + 1] = .{ 0.4, 1 };
    outline[LAST_ALONG + 2] = .{ 0, 1 };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try boolean.evenOdd(testing.allocator, tol, &.{&outline}, &diag);
    defer sheet.deinit();
    for (outline) |p| {
        var nearest = std.math.inf(f64);
        for (sheet.edges.items) |e| {
            const a = sheet.point(e.start);
            const b = sheet.point(e.end);
            const d: Vec2 = .{ b[0] - a[0], b[1] - a[1] };
            const s = std.math.clamp(vec.dot2(vec.sub2(p, .{ a[0], a[1] }), d) / vec.dot2(d, d), 0, 1);
            nearest = @min(nearest, vec.distance2(p, vec.addScaled2(.{ a[0], a[1] }, d, s)));
        }
        try testing.expect(nearest <= tol.zone);
    }
    try expectCounts(&sheet, 8, 8, 1, 1);
}

test "sketch booleans: an offset's bevel 2e-5 across cut by a line through the corner it bevelled, the pieces do not merge into a line through another vertex" {
    // The locus fuzzer's find (the nightly of 2026-11-19, run 44568960243, bi), as it drew
    // it: a triangle grown by 2e-5 with bevel joins, united with a sheet, then met with a
    // sheet whose line from (0, 6) to (3, 3) passes through the triangle's corner (1, 5),
    // itself a vertex of that sheet. About the corner the intersection's boundary runs
    // along the grown side, the bevel and that line, by pieces 2e-5, 1.8e-5 and 1.6e-5
    // long: each vertex between them within the zone of the line from the run's start to
    // the next, so they merged into one edge along the line through the corner, a vertex
    // the boundary passes twice, the bevel's own corner 1.4 zones off it; the face's
    // polygon was not simple and did not tessellate. Each vertex passed held within the
    // zone, the edge stops at the bevel
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    errdefer std.debug.print("{f}\n", .{&diag});
    var triangle = try drawnSheet(&.{&.{ .{ .p = .{ 3, 6 } }, .{ .p = .{ 1, 6 } }, .{ .p = .{ 1, 5 } } }}, &diag);
    defer triangle.deinit();
    var grown = try offset_mod.offset(testing.allocator, &triangle, 2e-5, .bevel, std.math.floatMax(f64), .{}, &diag);
    defer grown.deinit();
    var second = try drawnSheet(&.{
        &.{ .{ .p = .{ 5, 3 }, .bulge = 1, .ccw = false }, .{ .p = .{ 5, 1 }, .bulge = -1 }, .{ .p = .{ 3, 0 } }, .{ .p = .{ 3, 1 } } },
        &.{ .{ .p = .{ 3, 2 } }, .{ .p = .{ 2, 6 } }, .{ .p = .{ 6, 1 }, .bulge = -1, .ccw = false }, .{ .p = .{ 1, 6 } }, .{ .p = .{ 1, 3 } }, .{ .p = .{ 5, 0 }, .bulge = 0.5 } },
        &.{ .{ .p = .{ 6, 2 }, .bulge = 0.5 }, .{ .p = .{ 4, 0 } }, .{ .p = .{ 1, 6 } } },
    }, &diag);
    defer second.deinit();
    var joined = try boolean.boolean(testing.allocator, &.{ &grown, &second }, .@"union", .{}, &diag);
    defer joined.deinit();
    var third = try drawnSheet(&.{
        &.{ .{ .p = .{ 1, 5 }, .bulge = 0.5, .ccw = false }, .{ .p = .{ 1, 2 } }, .{ .p = .{ 4, 3 } }, .{ .p = .{ 0, 3 } }, .{ .p = .{ 1, 6 } }, .{ .p = .{ 4, 3 }, .bulge = 0.5 }, .{ .p = .{ 5, 2 } }, .{ .p = .{ 6, 4 } } },
        &.{ .{ .p = .{ 0, 6 } }, .{ .p = .{ 3, 3 } }, .{ .p = .{ 5, 3 }, .bulge = -1 }, .{ .p = .{ 2, 2 }, .bulge = -0.5 }, .{ .p = .{ 1, 4 } }, .{ .p = .{ 1, 0 } }, .{ .p = .{ 2, 1 } }, .{ .p = .{ 6, 4 }, .bulge = -1 } },
    }, &diag);
    defer third.deinit();
    var met = try boolean.boolean(testing.allocator, &.{ &joined, &third }, .intersection, .{}, &diag);
    defer met.deinit();
    var report = try check.run(testing.allocator, &met, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    var mesh = try tessellate.tessellate(testing.allocator, &met, .{}, .{}, &diag);
    defer mesh.deinit(testing.allocator);
    for (mesh.faces) |range| try testing.expectEqual(tessellate.Status.ok, range.status);
    // The corner, and the bevel's cut 1.06e-5 from it, where the edge along the line ends
    var corner = false;
    var cut = false;
    for (met.vertices.items) |v| {
        const p = met.geometry.point(v.point);
        corner = corner or (p[0] == 1 and p[1] == 5);
        cut = cut or (vec.distance2(.{ p[0], p[1] }, .{ 1, 5 }) > 1e-5 and vec.distance2(.{ p[0], p[1] }, .{ 1, 5 }) < 1.1e-5);
    }
    try testing.expect(corner and cut);
}

/// A point of a ring as the fuzzer draws it (fuzz_test.zig's `sheet`): the edge leaving
/// it straight, or with a `bulge` an arc about the point that share of the half-chord off
/// the chord's middle, to its left when positive, run counter-clockwise or not.
const Drawn = struct { p: Vec2, bulge: ?f64 = null, ccw: bool = true };

/// The sheet the rings fill by the even-odd rule, each ring's last point joined to its
/// first.
fn drawnSheet(rings: []const []const Drawn, diag: *Diagnostics) !Body {
    var edges: [MOST_DRAWN]primitives.OutlineEdge = undefined;
    var outlines: [MOST_RINGS][]const primitives.OutlineEdge = undefined;
    var used: usize = 0;
    for (rings, 0..) |ring, r| {
        for (ring, 0..) |from, k| {
            const b = ring[(k + 1) % ring.len].p;
            edges[used + k] = .{ .a = from.p, .b = b };
            if (from.bulge) |bulge| {
                const half = vec.scale2(vec.sub2(b, from.p), 0.5);
                const c = vec.add2(vec.add2(from.p, half), vec.scale2(vec.perp2(half), bulge));
                edges[used + k].arc = .{ .c = c, .r = vec.distance2(from.p, c), .ccw = from.ccw };
            }
        }
        outlines[r] = edges[used .. used + ring.len];
        used += ring.len;
    }
    return primitives.outlines(testing.allocator, tol, outlines[0..rings.len], diag);
}

test "sketch booleans: a narrow strip across the top of a wide disc keeps a short piece of its arc, not a whole turn" {
    // The audit of 2026-11-22 (kinds 6 to 8): an arc piece's sweep under 1e-9 rad was
    // read as a whole turn (the slack that tells a closed circle's ends apart), so a piece
    // 5e-5 long of a circle of radius 1e5 added the whole disc, 3e10, to its face's area.
    // A whole turn is two ends that are one vertex; two vertices are a piece however short
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (WIDE_DISCS) |sizes| for ([_]bool{ false, true }) |down| for ([_]bool{ false, true }) |strip_first| for (WIDE_SHIFTS) |shift| {
        const r = sizes[0];
        const w = sizes[1];
        errdefer std.debug.print("radius {e}, width {e}, down {}, the strip first {}, moved {e}\n", .{ r, w, down, strip_first, shift });
        var disc_drawn = try primitives.circle(testing.allocator, tol, r, &diag);
        defer disc_drawn.deinit();
        var disc = try moved(&disc_drawn, shift, 0, &diag);
        defer disc.deinit();
        const top: f64 = if (down) -r else r;
        // Moved, the measure sums terms of the shift times the radius, 3e10 to 3e11, to an
        // area of 5e-5: its rounding is as large as the area, and far from the disc's 3e10
        const close: f64 = w * STRIP_REACH * 1e-6 + (if (shift == 0) 0 else WIDE_MOVED_CLOSE);
        var strip = try primitives.polygon(testing.allocator, tol, &.{ .{ shift - w / 2, top - STRIP_REACH }, .{ shift + w / 2, top - STRIP_REACH }, .{ shift + w / 2, top + STRIP_REACH }, .{ shift - w / 2, top + STRIP_REACH } }, &diag);
        defer strip.deinit();
        const operands: [2]*const Body = if (strip_first) .{ &strip, &disc } else .{ &disc, &strip };
        var both = try boolean.boolean(testing.allocator, &operands, .intersection, .{}, &diag);
        defer both.deinit();
        {
            var report = try check.run(testing.allocator, &both, .global);
            defer report.deinit(testing.allocator);
            try testing.expect(report.ok());
        }
        // The strip up to the arc: its width times the reach, less the arc's sag (w²/8r each
        // end of nothing here)
        try testing.expectApproxEqAbs(w * STRIP_REACH, try areaOf(&both), close);
        try expectCounts(&both, 4, 4, 1, 1);
        var rest = try boolean.boolean(testing.allocator, &.{ &strip, &disc }, .difference, .{}, &diag);
        defer rest.deinit();
        {
            var report = try check.run(testing.allocator, &rest, .global);
            defer report.deinit(testing.allocator);
            try testing.expect(report.ok());
        }
        try testing.expectApproxEqAbs(w * STRIP_REACH, try areaOf(&rest), close);
    };
}

/// What a sketch boolean made: its counts and area, or that it was refused.
const SheetOutcome = struct { made: bool, faces: usize = 0, loops: usize = 0, edges: usize = 0, area: f64 = 0 };

fn sheetOutcome(sheets: []const *const Body, op: boolean.Op, diag: *Diagnostics) !SheetOutcome {
    var made = boolean.boolean(testing.allocator, sheets, op, .{}, diag) catch |e| {
        if (e == error.OutOfMemory) return e;
        return .{ .made = false };
    };
    defer made.deinit();
    var report = try check.run(testing.allocator, &made, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    const c = made.counts();
    return .{ .made = true, .faces = c.faces, .loops = c.loops, .edges = c.edges, .area = try areaOf(&made) };
}

test "sketch booleans: a disc tangent to a rectangle's side from within, every radius, in place, turned and moved whole" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for ([_]f64{ 10, 1e3, 1e4, 1e5 }) |r| for ([_]boolean.Op{ .@"union", .difference, .intersection }) |op| {
        // The disc's two vertices are at its east and west points wherever the rest is
        // turned, at the tangent point in odd quarter turns, and which arcs simplify joins
        // goes by them: the faces, loops and area are compared
        var base: [2]?SheetOutcome = .{ null, null };
        for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| for ([_]Vec2{ .{ 0, 0 }, .{ 3e5, 0 }, .{ 0, 3e5 }, .{ 3e5, 3e5 } }) |shift| {
            const place = struct {
                fn at(p: Vec2, quarters: usize, mirror: bool, by: Vec2) Vec2 {
                    var q: Vec2 = if (mirror) .{ -p[0], p[1] } else p;
                    for (0..quarters) |_| {
                        const turned: Vec2 = .{ -q[1], q[0] };
                        q = turned;
                    }
                    return vec.add2(q, by);
                }
            };
            var corners: [4]Vec2 = .{ .{ -2 * r, -3 * r }, .{ 2 * r, -3 * r }, .{ 2 * r, 0 }, .{ -2 * r, 0 } };
            for (&corners) |*p| p.* = place.at(p.*, quarter, mirrored, shift);
            if (mirrored) std.mem.reverse(Vec2, &corners);
            errdefer std.debug.print("radius {e}, {s}, quarter turns {d}, mirrored {}, moved {any}: {f}\n", .{ r, @tagName(op), quarter, mirrored, shift, &diag });
            var rect = try primitives.polygon(testing.allocator, tol, &corners, &diag);
            defer rect.deinit();
            const centre = place.at(.{ 0, -r }, quarter, mirrored, shift);
            var drawn = try primitives.circle(testing.allocator, tol, r, &diag);
            defer drawn.deinit();
            var disc = try moved(&drawn, centre[0], centre[1], &diag);
            defer disc.deinit();
            const got = try sheetOutcome(&.{ &rect, &disc }, op, &diag);
            errdefer std.debug.print("radius {e}, {s}, quarter turns {d}, mirrored {}, moved {any}: {any} against {any}\n", .{ r, @tagName(op), quarter, mirrored, shift, got, base[quarter % 2] });
            const want: f64 = switch (op) {
                .@"union" => 12 * r * r,
                .difference => (12 - PI) * r * r,
                .intersection => PI * r * r,
            };
            try testing.expect(got.made);
            try testing.expectApproxEqRel(want, got.area, 1e-6);
            if (base[quarter % 2]) |b| {
                try testing.expectEqual(b.faces, got.faces);
                try testing.expectEqual(b.loops, got.loops);
            } else base[quarter % 2] = got;
        };
    };
}

test "sketch booleans: a triangle's tip the zone past a square's side, to rounding, is cut there or refused, in place, turned and moved whole" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const square = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var k: i32 = -40;
    while (k <= 40) : (k += 1) {
        const past = tol.zone + @as(f64, @floatFromInt(k)) * 2e-12;
        for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| for ([_]Vec2{ .{ 0, 0 }, .{ 3e5, 0 }, .{ 0, 3e5 }, .{ 3e5, 3e5 } }) |shift| {
            const place = struct {
                fn at(p: Vec2, quarters: usize, mirror: bool, by: Vec2) Vec2 {
                    var q: Vec2 = if (mirror) .{ -p[0], p[1] } else p;
                    for (0..quarters) |_| {
                        const turned: Vec2 = .{ -q[1], q[0] };
                        q = turned;
                    }
                    return vec.add2(q, by);
                }
            };
            var a_pts = square;
            for (&a_pts) |*p| p.* = place.at(p.*, quarter, mirrored, shift);
            if (mirrored) std.mem.reverse(Vec2, &a_pts);
            var b_pts = [_]Vec2{ .{ 5, -past }, .{ 6, 5 }, .{ 4, 5 } };
            for (&b_pts) |*p| p.* = place.at(p.*, quarter, mirrored, shift);
            if (mirrored) std.mem.reverse(Vec2, &b_pts);
            var a = try primitives.polygon(testing.allocator, tol, &a_pts, &diag);
            defer a.deinit();
            var b = try primitives.polygon(testing.allocator, tol, &b_pts, &diag);
            defer b.deinit();
            for ([_]boolean.Op{ .@"union", .difference, .intersection }) |op| {
                errdefer std.debug.print("past {e}, {s}, quarter turns {d}, mirrored {}, moved {any}: {any}\n", .{ past, @tagName(op), quarter, mirrored, shift, diag.first() });
                var made = boolean.boolean(testing.allocator, &.{ &a, &b }, op, .{}, &diag) catch |e| {
                    try testing.expectEqual(error.Degenerate, e);
                    try testing.expectEqual(.at_tolerance, diag.first().?.code);
                    diag.deinit();
                    diag = Diagnostics.init(testing.allocator);
                    continue;
                };
                defer made.deinit();
                var report = try check.run(testing.allocator, &made, .global);
                defer report.deinit(testing.allocator);
                try testing.expect(report.ok());
                // The triangle's area in the square (all of it but its tip below the side)
                // The triangle's area in the square: all of it but its tip below the side,
                // to the zone's moves of its corners
                const inside = 5 + past - past * past / 5;
                const want: f64 = switch (op) {
                    .@"union" => 100 + past * past / 5,
                    .difference => 100 - inside,
                    .intersection => inside,
                };
                try testing.expectApproxEqAbs(want, try areaOf(&made), 1e-4);
            }
        };
    }
}

test "sketch booleans: two discs tangent inside, nearly one radius, in place, turned and moved whole, at two zones" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for ([_]f64{ 1e-5, 1e-6 }) |zone| for ([_][2]f64{ .{ 10, 10.001 }, .{ 1e3, 1e3 + 0.01 }, .{ 1e4, 1e4 + 0.1 } }) |radii| for ([_]boolean.Op{ .@"union", .difference, .intersection }) |op| {
        const t = Tolerance.fromZone(zone);
        var base: ?SheetOutcome = null;
        for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| for ([_]Vec2{ .{ 0, 0 }, .{ 3e5, 0 }, .{ 0, 3e5 }, .{ 3e5, 3e5 }, .{ 1e6, -1e6 } }) |shift| {
            // Within the scale guard: the zone at least the extent times 1e-12
            if (@max(@abs(shift[0]), @abs(shift[1])) + 2 * radii[1] > zone * 1e12) continue;
            var turned: Vec2 = .{ 0, -1 };
            if (mirrored) turned[0] = -turned[0];
            for (0..quarter) |_| {
                const q: Vec2 = .{ -turned[1], turned[0] };
                turned = q;
            }
            errdefer std.debug.print("radii {any}, zone {e}, {s}, quarter turns {d}, mirrored {}, moved {any}: {f}\n", .{ radii, zone, @tagName(op), quarter, mirrored, shift, &diag });
            var discs: [2]Body = undefined;
            for (radii, &discs, 0..) |r, *disc, i| {
                var drawn = try primitives.circle(testing.allocator, t, r, &diag);
                defer drawn.deinit();
                const centre = vec.addScaled2(shift, turned, r);
                disc.* = try moved(&drawn, centre[0], centre[1], &diag);
                errdefer if (i == 1) discs[0].deinit();
            }
            defer for (&discs) |*d| d.deinit();
            const got = try sheetOutcome(&.{ &discs[1], &discs[0] }, op, &diag);
            errdefer std.debug.print("{any} against {any}\n", .{ got, base });
            const small = PI * radii[0] * radii[0];
            const large = PI * radii[1] * radii[1];
            const want: f64 = switch (op) {
                .@"union" => large,
                .difference => large - small,
                .intersection => small,
            };
            try testing.expect(got.made);
            try testing.expectApproxEqAbs(want, got.area, 1e-9 * large);
            if (base) |b| {
                try testing.expectEqual(b.faces, got.faces);
                try testing.expectEqual(b.loops, got.loops);
            } else base = got;
        };
    };
}
