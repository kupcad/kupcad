//! Contours at a resolution, containment with the outline's tolerance, convexity, and the
//! hull of sketches.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const mass = @import("../measure/mass.zig");
const boolean = @import("boolean.zig");
const query = @import("query.zig");
const hull = @import("hull.zig");
const Vec2 = vec.Vec2;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;

test "contours: a square is its corners, a circle its segments at the resolution, a hole runs clockwise" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 4, 3, false, &diag);
    defer sq.deinit();
    var outline = try query.contours(testing.allocator, &sq, .{}, &diag);
    defer outline.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), outline.count());
    try testing.expectEqual(@as(usize, 4), outline.contour(0).len);

    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    var rim = try query.contours(testing.allocator, &disc, .{ .segments = 64 }, &diag);
    defer rim.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 64), rim.contour(0).len);
    for (rim.contour(0)) |p| try testing.expectApproxEqAbs(@as(f64, 2), vec.length2(p), 1e-12);
    // Counter-clockwise: the second point is above the first (which is at angle 0)
    try testing.expect(rim.contour(0)[1][1] > 0);

    var small = try primitives.circle(testing.allocator, tol, 1, &diag);
    defer small.deinit();
    var hole = try transform.transform(testing.allocator, &small, &mat.Affine.translate(.{ 2, 1.5, 0 }), .{}, &diag);
    defer hole.deinit();
    var pierced = try boolean.boolean(testing.allocator, &.{ &sq, &hole }, .difference, .{}, &diag);
    defer pierced.deinit();
    var both = try query.contours(testing.allocator, &pierced, .{ .segments = 16 }, &diag);
    defer both.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), both.count());
    try testing.expectEqual(@as(usize, 16), both.contour(1).len);
    // The hole's polyline runs clockwise: negative area by the shoelace
    const ring = both.contour(1);
    var area: f64 = 0;
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        area += p[0] * q[1] - q[0] * p[1];
    }
    try testing.expect(area < 0);
}

test "contains: inside, outside, in a hole, and on an outline within the tolerance" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 10, 10, false, &diag);
    defer sq.deinit();
    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    var hole = try transform.transform(testing.allocator, &disc, &mat.Affine.translate(.{ 5, 5, 0 }), .{}, &diag);
    defer hole.deinit();
    var pierced = try boolean.boolean(testing.allocator, &.{ &sq, &hole }, .difference, .{}, &diag);
    defer pierced.deinit();
    try testing.expect(try query.contains(&pierced, .{ 1, 1 }, 1e-9, &diag));
    try testing.expect(!try query.contains(&pierced, .{ 11, 1 }, 1e-9, &diag));
    try testing.expect(!try query.contains(&pierced, .{ 5, 5 }, 1e-9, &diag));
    try testing.expect(try query.contains(&pierced, .{ 5, 7 }, 1e-9, &diag));
    // Just inside the hole: on its rim within a loose tolerance, in it within a tight one
    try testing.expect(try query.contains(&pierced, .{ 5, 6.9995 }, 1e-3, &diag));
    try testing.expect(!try query.contains(&pierced, .{ 5, 6.9995 }, 1e-6, &diag));
    try testing.expect(try query.contains(&pierced, .{ 10.0005, 3 }, 1e-3, &diag));
    try testing.expect(try query.contains(&disc, .{ 1.9, 0 }, 1e-9, &diag));
    try testing.expect(!try query.contains(&disc, .{ 2.1, 0 }, 1e-9, &diag));
}

test "convex: a square and a disc are, an L and a pierced plate are not" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 4, 3, false, &diag);
    defer sq.deinit();
    try testing.expect(try query.isConvex(&sq, &diag));
    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    try testing.expect(try query.isConvex(&disc, &diag));
    var ell = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 1 }, .{ 1, 1 }, .{ 1, 4 }, .{ 0, 4 } }, &diag);
    defer ell.deinit();
    try testing.expect(!try query.isConvex(&ell, &diag));
    var hole = try transform.transform(testing.allocator, &disc, &mat.Affine.translate(.{ 2, 1.5, 0 }), .{}, &diag);
    defer hole.deinit();
    var inner = try primitives.circle(testing.allocator, tol, 1, &diag);
    defer inner.deinit();
    var small = try transform.transform(testing.allocator, &inner, &mat.Affine.translate(.{ 2, 1.5, 0 }), .{}, &diag);
    defer small.deinit();
    var pierced = try boolean.boolean(testing.allocator, &.{ &sq, &small }, .difference, .{}, &diag);
    defer pierced.deinit();
    try testing.expect(!try query.isConvex(&pierced, &diag));
    // A square less a disc at its corner: the concave arc makes it not convex
    var bitten = try boolean.boolean(testing.allocator, &.{ &sq, &disc }, .difference, .{}, &diag);
    defer bitten.deinit();
    try testing.expect(!try query.isConvex(&bitten, &diag));
}

test "hull: of two squares apart, of a disc (its extreme points), and of points on a line is refused" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try primitives.square(testing.allocator, tol, 2, 2, false, &diag);
    defer a.deinit();
    var b = try transform.transform(testing.allocator, &a, &mat.Affine.translate(.{ 5, 1, 0 }), .{}, &diag);
    defer b.deinit();
    var both = try hull.hull(testing.allocator, &.{ &a, &b }, .{}, &diag);
    defer both.deinit();
    try testing.expectEqual(@as(usize, 6), both.counts().edges);
    try testing.expectApproxEqRel(@as(f64, 16), (try mass.mass(&both, .{}, &diag)).area, 1e-12);
    try testing.expect(try query.isConvex(&both, &diag));

    var disc = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer disc.deinit();
    var diamond = try hull.hull(testing.allocator, &.{&disc}, .{}, &diag);
    defer diamond.deinit();
    try testing.expectEqual(@as(usize, 4), diamond.counts().edges);
    try testing.expectApproxEqRel(@as(f64, 8), (try mass.mass(&diamond, .{}, &diag)).area, 1e-12);

    const ring = try hull.hullOf(testing.allocator, &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } });
    defer testing.allocator.free(ring);
    try testing.expectEqual(@as(usize, 2), ring.len);
}
