//! Offsets against closed forms: a square grown with each join, shrunk, shrunk to nothing;
//! a circle; a plate with a hole, whose hole shrinks as the plate grows.

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
