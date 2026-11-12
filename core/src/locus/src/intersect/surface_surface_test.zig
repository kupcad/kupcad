//! A plane against each surface kind: a plane across, along and beside another; a cylinder
//! along the normal (a circle), lying in the plane (two lines, a touch, a miss) and tilted
//! (an ellipse); a cone along its axis and across it (refused); a sphere cut, touched and
//! missed; a torus cut through its tube, touched at its crown and across its axis
//! (refused); an axis a rounding off the normal cut as the normal.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const geometry = @import("../geometry/types.zig");
const surfaces = @import("../geometry/surfaces.zig");
const curves = @import("../geometry/curves.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const curve_surface = @import("curve_surface.zig");
const surface_surface = @import("surface_surface.zig");
const Plane = curve_surface.Plane;
const Frame = geometry.Frame;
const Surface = surfaces.Surface;
const Trace = surface_surface.Trace;
const Vec3 = vec.Vec3;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
const CLOSE = 1e-9;
/// The size of the region every case is cut over.
const EXTENT = 20;

fn traceAt(surface: Surface, height: f64) !Trace {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return surface_surface.planeSurface(Plane.level(height), surface, .{ 0, 0, height }, EXTENT, tol, &diag);
}

fn expectRefused(surface: Surface, height: f64) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.NotImplemented, surface_surface.planeSurface(Plane.level(height), surface, .{ 0, 0, height }, EXTENT, tol, &diag));
    try testing.expectEqual(.not_implemented, diag.first().?.code);
}

fn expectVec(want: Vec3, got: Vec3) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(want[k], got[k], CLOSE);
}

/// A circle turning counter-clockwise seen from above, about `c` of radius `r`.
fn expectCircle(c: Vec3, r: f64, curve: curves.Curve) !void {
    const circle = curve.circle;
    try expectVec(c, circle.c);
    try testing.expectApproxEqAbs(r, circle.r, CLOSE);
    try expectVec(vec.Z3, circle.normal());
}

test "planeSurface: a plane across another is a line in both; parallel ones coincide or miss" {
    const wall: Surface = .{ .plane = .{ .frame = Frame.fromAxis(.{ 3, 0, 0 }, vec.normalized(.{ 1, 1, 0 }).?) } };
    const cut = try traceAt(wall, 4);
    try testing.expectEqual(.curves, cut.kind);
    const line = cut.curves[0].line;
    try testing.expectApproxEqAbs(@as(f64, 4), line.o[2], CLOSE);
    try testing.expectApproxEqAbs(@as(f64, 0), line.d[2], CLOSE);
    // On the wall: (p − (3, 0, 0))·n = 0
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(vec.sub(line.o, .{ 3, 0, 0 }), vec.normalized(.{ 1, 1, 0 }).?), CLOSE);
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(line.d, .{ 1, 1, 0 }), CLOSE);
    const floor: Surface = .{ .plane = .{ .frame = Frame.fromAxis(.{ 5, 5, 2 }, vec.neg(vec.Z3)) } };
    try testing.expectEqual(.coincident, (try traceAt(floor, 2)).kind);
    try testing.expectEqual(.none, (try traceAt(floor, 2.5)).kind);
}

test "planeSurface: a cylinder is a circle along the normal, two lines lying in the plane, an ellipse tilted" {
    const standing: Surface = .{ .cylinder = .{ .frame = Frame.fromAxis(.{ 1, 2, -3 }, vec.Z3), .r = 4 } };
    const ring = try traceAt(standing, 6);
    try testing.expectEqual(@as(u8, 1), ring.count);
    try expectCircle(.{ 1, 2, 6 }, 4, ring.curves[0]);
    // Its axis along x at height 2, radius 1: generators at y = ±√(1 − 0.5²) for height 2.5
    const lying: Surface = .{ .cylinder = .{ .frame = Frame.fromAxis(.{ 0, 0, 2 }, vec.X3), .r = 1 } };
    const two = try traceAt(lying, 2.5);
    try testing.expectEqual(@as(u8, 2), two.count);
    var ys: [2]f64 = undefined;
    for (two.slice(), &ys) |curve, *y| {
        try testing.expectApproxEqAbs(@as(f64, 2.5), curve.line.o[2], CLOSE);
        try expectVec(vec.X3, .{ @abs(curve.line.d[0]), curve.line.d[1], curve.line.d[2] });
        y.* = curve.line.o[1];
    }
    std.mem.sort(f64, &ys, {}, std.sort.asc(f64));
    try testing.expectApproxEqAbs(-@sqrt(0.75), ys[0], CLOSE);
    try testing.expectApproxEqAbs(@sqrt(0.75), ys[1], CLOSE);
    try testing.expectEqual(.tangent, (try traceAt(lying, 3)).kind);
    try testing.expectEqual(.tangent, (try traceAt(lying, 1)).kind);
    try testing.expectEqual(.none, (try traceAt(lying, 3.5)).kind);
    // Tilted a sixth of a turn from the normal: an ellipse of semi-axes r / cos 60° and r
    const tilted: Surface = .{ .cylinder = .{ .frame = Frame.fromAxis(.{ 0, 0, 0 }, .{ 0, @sin(PI / 3.0), @cos(PI / 3.0) }), .r = 1 } };
    const ellipse = (try traceAt(tilted, 0)).curves[0].ellipse;
    try testing.expectApproxEqAbs(@as(f64, 2), ellipse.a, CLOSE);
    try testing.expectApproxEqAbs(@as(f64, 1), ellipse.b, CLOSE);
    try expectVec(vec.Z3, ellipse.normal());
    // Every point of it on the cylinder: its distance from the axis is the radius
    for (0..8) |k| {
        const p = curves.Curve.eval(.{ .ellipse = ellipse }, @as(f64, @floatFromInt(k)) * PI / 4.0);
        const axis: Vec3 = .{ 0, @sin(PI / 3.0), @cos(PI / 3.0) };
        try testing.expectApproxEqAbs(@as(f64, 1), vec.length(vec.sub(p, vec.scale(axis, vec.dot(p, axis)))), CLOSE);
        try testing.expectApproxEqAbs(@as(f64, 0), p[2], CLOSE);
    }
}

test "planeSurface: an axis a rounding off the normal (a solid turned a right angle) is cut as the normal" {
    const rounded: Vec3 = vec.normalized(.{ 6.123233995736766e-17, 0, 1 }).?;
    const cyl: Surface = .{ .cylinder = .{ .frame = Frame.fromAxis(.{ 0, 0, 0 }, rounded), .r = 2 } };
    const cut = try traceAt(cyl, 5);
    try expectCircle(.{ 0, 0, 5 }, 2, cut.curves[0]);
    const lying: Surface = .{ .cylinder = .{ .frame = Frame.fromAxis(.{ 0, 0, 0 }, vec.normalized(.{ 1, 0, 6.123233995736766e-17 }).?), .r = 2 } };
    try testing.expectEqual(@as(u8, 2), (try traceAt(lying, 1)).count);
}

test "planeSurface: a cone along its axis is a circle, its apex a touch; across its axis it waits for M5" {
    // Radius 2 at its frame's origin, widening upward by tan 30° per unit of height
    const cone: Surface = .{ .cone = .{ .frame = Frame.fromAxis(.{ 0, 0, 1 }, vec.Z3), .r = 2, .half_angle = PI / 6.0 } };
    const cut = try traceAt(cone, 4);
    try expectCircle(.{ 0, 0, 4 }, 2 + 3 * @tan(PI / 6.0), cut.curves[0]);
    try testing.expectEqual(.tangent, (try traceAt(cone, 1.0 - 2.0 / @tan(PI / 6.0))).kind);
    const tilted: Surface = .{ .cone = .{ .frame = Frame.fromAxis(.{ 0, 0, 1 }, vec.X3), .r = 2, .half_angle = PI / 6.0 } };
    try expectRefused(tilted, 1);
}

test "planeSurface: a sphere is cut in a circle, touched at its poles, missed beyond" {
    const ball: Surface = .{ .sphere = .{ .frame = Frame.fromAxis(.{ 1, -1, 2 }, vec.Z3), .r = 5 } };
    try expectCircle(.{ 1, -1, 5 }, 4, (try traceAt(ball, 5)).curves[0]);
    try expectCircle(.{ 1, -1, -1 }, 4, (try traceAt(ball, -1)).curves[0]);
    try testing.expectEqual(.tangent, (try traceAt(ball, 7)).kind);
    try testing.expectEqual(.tangent, (try traceAt(ball, -3)).kind);
    try testing.expectEqual(.none, (try traceAt(ball, 7.1)).kind);
}

test "planeSurface: a torus along its axis is two circles, touched at its crown; across it waits for M5" {
    const ring: Surface = .{ .torus = .{ .frame = Frame.fromAxis(.{ 0, 0, 1 }, vec.Z3), .major = 5, .minor = 1 } };
    const middle = try traceAt(ring, 1);
    try testing.expectEqual(@as(u8, 2), middle.count);
    try expectCircle(.{ 0, 0, 1 }, 6, middle.curves[0]);
    try expectCircle(.{ 0, 0, 1 }, 4, middle.curves[1]);
    const upper = try traceAt(ring, 1.5);
    try expectCircle(.{ 0, 0, 1.5 }, 5 + @sqrt(0.75), upper.curves[0]);
    try expectCircle(.{ 0, 0, 1.5 }, 5 - @sqrt(0.75), upper.curves[1]);
    try testing.expectEqual(.tangent, (try traceAt(ring, 2)).kind);
    try testing.expectEqual(.none, (try traceAt(ring, 2.5)).kind);
    const standing: Surface = .{ .torus = .{ .frame = Frame.fromAxis(.{ 0, 0, 1 }, vec.X3), .major = 5, .minor = 1 } };
    try expectRefused(standing, 1);
}
