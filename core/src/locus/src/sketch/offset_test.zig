//! Offsets against closed forms: a square grown with each join, shrunk, shrunk to nothing;
//! a circle; a plate with a hole, whose hole shrinks as the plate grows; a sliver shrunk
//! past its width; a U whose slot is narrower than the offset, shrunk with each join and
//! grown shut; a square less a quarter disc, whose two cusps get each join, grown and as
//! a hole shrunk.

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
const query = @import("query.zig");
const boolean = @import("boolean.zig");
const offset = @import("offset.zig");
const hull = @import("hull.zig");
const test_bodies = @import("../construct/test_bodies.zig");

const tol = Tolerance.fromZone(1e-5);
const PI = std.math.pi;
const Vec2 = vec.Vec2;

/// The seam family (the test of a segment of a disc grown twice): the disc's radius about
/// the origin and the angle its arc runs through; how far short of its circle's seam (the
/// point to +x of the centre, where an arc across it is two edges, D7) the arc starts, or
/// past it ends, each but the last (a control) leaving a piece of the grown arc within the
/// zone of its chord (`√(8·zone/r)`, 4e-3 at the grown radius, is the most), the second
/// the find's (the nightly of 2026-11-20, bm); the two offsets; and the side of the square
/// plate the segment is a hole of.
const SEGMENT_RADIUS: f64 = 4;
const SEGMENT_ANGLE: f64 = 2;
const SEAM_GAPS = [_]f64{ 3e-4, 1.2e-3, 3e-3, 0.3 };
const SEAM_OFFSETS = [2]f64{ 1, 1.5 };
const SEAM_PLATE: f64 = 40;
/// How near a twice-offset sheet's area is to its closed form, and to the control's.
const SEAM_AREA_CLOSE: f64 = 1e-9;
/// The cusp family (the spandrel's cusps grown with miters, turned and moved out): the
/// offsets (the find's 2e-5 leaves the spandrel's bands under the sheet's size rules and is
/// refused; the miter's reach, δ over the tangents' cross, goes by the cross at any δ);
/// the miter limits, the least and past any cusp's reach (the 2D chain fuzzer's
/// find dh drew `floatMax`); the moves, as the chain fuzzer moves a sheet whole (a turn
/// about z, then a shift), the find's first; and how near each area is to the closed form.
const CUSP_OFFSETS = [_]f64{ 1e-3, 0.5 };
const CUSP_LIMITS = [_]f64{ 2, 1e3, std.math.floatMax(f64) };
const CUSP_MOVES = [_]struct { angle: f64, shift: Vec2 }{
    .{ .angle = 0.014142253477512098, .shift = .{ 1e5, -2e5 } },
    .{ .angle = 0, .shift = .{ 0, 0 } },
    .{ .angle = 0, .shift = .{ 1e5, -2e5 } },
    .{ .angle = 0.3, .shift = .{ 0, 0 } },
    .{ .angle = 0.3, .shift = .{ 1e5, -2e5 } },
};
const CUSP_AREA_CLOSE: f64 = 1e-9;
/// The radius of the rounded corner of the square whose arc's end is given off its
/// circle, and how far inside the circle the end is given, in zones (the overlay welds an
/// end within the zone; an outline is taken with one).
const OFF_CIRCLE_RADIUS: f64 = 5e-5;
const OFF_CIRCLE_INSIDE = [_]f64{ 0, 0.5, 0.9, -0.9 };
/// How far that square is grown, and how close its grown area comes to the closed form of
/// the square's (the corner's rounding and the end's shift are within the zone times the
/// perimeter).
const OFF_CIRCLE_GROWTHS = [_]f64{ 1, 5 };
const OFF_CIRCLE_CLOSE: f64 = 1e-3;

fn areaOf(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).area;
}

fn grown(sheet: *const Body, delta: f64, join: offset.Join, diag: *Diagnostics) !Body {
    return offset.offset(testing.allocator, sheet, delta, join, 2, .{}, diag);
}

const RingPoint = test_bodies.RingPoint;

fn bulged(rings: []const []const RingPoint, diag: *Diagnostics) !Body {
    return test_bodies.ringSheet(testing.allocator, tol, rings, diag);
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

test "offset: a shrunk sheet lies within its sheet (the fuzzer's chain of 12,899 overlay edges)" {
    // Three edges within a degree of one another at one vertex had no order in the
    // overlay's angular sort, and two lines through one vertex a fraction of a degree
    // apart were interned as one: the shrunk sheet came out as 43 slivers outside the
    // sheet
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const a1 = [_]Vec2{ .{ 1, 3 }, .{ 3, 5 }, .{ 0, 1 }, .{ 6, 5 }, .{ 4, 0 }, .{ 1, 4 }, .{ 2, 6 }, .{ 6, 1 } };
    const a2 = [_]Vec2{ .{ 3, 1 }, .{ 1, 3 }, .{ 2, 5 }, .{ 0, 0 }, .{ 6, 6 }, .{ 2, 2 }, .{ 3, 1 } };
    const a3 = [_]Vec2{ .{ 4, 3 }, .{ 4, 6 }, .{ 4, 0 }, .{ 5, 2 }, .{ 1, 1 }, .{ 6, 4 }, .{ 2, 5 }, .{ 1, 3 } };
    var a = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &a1, &a2, &a3 }, &diag);
    defer a.deinit();
    const b1 = [_]Vec2{ .{ 3, 6 }, .{ 4, 2 }, .{ 0, 4 }, .{ 3, 3 }, .{ 2, 3 }, .{ 4, 4 }, .{ 0, 4 }, .{ 4, 6 } };
    const b2 = [_]Vec2{ .{ 3, 1 }, .{ 0, 5 }, .{ 2, 5 }, .{ 1, 6 }, .{ 4, 1 }, .{ 2, 1 }, .{ 1, 5 } };
    const b3 = [_]Vec2{ .{ 5, 6 }, .{ 3, 3 }, .{ 6, 6 }, .{ 1, 5 }, .{ 2, 6 }, .{ 2, 1 }, .{ 2, 6 }, .{ 2, 2 } };
    var b = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &b1, &b2, &b3 }, &diag);
    defer b.deinit();
    var u = try boolean.boolean(testing.allocator, &.{ &a, &b }, .@"union", .{}, &diag);
    defer u.deinit();
    var s = try offset.offset(testing.allocator, &u, -1, .round, 3, .{}, &diag);
    defer s.deinit();
    var both = try boolean.boolean(testing.allocator, &.{ &u, &s }, .intersection, .{}, &diag);
    defer both.deinit();
    try testing.expectApproxEqRel(try areaOf(&s), try areaOf(&both), 1e-9);
    try testing.expect(try areaOf(&s) < try areaOf(&u));
}

test "offset: a grown sheet holds its sheet where a join arc is tangent to a neighbour's edge" {
    // The fuzzer's find (2026-11-09): a triangle's join arc about (2.5, 3.5) of radius
    // one half touches the other triangle's edge along y = 3 at (2.5, 3). The sheet's
    // edge and the band's coincident copy of it, measured from either end, put the
    // tangency's discriminant a rounding either side of zero: one was cut there and the
    // other not, and the map was not planar. Every vertex within the zone of an edge is
    // now a cut on it, whichever pair made the vertex
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const lower = [_]Vec2{ .{ 2.8, 3 }, .{ 2.6285714285714286, 3.2857142857142856 }, .{ 2.4, 3 } };
    const upper = [_]Vec2{ .{ 2.5, 3.5 }, .{ 2.647058823529412, 3.5294117647058822 }, .{ 2.3333333333333335, 4 } };
    var two = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &lower, &upper }, &diag);
    defer two.deinit();
    var fat = try offset.offset(testing.allocator, &two, 0.5, .round, 3, .{}, &diag);
    defer fat.deinit();
    try testing.expectEqual(@as(usize, 1), fat.counts().faces);
    var both = try boolean.boolean(testing.allocator, &.{ &two, &fat }, .intersection, .{}, &diag);
    defer both.deinit();
    try testing.expectApproxEqRel(try areaOf(&two), try areaOf(&both), 1e-9);
    // The whole chain: a difference of two three-ring sheets, grown by one half
    const a1 = [_]Vec2{ .{ 1, 3 }, .{ 3, 2 }, .{ 0, 2 }, .{ 3, 2 } };
    const a2 = [_]Vec2{ .{ 4, 1 }, .{ 1, 6 }, .{ 2, 1 }, .{ 2, 5 }, .{ 0, 1 }, .{ 2, 4 }, .{ 5, 4 }, .{ 0, 3 } };
    const a3 = [_]Vec2{ .{ 2, 1 }, .{ 0, 5 }, .{ 0, 2 }, .{ 0, 4 } };
    var a = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &a1, &a2, &a3 }, &diag);
    defer a.deinit();
    const b1 = [_]Vec2{ .{ 0, 4 }, .{ 6, 1 }, .{ 6, 1 }, .{ 0, 2 }, .{ 6, 5 }, .{ 5, 3 }, .{ 5, 5 }, .{ 1, 4 } };
    const b2 = [_]Vec2{ .{ 0, 3 }, .{ 5, 3 }, .{ 4, 5 }, .{ 0, 0 }, .{ 3, 3 }, .{ 1, 6 } };
    var b = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &b1, &b2 }, &diag);
    defer b.deinit();
    var d = try boolean.boolean(testing.allocator, &.{ &a, &b }, .difference, .{}, &diag);
    defer d.deinit();
    var g = try offset.offset(testing.allocator, &d, 0.5, .round, 3, .{}, &diag);
    defer g.deinit();
    var held = try boolean.boolean(testing.allocator, &.{ &d, &g }, .intersection, .{}, &diag);
    defer held.deinit();
    try testing.expectApproxEqRel(try areaOf(&d), try areaOf(&held), 1e-9);
}

test "offset: a shrunk sheet lies within its sheet where the nesting ray passes a rounding below a vertex" {
    // The fuzzer's find (2026-11-09): a hull less a sheet, shrunk by one half with square
    // joins. One shrunk face's leftmost vertex is (2.7071, 0.9999999999999999), and the
    // ray from it to −x passes one rounding below the sheet's vertex (2, 1), where two
    // edges come down through the ray to that vertex at the same computed x; the most
    // clockwise of them was taken as nearer, as for a vertex on the ray, and the face was
    // nested in the plane, outside its sheet
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const a1 = [_]Vec2{ .{ 3, 3 }, .{ 2, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 2, 0 }, .{ 6, 2 } };
    const a2 = [_]Vec2{ .{ 6, 2 }, .{ 6, 1 }, .{ 5, 4 }, .{ 6, 1 }, .{ 1, 6 }, .{ 6, 4 } };
    const a3 = [_]Vec2{ .{ 2, 5 }, .{ 1, 4 }, .{ 0, 6 }, .{ 4, 3 }, .{ 5, 6 } };
    var a = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &a1, &a2, &a3 }, &diag);
    defer a.deinit();
    var h = try hull.hull(testing.allocator, &.{&a}, .{}, &diag);
    defer h.deinit();
    const b1 = [_]Vec2{ .{ 3, 4 }, .{ 5, 1 }, .{ 3, 5 }, .{ 6, 5 }, .{ 3, 0 }, .{ 2, 1 } };
    const b2 = [_]Vec2{ .{ 5, 3 }, .{ 1, 4 }, .{ 0, 4 }, .{ 0, 0 }, .{ 5, 0 }, .{ 0, 6 }, .{ 6, 1 }, .{ 1, 5 } };
    const b3 = [_]Vec2{ .{ 4, 6 }, .{ 0, 0 }, .{ 3, 4 }, .{ 1, 6 }, .{ 6, 5 }, .{ 1, 0 } };
    var b = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &b1, &b2, &b3 }, &diag);
    defer b.deinit();
    var d = try boolean.boolean(testing.allocator, &.{ &h, &b }, .difference, .{}, &diag);
    defer d.deinit();
    var s = try offset.offset(testing.allocator, &d, -0.5, .square, 4, .{}, &diag);
    defer s.deinit();
    var both = try boolean.boolean(testing.allocator, &.{ &d, &s }, .intersection, .{}, &diag);
    defer both.deinit();
    try testing.expectApproxEqRel(try areaOf(&s), try areaOf(&both), 1e-9);
}

test "offset: pieces smaller than the shrink are gone (the fuzzer's chain whose band line was tangent to a join)" {
    // A union of two three-ring sheets shrunk by a half leaves three pieces under a unit
    // across; shrunk by one and a half they are gone. A band line of the second shrink was
    // tangent to a join's circle: floating point said it missed, the arc's end was within
    // the zone of the line, and the cut there bent the line's piece across the arc with
    // no vertex at the crossing (overlay_test.zig has the geometry alone); the result was
    // eleven faces of area three, outside the sheet
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const a1 = [_]Vec2{ .{ 0, 3 }, .{ 6, 3 }, .{ 1, 5 }, .{ 0, 2 }, .{ 0, 6 } };
    const a2 = [_]Vec2{ .{ 2, 5 }, .{ 6, 1 }, .{ 5, 5 }, .{ 5, 0 }, .{ 3, 3 }, .{ 1, 3 } };
    const a3 = [_]Vec2{ .{ 1, 6 }, .{ 3, 5 }, .{ 4, 2 }, .{ 1, 5 }, .{ 1, 0 }, .{ 5, 4 }, .{ 0, 0 } };
    var a = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &a1, &a2, &a3 }, &diag);
    defer a.deinit();
    const b1 = [_]Vec2{ .{ 3, 2 }, .{ 0, 2 }, .{ 4, 4 }, .{ 5, 3 }, .{ 0, 1 }, .{ 6, 4 }, .{ 4, 0 }, .{ 3, 6 } };
    const b2 = [_]Vec2{ .{ 2, 6 }, .{ 0, 5 }, .{ 3, 1 }, .{ 0, 4 }, .{ 0, 1 }, .{ 0, 2 }, .{ 5, 4 }, .{ 0, 4 } };
    const b3 = [_]Vec2{ .{ 0, 2 }, .{ 0, 5 }, .{ 3, 0 }, .{ 4, 0 }, .{ 1, 0 }, .{ 4, 6 }, .{ 2, 3 }, .{ 6, 0 } };
    var b = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &b1, &b2, &b3 }, &diag);
    defer b.deinit();
    var u = try boolean.boolean(testing.allocator, &.{ &a, &b }, .@"union", .{}, &diag);
    defer u.deinit();
    var s1 = try offset.offset(testing.allocator, &u, -0.5, .round, 4, .{}, &diag);
    defer s1.deinit();
    try testing.expectEqual(@as(usize, 3), s1.counts().faces);
    try testing.expect(try areaOf(&s1) < 0.3);
    var s2 = try offset.offset(testing.allocator, &s1, -1.5, .round, 4, .{}, &diag);
    defer s2.deinit();
    try testing.expect(s2.isEmpty());
    // The one piece with arcs, alone, the same
    var window = try primitives.polygon(testing.allocator, tol, &.{ .{ 4, 1.5 }, .{ 4.7, 1.5 }, .{ 4.7, 2.4 }, .{ 4, 2.4 } }, &diag);
    defer window.deinit();
    var piece = try boolean.boolean(testing.allocator, &.{ &s1, &window }, .intersection, .{}, &diag);
    defer piece.deinit();
    try testing.expectEqual(@as(usize, 1), piece.counts().faces);
    var gone = try offset.offset(testing.allocator, &piece, -1.5, .round, 4, .{}, &diag);
    defer gone.deinit();
    try testing.expect(gone.isEmpty());
}

test "offset: a shrunk sheet lies within its sheet where two arcs meet a rounding above the nesting ray" {
    // The fuzzer's find (2026-11-12): the intersection of two three-ring sheets of lines
    // and arcs, united with a third, shrunk by one half with miter joins. The sheet's arcs
    // about (1.5, 0.5) and (1.5, −1.5) meet at a vertex a rounding above y = −0.5, where
    // their circles cross, and a sliver's arcs on the same circles meet there too; the
    // ray from the shrunk sheet's largest face, its leftmost vertex at y = −0.5, met the
    // two at one exact x, and the tie taken as a fan up from the ray put the face (of
    // area 16.9) in the plane, outside its sheet (overlay_test.zig has the geometry alone)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var s1 = try bulged(&.{
        &.{ .{ .p = .{ 0, 0 } }, .{ .p = .{ 0, 4 }, .bulge = 0.5 }, .{ .p = .{ 0, 2 } } },
        &.{ .{ .p = .{ 4, 0 } }, .{ .p = .{ 0, 4 }, .bulge = 0.5 }, .{ .p = .{ 4, 0 } }, .{ .p = .{ 6, 1 } }, .{ .p = .{ 3, 4 } }, .{ .p = .{ 5, 0 } } },
        &.{ .{ .p = .{ 2, 1 } }, .{ .p = .{ 0, 5 } }, .{ .p = .{ 0, 2 } }, .{ .p = .{ 6, 4 } }, .{ .p = .{ 2, 3 } }, .{ .p = .{ 0, 3 } }, .{ .p = .{ 1, 6 }, .bulge = 0.5 }, .{ .p = .{ 6, 0 }, .bulge = 0.5 } },
    }, &diag);
    defer s1.deinit();
    var s2 = try bulged(&.{
        &.{ .{ .p = .{ 4, 5 }, .bulge = 0.5, .ccw = false }, .{ .p = .{ 5, 1 } }, .{ .p = .{ 0, 6 } }, .{ .p = .{ 5, 4 } } },
        &.{ .{ .p = .{ 1, 0 }, .bulge = 1 }, .{ .p = .{ 3, 4 } }, .{ .p = .{ 2, 5 }, .bulge = -1, .ccw = false }, .{ .p = .{ 1, 2 }, .bulge = -0.5 }, .{ .p = .{ 0, 4 } } },
        &.{ .{ .p = .{ 4, 6 }, .bulge = 1 }, .{ .p = .{ 1, 4 } }, .{ .p = .{ 4, 5 }, .bulge = 0.5, .ccw = false } },
    }, &diag);
    defer s2.deinit();
    var s3 = try bulged(&.{
        &.{ .{ .p = .{ 3, 2 }, .bulge = 1 }, .{ .p = .{ 1, 5 } }, .{ .p = .{ 0, 0 }, .bulge = -1 }, .{ .p = .{ 3, 0 }, .bulge = -1 }, .{ .p = .{ 5, 4 } }, .{ .p = .{ 0, 2 }, .bulge = -1 } },
        &.{ .{ .p = .{ 2, 4 } }, .{ .p = .{ 2, 5 } }, .{ .p = .{ 6, 0 } }, .{ .p = .{ 2, 1 } }, .{ .p = .{ 6, 0 } }, .{ .p = .{ 3, 3 } }, .{ .p = .{ 2, 2 } }, .{ .p = .{ 1, 1 } } },
    }, &diag);
    defer s3.deinit();
    var common = try boolean.boolean(testing.allocator, &.{ &s1, &s2 }, .intersection, .{}, &diag);
    defer common.deinit();
    var sheet = try boolean.boolean(testing.allocator, &.{ &common, &s3 }, .@"union", .{}, &diag);
    defer sheet.deinit();
    var s = try offset.offset(testing.allocator, &sheet, -0.5, .miter, 3, .{}, &diag);
    defer s.deinit();
    try testing.expect(try areaOf(&s) > 19);
    for ([_][2]*const Body{ .{ &s, &sheet }, .{ &sheet, &s } }) |pair| {
        var both = try boolean.boolean(testing.allocator, &pair, .intersection, .{}, &diag);
        defer both.deinit();
        try testing.expectApproxEqRel(try areaOf(&s), try areaOf(&both), 1e-9);
    }
    var outside = try boolean.boolean(testing.allocator, &.{ &s, &sheet }, .difference, .{}, &diag);
    defer outside.deinit();
    try testing.expectEqual(@as(usize, 0), outside.counts().faces);
}

test "offset: a cusp turns a half turn to its face's side, joined with each join (a square less a quarter disc)" {
    // The square [0, 2]² less the quarter disc about (0, 2) of radius 2: the arc ends
    // tangent to the bottom at (0, 0) and to the right side at (2, 2), two cusps where the
    // tangents oppose and their cross is exactly 0. Grown by one half, the region is the
    // sheet, the bands along its sides and its arc, and the joins: at each cusp a half
    // disc for round (with the quarter disc at (2, 0), Steiner's A + Pδ + πδ² in all),
    // a δ by 2δ cap for square and miter (the offset lines are parallel), nothing for
    // bevel. The plate [−2, 4]² with the sheet as a hole, shrunk by one half, loses the
    // same about the hole, whose cusps turn the other way
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const spandrel = [_]RingPoint{ .{ .p = .{ 0, 0 } }, .{ .p = .{ 2, 0 } }, .{ .p = .{ 2, 2 }, .bulge = -1, .ccw = false } };
    var sheet = try bulged(&.{&spandrel}, &diag);
    defer sheet.deinit();
    const plate = [_]RingPoint{ .{ .p = .{ -2, -2 } }, .{ .p = .{ 4, -2 } }, .{ .p = .{ 4, 4 } }, .{ .p = .{ -2, 4 } } };
    var holed = try bulged(&.{ &plate, &spandrel }, &diag);
    defer holed.deinit();
    // The sheet, its sides' bands and its arc's annular sector between radii 2 and 1.5
    const banded: f64 = 4 - PI + 2 + PI / 4.0 * (4 - 1.5 * 1.5);
    const joins = [_]struct { join: offset.Join, corners: f64 }{
        .{ .join = .round, .corners = PI / 16.0 + PI / 4.0 },
        .{ .join = .square, .corners = 0.25 * (2 * @sqrt(2.0) - 2) + 1 },
        .{ .join = .miter, .corners = 0.25 + 1 },
        .{ .join = .bevel, .corners = 0.125 },
    };
    for (joins) |j| {
        errdefer std.debug.print("the join: {s}\n", .{@tagName(j.join)});
        var g = try grown(&sheet, 0.5, j.join, &diag);
        defer g.deinit();
        try testing.expectApproxEqRel(banded + j.corners, try areaOf(&g), 1e-12);
        var s = try grown(&holed, -0.5, j.join, &diag);
        defer s.deinit();
        try testing.expectApproxEqRel(25 - banded - j.corners, try areaOf(&s), 1e-12);
    }
}

test "offset: a grown sheet holds the disc about its cusp, turned or not (the fuzzer's chain whose join came and went)" {
    // The fuzzer's find (2026-11-14, run 43585380964): a triangle whose side from (0, 3)
    // to (2, 1) is an arc about (0, 1) of radius 2, which crosses the side from (2, 2) at
    // (1.6, 2.2) and ends at (2, 1) tangent to the side x = 2 (the fuzzer's sheet had a
    // second ring, a spur that fills nothing). Grown by 1.5 with round joins: the tangents'
    // cross at the cusp was exactly 0 and the half disc below it was left out (13.81); on
    // the sheet turned 0.3 about z and moved far out the cross was a rounding above 0 and
    // it was put in (16.98; a fine grid of distances to the sheet gives 16.979)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try bulged(&.{&.{ .{ .p = .{ 2, 2 } }, .{ .p = .{ 0, 3 }, .bulge = -1, .ccw = false }, .{ .p = .{ 2, 1 } } }}, &diag);
    defer sheet.deinit();
    var g = try offset.offset(testing.allocator, &sheet, 1.5, .round, 3, .{}, &diag);
    defer g.deinit();
    try testing.expect(try query.contains(&g, .{ 2, -0.4 }, tol.zone, &diag));
    try testing.expect(try areaOf(&g) > 16.97);
    const move = mat.Affine.translate(.{ 1e5, -2e5, 0 }).compose(&mat.Affine.rotate(vec.Z3, 0.3));
    var moved = try transform.transform(testing.allocator, &sheet, &move, .{}, &diag);
    defer moved.deinit();
    var gm = try offset.offset(testing.allocator, &moved, 1.5, .round, 3, .{}, &diag);
    defer gm.deinit();
    try testing.expectApproxEqRel(try areaOf(&g), try areaOf(&gm), 1e-9);
}

test "offset: a miter reaching the limit is a miter, turned any way (the fuzzer's corner at exactly the limit)" {
    // The fuzzer's find (nightly 2026-11-18, run 44297393647): a corner whose miter reached
    // exactly twice the offset, the limit, was squared off on the sheet as drawn (the reach
    // a rounding past it) and mitered on the sheet turned 0.014 about z (a rounding short),
    // 124.04 against 124.48. Each corner of an equilateral triangle turns a third of a
    // turn, so its miter reaches 1 / cos 60° = 2 offsets: grown by 1 with the limit 2, it
    // is the equilateral triangle of inradius 1 / √3 + 1 whichever way it is turned
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const s3: f64 = @sqrt(3.0);
    const corners = [_]Vec2{ .{ 0, 0 }, .{ 2, 0 }, .{ 1, s3 } };
    var tri = try primitives.polygon(testing.allocator, tol, &corners, &diag);
    defer tri.deinit();
    const inradius = 1 / s3 + 1;
    for (0..64) |k| {
        const turn = mat.Affine.rotate(vec.Z3, @as(f64, @floatFromInt(k)) * 0.1);
        var turned = try transform.transform(testing.allocator, &tri, &turn, .{}, &diag);
        defer turned.deinit();
        var g = try grown(&turned, 1, .miter, &diag);
        defer g.deinit();
        try testing.expectApproxEqRel(3 * s3 * inradius * inradius, try areaOf(&g), 1e-9);
        try testing.expectEqual(@as(usize, 3), g.counts().edges);
    }
}

/// The seam family's segment as an outline: the arc from `start` through `SEGMENT_ANGLE`
/// counter-clockwise about the origin, and its chord back.
fn segmentOutline(start: f64) [2]primitives.OutlineEdge {
    const a: Vec2 = .{ SEGMENT_RADIUS * @cos(start), SEGMENT_RADIUS * @sin(start) };
    const b: Vec2 = .{ SEGMENT_RADIUS * @cos(start + SEGMENT_ANGLE), SEGMENT_RADIUS * @sin(start + SEGMENT_ANGLE) };
    return .{ .{ .a = a, .b = b, .arc = .{ .c = .{ 0, 0 }, .r = SEGMENT_RADIUS, .ccw = true } }, .{ .a = b, .b = a } };
}

test "offset: a segment of a disc grown with bevels, then with each join, is the same wherever its arc ends by its circle's seam, a sheet or a hole" {
    // The nightly's find (2026-11-20, bm; run 44729658253): the first offset's arc had a
    // vertex to +x of its centre, where the sweeps of the sheet's arc, two edges there
    // (D7), met; the piece from the arc's end to it, 0.0012 rad, was within the zone of
    // its chord and was made a line, 6e-4 rad off the circle's tangent; the second
    // offset's bevel at that end went by the line and came 9e-4 short at 1.5 (82.93347; on
    // the sheet turned, the vertex elsewhere on the arc, 82.93419).
    //
    // A segment under the angle Δ is convex, so grown by d with bevels it gains its
    // perimeter times d, the arc's turn Δ as a sector, ½·d²·Δ, and at each of its two
    // corners, which turn τ = π − Δ/2, the triangle ½·d²·sin τ; its corners are then four,
    // each turning τ/2, about bevels 2·d·sin(τ/2) long, and grown again it gains the same
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const r = SEGMENT_RADIUS;
    const angle = SEGMENT_ANGLE;
    const d1 = SEAM_OFFSETS[0];
    const d2 = SEAM_OFFSETS[1];
    const turn = PI - angle / 2.0;
    const chord = 2 * r * @sin(angle / 2.0);
    const once = r * r * (angle - @sin(angle)) / 2.0 + (r * angle + chord) * d1 + d1 * d1 * angle / 2.0 + d1 * d1 * @sin(turn);
    const perimeter_once = (r + d1) * angle + chord + 4 * d1 * @sin(turn / 2.0);
    const twice = once + perimeter_once * d2 + d2 * d2 * angle / 2.0 + 2 * d2 * d2 * @sin(turn / 2.0);
    const plate_left = (SEAM_PLATE - 2 * (d1 + d2)) * (SEAM_PLATE - 2 * (d1 + d2));
    const half = SEAM_PLATE / 2.0;
    const plate = [_]primitives.OutlineEdge{
        .{ .a = .{ -half, -half }, .b = .{ half, -half } },
        .{ .a = .{ half, -half }, .b = .{ half, half } },
        .{ .a = .{ half, half }, .b = .{ -half, half } },
        .{ .a = .{ -half, half }, .b = .{ -half, -half } },
    };
    for ([_]bool{ false, true }) |hole| {
        const sign: f64 = if (hole) -1 else 1;
        for (std.enums.values(offset.Join)) |join| {
            if (join == .round) continue;
            // The control's area, the last gap's: what the others must come to
            var control: [2]f64 = undefined;
            var gap_at = SEAM_GAPS.len;
            while (gap_at > 0) {
                gap_at -= 1;
                const gap = SEAM_GAPS[gap_at];
                for ([_]bool{ false, true }, 0..) |past, which| {
                    errdefer std.debug.print("the arc {s} the seam by {d}, the second join {s}, as a {s}\n", .{ if (past) "ending past" else "starting short of", gap, @tagName(join), if (hole) "hole" else "sheet" });
                    const segment = segmentOutline(if (past) gap - SEGMENT_ANGLE else -gap);
                    var sheet = try primitives.outlines(testing.allocator, tol, if (hole) &.{ &plate, &segment } else &.{&segment}, &diag);
                    defer sheet.deinit();
                    var first = try offset.offset(testing.allocator, &sheet, sign * d1, .bevel, 2, .{}, &diag);
                    defer first.deinit();
                    try testing.expectApproxEqRel(if (hole) (SEAM_PLATE - 2 * d1) * (SEAM_PLATE - 2 * d1) - once else once, try areaOf(&first), SEAM_AREA_CLOSE);
                    var second = try offset.offset(testing.allocator, &first, sign * d2, join, 2, .{}, &diag);
                    defer second.deinit();
                    const area = try areaOf(&second);
                    if (gap_at == SEAM_GAPS.len - 1) control[which] = area;
                    try testing.expectApproxEqRel(control[which], area, SEAM_AREA_CLOSE);
                    if (join == .bevel) try testing.expectApproxEqRel(if (hole) plate_left - twice else twice, area, SEAM_AREA_CLOSE);
                }
            }
        }
    }
}

test "offset: a cusp's miter is a cap however the sheet is turned, mirrored or moved, whatever the limit (the find dh)" {
    // The 2D chain fuzzer's find dh (2026-11-22): at a cusp, an arc arriving tangent to the
    // line it leaves by, the offset lines are parallel and the miter is capped; moved 2e5
    // out and turned 0.014, the tangents' cross was a rounding of 1e-11, the lines met
    // 4.1e6 away, and with no limit to speak of that was the miter. The spandrel's two
    // cusps (the cusp test's square less a quarter disc), grown by δ: the sheet, its sides'
    // bands, the annular sector inside its arc, δ² at the square corner and 2δ² at each
    // cusp, wherever it is and whichever way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const spandrel = [_]RingPoint{ .{ .p = .{ 0, 0 } }, .{ .p = .{ 2, 0 } }, .{ .p = .{ 2, 2 }, .bulge = -1, .ccw = false } };
    var sheet = try bulged(&.{&spandrel}, &diag);
    defer sheet.deinit();
    for (CUSP_MOVES) |move| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        const turn = mat.Affine.rotate(vec.Z3, move.angle + @as(f64, @floatFromInt(quarter)) * PI / 2);
        const mirror = if (mirrored) mat.Affine.mirror(vec.X3) else mat.Affine.translate(.{ 0, 0, 0 });
        const place = mat.Affine.translate(.{ move.shift[0], move.shift[1], 0 }).compose(&turn).compose(&mirror);
        var moved = try transform.transform(testing.allocator, &sheet, &place, .{}, &diag);
        defer moved.deinit();
        for (CUSP_OFFSETS) |delta| for (CUSP_LIMITS) |limit| {
            errdefer std.debug.print("turned {d} and {d} quarters, mirrored {}, shifted {any}; grown {d} with the limit {e}\n", .{ move.angle, quarter, mirrored, move.shift, delta, limit });
            var g = try offset.offset(testing.allocator, &moved, delta, .miter, limit, .{}, &diag);
            defer g.deinit();
            const want = 4 - PI + 4 * delta + PI / 4.0 * (4 - (2 - delta) * (2 - delta)) + 5 * delta * delta;
            try testing.expectApproxEqRel(want, try areaOf(&g), CUSP_AREA_CLOSE);
        };
    };
}

test "offset: an arc whose end lies off its circle within the zone moves to the moved circle, not by the circle's growth times its error" {
    // The audit of 2026-11-22 (kind 8, C3): an arc's moved ends were its ends scaled about
    // the centre by the moved radius over the radius. An end 9e-6 inside a circle of
    // radius 5e-5, grown by 1, landed 0.18 inside the moved circle, and the band's region
    // was drawn with an arc that far off its end. The moved end is the moved circle's
    // point on the ray through the end
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const r = OFF_CIRCLE_RADIUS;
    for (OFF_CIRCLE_INSIDE) |inside| for (OFF_CIRCLE_GROWTHS) |delta| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("{d} zones inside, grown {d}, mirrored {}\n", .{ inside, delta, mirrored });
        const end: Vec2 = .{ 1 - inside * tol.zone, r };
        var edges = [_]primitives.OutlineEdge{
            .{ .a = .{ 0, 0 }, .b = .{ 1 - r, 0 } },
            .{ .a = .{ 1 - r, 0 }, .b = end, .arc = .{ .c = .{ 1 - r, r }, .r = r, .ccw = true } },
            .{ .a = end, .b = .{ 1, 1 } },
            .{ .a = .{ 1, 1 }, .b = .{ 0, 1 } },
            .{ .a = .{ 0, 1 }, .b = .{ 0, 0 } },
        };
        if (mirrored) {
            // Mirrored in the y axis and run the other way round, a region still
            var turned: [edges.len]primitives.OutlineEdge = undefined;
            for (edges, 0..) |e, k| {
                turned[edges.len - 1 - k] = .{ .a = .{ -e.b[0], e.b[1] }, .b = .{ -e.a[0], e.a[1] } };
                if (e.arc) |arc| turned[edges.len - 1 - k].arc = .{ .c = .{ -arc.c[0], arc.c[1] }, .r = arc.r, .ccw = true };
            }
            edges = turned;
        }
        var sheet = try primitives.outlines(testing.allocator, tol, &.{&edges}, &diag);
        defer sheet.deinit();
        var round = try grown(&sheet, delta, .round, &diag);
        defer round.deinit();
        try testing.expectApproxEqAbs(1 + 4 * delta + PI * delta * delta, try areaOf(&round), OFF_CIRCLE_CLOSE);
        var back = try grown(&round, -delta, .round, &diag);
        defer back.deinit();
        try testing.expectApproxEqAbs(@as(f64, 1), try areaOf(&back), OFF_CIRCLE_CLOSE);
    };
}
