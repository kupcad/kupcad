//! A curve against a plane: a line crossing, ending on, lying in and missing it; a circle
//! standing across it (two crossings, a touch, a miss, part of its turn), one lying in it
//! and one level above it; an ellipse; and the zone at the ends.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const curves = @import("../geometry/curves.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const curve_surface = @import("curve_surface.zig");
const Plane = curve_surface.Plane;
const Curve = curves.Curve;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
const CLOSE = 1e-12;

fn crossings(curve: Curve, t0: f64, t1: f64, height: f64) !curve_surface.Crossings {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return curve_surface.curvePlane(curve, t0, t1, Plane.level(height), tol, &diag);
}

fn expectParams(want: []const f64, got: curve_surface.Crossings) !void {
    try testing.expect(!got.lies_in);
    try testing.expectEqual(want.len, got.params().len);
    for (want, got.params()) |w, g| try testing.expectApproxEqAbs(w, g, CLOSE);
}

test "curvePlane: a line crosses, ends on, lies in or misses a plane" {
    const up: Curve = .{ .line = .{ .o = .{ 1, 2, 0 }, .d = vec.Z3 } };
    try expectParams(&.{5}, try crossings(up, 0, 10, 5));
    try expectParams(&.{0}, try crossings(up, 0, 10, 0));
    try expectParams(&.{10}, try crossings(up, 0, 10, 10));
    try expectParams(&.{}, try crossings(up, 0, 10, 11));
    // An end a fraction of the zone off the plane is on it
    try expectParams(&.{10}, try crossings(up, 0, 10, 10 + 0.5e-5));
    const level: Curve = .{ .line = .{ .o = .{ 0, 0, 3 }, .d = vec.X3 } };
    try testing.expect((try crossings(level, -4, 4, 3)).lies_in);
    try expectParams(&.{}, try crossings(level, -4, 4, 3.5));
    // A slope crossing in the middle of its range
    const slope: Curve = .{ .line = .{ .o = .{ 0, 0, 0 }, .d = vec.normalized(.{ 1, 0, 1 }).? } };
    try expectParams(&.{@sqrt(2.0)}, try crossings(slope, 0, 4, 1));
}

test "curvePlane: a circle standing across a plane crosses it twice, touches it or misses it" {
    // In the xz-plane about (0, 0, 5): its height is 5 + 2 sin t
    const standing: Curve = .{ .circle = .{ .c = .{ 0, 0, 5 }, .x = vec.X3, .y = vec.Z3, .r = 2 } };
    try expectParams(&.{ 0, PI }, try crossings(standing, 0, 2 * PI, 5));
    try expectParams(&.{ PI + PI / 6.0, 2 * PI - PI / 6.0 }, try crossings(standing, 0, 2 * PI, 4));
    try expectParams(&.{PI / 2.0}, try crossings(standing, 0, 2 * PI, 7));
    try expectParams(&.{}, try crossings(standing, 0, 2 * PI, 7.5));
    // Part of its turn: one root inside, the other outside the range
    try expectParams(&.{PI / 6.0}, try crossings(standing, 0, PI / 2.0, 6));
    // A range starting past a turn: the roots taken into it
    try expectParams(&.{ 2 * PI + PI / 6.0, 3 * PI - PI / 6.0 }, try crossings(standing, 2 * PI, 4 * PI, 6));
}

test "curvePlane: a level circle lies in its plane and misses the others; an ellipse crosses twice" {
    const level: Curve = .{ .circle = curves.Circle.inPlane(.{ 1, 1, 2 }, vec.Z3, 3) };
    try testing.expect((try crossings(level, 0, 2 * PI, 2)).lies_in);
    try testing.expect((try crossings(level, 1, 2, 2 + 0.5e-5)).lies_in);
    try expectParams(&.{}, try crossings(level, 0, 2 * PI, 2.1));
    // Semi-axes 4 along x and 1 along z about the origin: height sin t
    const ellipse: Curve = .{ .ellipse = .{ .c = .{ 0, 0, 0 }, .x = vec.X3, .y = vec.Z3, .a = 4, .b = 1 } };
    try expectParams(&.{ PI / 6.0, PI - PI / 6.0 }, try crossings(ellipse, 0, 2 * PI, 0.5));
}
