//! Offsets against closed forms: a square grown with each join, shrunk, shrunk to nothing;
//! a circle; a plate with a hole, whose hole shrinks as the plate grows; a sliver shrunk
//! past its width; a U whose slot is narrower than the offset, shrunk with each join and
//! grown shut.

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
const offset = @import("offset.zig");

const tol = Tolerance.fromZone(1e-5);
const PI = std.math.pi;
const Vec2 = vec.Vec2;

fn areaOf(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).area;
}

fn grown(sheet: *const Body, delta: f64, join: offset.Join, diag: *Diagnostics) !Body {
    return offset.offset(testing.allocator, sheet, delta, join, 2, .{}, diag);
}

test "offset: a square by one, with each join; shrunk; shrunk to nothing" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 4, 4, false, &diag);
    defer sq.deinit();

    var round = try grown(&sq, 1, .round, &diag);
    defer round.deinit();
    try testing.expectApproxEqRel(16 + 16 + PI, try areaOf(&round), 1e-12);
    try testing.expectEqual(@as(usize, 8), round.counts().edges);

    var miter = try grown(&sq, 1, .miter, &diag);
    defer miter.deinit();
    try testing.expectApproxEqRel(@as(f64, 36), try areaOf(&miter), 1e-12);
    try testing.expectEqual(@as(usize, 4), miter.counts().edges);

    var bevel = try grown(&sq, 1, .bevel, &diag);
    defer bevel.deinit();
    try testing.expectApproxEqRel(@as(f64, 34), try areaOf(&bevel), 1e-12);

    // The cap is a chord at distance one from the corner: each corner loses (2 − √2)²/2
    var square = try grown(&sq, 1, .square, &diag);
    defer square.deinit();
    try testing.expectApproxEqRel(36 - 2 * (2 - @sqrt(2.0)) * (2 - @sqrt(2.0)), try areaOf(&square), 1e-12);

    var shrunk = try grown(&sq, -1, .round, &diag);
    defer shrunk.deinit();
    try testing.expectApproxEqRel(@as(f64, 4), try areaOf(&shrunk), 1e-12);
    try testing.expectEqual(@as(usize, 4), shrunk.counts().edges);

    var gone = try grown(&sq, -3, .round, &diag);
    defer gone.deinit();
    try testing.expect(gone.isEmpty());
}

test "offset: a round join at a vertex three faces share is one arc, not three on one circle" {
    // Three rings through (0, 3) (the fuzzer's): each face's round join about it is
    // computed by its own arithmetic, a bit apart; the overlay welds the centres, so
    // the joins' overlapping pieces are one edge each, and no two edges share their ends
    // and circle
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const a0 = [_]Vec2{ .{ 0, 3 }, .{ 1, 2 }, .{ 2, 3 } };
    const a1 = [_]Vec2{ .{ 0, 3 }, .{ 3, 6 }, .{ 0, 2 } };
    const a2 = [_]Vec2{ .{ 4, 4 }, .{ 0, 3 }, .{ 6, 2 }, .{ 3, 0 }, .{ 6, 1 } };
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &a0, &a1, &a2 }, &diag);
    defer sheet.deinit();
    var rounded = try offset.offset(testing.allocator, &sheet, 1.5, .round, 3, .{}, &diag);
    defer rounded.deinit();
    for (rounded.edges.items, 0..) |e, i| {
        if (e.flags.tombstone) continue;
        for (rounded.edges.items[0..i]) |other| {
            if (other.flags.tombstone) continue;
            const same_ends = (other.start == e.start and other.end == e.end) or (other.start == e.end and other.end == e.start);
            try testing.expect(!(same_ends and other.curve.kind == e.curve.kind and e.curve.kind == .circle));
        }
    }
    try testing.expectEqual(@as(usize, 1), rounded.counts().faces);
}

test "offset: a circle keeps its centre; a plate with a round hole grows as its hole shrinks; a miter past its limit is squared" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    var bigger = try grown(&disc, 1, .miter, &diag);
    defer bigger.deinit();
    try testing.expectApproxEqRel(PI * 9, try areaOf(&bigger), 1e-12);
    try testing.expectEqual(@as(usize, 2), bigger.counts().edges);
    var smaller = try grown(&disc, -1, .round, &diag);
    defer smaller.deinit();
    try testing.expectApproxEqRel(PI, try areaOf(&smaller), 1e-12);

    var plate = try primitives.square(testing.allocator, tol, 10, 10, false, &diag);
    defer plate.deinit();
    var hole = try transform.transform(testing.allocator, &disc, &mat.Affine.translate(.{ 5, 5, 0 }), .{}, &diag);
    defer hole.deinit();
    var pierced = try boolean.boolean(testing.allocator, &.{ &plate, &hole }, .difference, .{}, &diag);
    defer pierced.deinit();
    var thicker = try grown(&pierced, 1, .round, &diag);
    defer thicker.deinit();
    try testing.expectApproxEqRel(100 + 40 + PI - PI, try areaOf(&thicker), 1e-12);
    try testing.expectEqual(@as(usize, 2), thicker.counts().loops);
    // Shrunk by two, the hole is gone and the plate is 6 by 6, the hole having grown to
    // radius 4: a 6 × 6 square less what a circle of radius 4 about its centre takes
    var thinner = try grown(&pierced, -2, .round, &diag);
    defer thinner.deinit();
    try testing.expect(try areaOf(&thinner) < 36);
    try testing.expect(try areaOf(&thinner) > 0);

    // A sharp corner: the miter of a thin triangle's point reaches past the limit and is
    // squared off, so the grown triangle has less area than a miter of twice the limit
    // would give it
    const spike = [_]vec.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 1 } };
    var tri = try primitives.polygon(testing.allocator, tol, &spike, &diag);
    defer tri.deinit();
    var capped = try grown(&tri, 1, .miter, &diag);
    defer capped.deinit();
    var reaching = try offset.offset(testing.allocator, &tri, 1, .miter, 30, .{}, &diag);
    defer reaching.deinit();
    try testing.expect(try areaOf(&capped) < try areaOf(&reaching));
    try testing.expectEqual(@as(usize, 3), reaching.counts().edges);
}

test "offset: a sliver shrunk past its width is gone; grown, it is the sliver, its perimeter's band and a disc" {
    // The fuzzer's find (2026-11-08): the raw outline of a sliver shrunk past its width
    // turns inside out with positive winding, which the classic recipe kept as a region
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const sliver = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 0.1 } };
    var tri = try primitives.polygon(testing.allocator, tol, &sliver, &diag);
    defer tri.deinit();
    var gone = try grown(&tri, -1, .round, &diag);
    defer gone.deinit();
    try testing.expect(gone.isEmpty());
    // A convex region grown by d (round): its area, its perimeter times d, and πd²
    var fat = try grown(&tri, 1, .round, &diag);
    defer fat.deinit();
    const perimeter = 10 + 2 * @sqrt(25.0 + 0.01);
    try testing.expectApproxEqRel(0.5 + perimeter + PI, try areaOf(&fat), 1e-12);
    // The fuzzer's own sliver, of area 0.0019, and the whole of its chain's first offset
    const tiny = [_]Vec2{ .{ 2.5, 2 }, .{ 2.6, 2 }, .{ 2.5926, 2.037 } };
    var small = try primitives.polygon(testing.allocator, tol, &tiny, &diag);
    defer small.deinit();
    var nothing = try grown(&small, -1, .round, &diag);
    defer nothing.deinit();
    try testing.expect(nothing.isEmpty());
    // A disc shrunk past its radius: the arcs' sweeps pass the centre
    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    var no_disc = try grown(&disc, -3, .round, &diag);
    defer no_disc.deinit();
    try testing.expect(no_disc.isEmpty());
    // A plate's hole narrower than the growth fills: the hole's arcs swept past their centre
    var plate = try primitives.square(testing.allocator, tol, 10, 10, false, &diag);
    defer plate.deinit();
    var hole = try transform.transform(testing.allocator, &disc, &mat.Affine.translate(.{ 5, 5, 0 }), .{}, &diag);
    defer hole.deinit();
    var pierced = try boolean.boolean(testing.allocator, &.{ &plate, &hole }, .difference, .{}, &diag);
    defer pierced.deinit();
    var filled = try grown(&pierced, 3, .round, &diag);
    defer filled.deinit();
    try testing.expectApproxEqRel(100 + 120 + 9 * PI, try areaOf(&filled), 1e-12);
    try testing.expectEqual(@as(usize, 1), filled.counts().loops);
}

test "offset: a U with a slot narrower than the offset, shrunk with each join and grown shut" {
    // A 6 by 7 plate with a slot one wide and four deep from its top: shrunk by one, a U
    // again (legs half wide, base one high, area 8) whose inner corners the join shapes:
    // round leaves the square between the sweeps less a quarter disc at each, bevel half
    // of it, miter nothing
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outline = [_]Vec2{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 7 }, .{ 3.5, 7 }, .{ 3.5, 3 }, .{ 2.5, 3 }, .{ 2.5, 7 }, .{ 0, 7 } };
    var u = try primitives.polygon(testing.allocator, tol, &outline, &diag);
    defer u.deinit();
    var round = try grown(&u, -1, .round, &diag);
    defer round.deinit();
    try testing.expectApproxEqRel(8 + 2 * (1 - PI / 4.0), try areaOf(&round), 1e-12);
    try testing.expectEqual(@as(usize, 1), round.counts().faces);
    var bevel = try grown(&u, -1, .bevel, &diag);
    defer bevel.deinit();
    try testing.expectApproxEqRel(@as(f64, 9), try areaOf(&bevel), 1e-12);
    var miter = try grown(&u, -1, .miter, &diag);
    defer miter.deinit();
    try testing.expectApproxEqRel(@as(f64, 8), try areaOf(&miter), 1e-12);
    try testing.expectEqual(@as(usize, 8), miter.counts().edges);
    // Grown by one, the slot closes (every point of it is within half of a wall) but
    // for the notch at its mouth beyond the reach of the two corners' discs: the grown
    // plate, 68 + π, less 2∫₀^½ (1 − √(1 − u²)) du = 1 − √3/4 − π/6
    var shut = try grown(&u, 1, .round, &diag);
    defer shut.deinit();
    const notch = 1 - @sqrt(3.0) / 4.0 - PI / 6.0;
    try testing.expectApproxEqRel(68 + PI - notch, try areaOf(&shut), 1e-12);
    try testing.expectEqual(@as(usize, 1), shut.counts().loops);
}

test "offset: a grown sheet holds its sheet (the fuzzer's chain whose grown sheet was nothing)" {
    // A union of two three-ring sheets grown by one: 1,063 input edges, 3,929 faces of
    // the overlay. A ray-crossing rule that counted a vertex differently on its line and
    // its arc nested the outer boundary in a face of no area and labelled nothing
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const a1 = [_]Vec2{ .{ 1, 3 }, .{ 3, 5 }, .{ 0, 2 }, .{ 6, 2 }, .{ 4, 0 }, .{ 1, 0 }, .{ 2, 1 }, .{ 6, 5 } };
    const a2 = [_]Vec2{ .{ 3, 1 }, .{ 1, 4 }, .{ 2, 2 }, .{ 0, 1 }, .{ 6, 1 }, .{ 2, 5 }, .{ 3, 0 } };
    const a3 = [_]Vec2{ .{ 4, 4 }, .{ 4, 6 }, .{ 4, 1 }, .{ 5, 1 }, .{ 1, 3 }, .{ 6, 5 }, .{ 2, 0 }, .{ 1, 6 } };
    var a = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &a1, &a2, &a3 }, &diag);
    defer a.deinit();
    const b1 = [_]Vec2{ .{ 3, 2 }, .{ 2, 1 }, .{ 0, 3 }, .{ 3, 6 }, .{ 2, 0 }, .{ 4, 2 }, .{ 0, 1 }, .{ 6, 4 } };
    const b2 = [_]Vec2{ .{ 6, 4 }, .{ 2, 3 }, .{ 3, 6 }, .{ 2, 5 }, .{ 3, 4 }, .{ 0, 3 }, .{ 0, 3 } };
    const b3 = [_]Vec2{ .{ 6, 4 }, .{ 4, 4 }, .{ 6, 6 }, .{ 6, 1 }, .{ 1, 5 }, .{ 2, 5 }, .{ 0, 2 }, .{ 1, 1 } };
    var b = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &b1, &b2, &b3 }, &diag);
    defer b.deinit();
    var u = try boolean.boolean(testing.allocator, &.{ &a, &b }, .@"union", .{}, &diag);
    defer u.deinit();
    var g = try offset.offset(testing.allocator, &u, 1, .round, 3, .{}, &diag);
    defer g.deinit();
    var both = try boolean.boolean(testing.allocator, &.{ &u, &g }, .intersection, .{}, &diag);
    defer both.deinit();
    try testing.expectApproxEqRel(try areaOf(&u), try areaOf(&both), 1e-9);
    try testing.expect(try areaOf(&g) > try areaOf(&u) + 20);
}
