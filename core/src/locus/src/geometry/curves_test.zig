const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const Vec3 = vec.Vec3;
const Curve = curves.Curve;

/// The finite-difference step for checking derivatives, and the larger one for second
/// differences (rounding error grows as 1/H²).
const H: f64 = 1e-6;
const H2: f64 = 1e-4;
const DERIV_TOL: f64 = 1e-6;

fn expectVec(expected: Vec3, actual: Vec3, tol: f64) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(expected[k], actual[k], tol);
}

/// Checks a curve's derivatives against central differences at `t`.
fn expectDerivatives(curve: Curve, t: f64) !void {
    const s = curve.sample(t);
    try expectVec(curve.eval(t), s.p, 1e-12);
    const d1 = vec.scale(vec.sub(curve.eval(t + H), curve.eval(t - H)), 1.0 / (2.0 * H));
    try expectVec(d1, s.d1, DERIV_TOL);
    const d2 = vec.scale(vec.add(vec.sub(curve.eval(t + H2), vec.scale(curve.eval(t), 2.0)), curve.eval(t - H2)), 1.0 / (H2 * H2));
    try expectVec(d2, s.d2, 1e-6);
}

test "Line: through two points, parameterized by length, projected by dot product" {
    const line = curves.Line.through(.{ 1, 2, 3 }, .{ 1, 2, 8 }).?;
    try testing.expectEqual(Vec3{ 0, 0, 1 }, line.d);
    try expectVec(.{ 1, 2, 8 }, line.eval(5), 0);
    try testing.expectEqual(@as(f64, 5), line.project(.{ 7, 7, 8 }));
    try testing.expectEqual(@as(?curves.Line, null), curves.Line.through(.{ 1, 2, 3 }, .{ 1, 2, 3 }));
    const c = Curve{ .line = line };
    try testing.expect(!c.isPeriodic());
    try testing.expect(std.math.isInf(c.domain().t0));
    try expectDerivatives(c, 2.5);
    const box = c.bounds(-1, 2);
    try expectVec(.{ 1, 2, 2 }, box.min, 0);
    try expectVec(.{ 1, 2, 5 }, box.max, 0);
}

test "Circle: points at radius, derivatives, projection with the angle wrapped, extremes in the box" {
    const circle = curves.Circle.inPlane(.{ 1, 1, 0 }, vec.Z3, 2);
    try expectVec(.{ 3, 1, 0 }, circle.eval(0), 1e-15);
    try expectVec(.{ 1, 3, 0 }, circle.eval(std.math.pi / 2.0), 1e-15);
    try expectVec(vec.Z3, circle.normal(), 1e-15);
    const c = Curve{ .circle = circle };
    try testing.expect(c.isPeriodic());
    try expectDerivatives(c, 0.7);
    try expectDerivatives(c, 4.0);
    // Projection: the angle of the nearest point, in [0, 2π)
    try testing.expectApproxEqAbs(@as(f64, 3.0 * std.math.pi / 2.0), c.project(.{ 1, -10, 5 }, 1e-9, 50), 1e-12);
    try testing.expectEqual(@as(f64, 0), c.project(.{ 1, 1, 7 }, 1e-9, 50)); // on the axis
    // The box of a quarter arc from 0 to π/2 is the quadrant; of the arc 0..π the half disc
    const quarter = c.bounds(0, std.math.pi / 2.0);
    try expectVec(.{ 1, 1, 0 }, quarter.min, 1e-15);
    try expectVec(.{ 3, 3, 0 }, quarter.max, 1e-15);
    const half = c.bounds(0, std.math.pi);
    try expectVec(.{ -1, 1, 0 }, half.min, 1e-15);
    try expectVec(.{ 3, 3, 0 }, half.max, 1e-15);
    const full = c.bounds(0, types.TWO_PI);
    try expectVec(.{ -1, -1, 0 }, full.min, 1e-15);
    try expectVec(.{ 3, 3, 0 }, full.max, 1e-15);
}

test "Circle: a tilted circle's box has the exact extremes" {
    // About the axis (1, 1, 1)/√3 with radius 1: each axis reaches ±√(2/3)
    const n = vec.normalized(.{ 1, 1, 1 }).?;
    const circle = curves.Circle.inPlane(vec.ZERO3, n, 1);
    const box = (Curve{ .circle = circle }).bounds(0, types.TWO_PI);
    const reach = @sqrt(2.0 / 3.0);
    try expectVec(.{ -reach, -reach, -reach }, box.min, 1e-12);
    try expectVec(.{ reach, reach, reach }, box.max, 1e-12);
}

test "Ellipse: points, derivatives, projection by Newton from the affine seed, box" {
    const e = curves.Ellipse{ .c = vec.ZERO3, .x = vec.X3, .y = vec.Y3, .a = 4, .b = 2 };
    const c = Curve{ .ellipse = e };
    try expectVec(.{ 4, 0, 0 }, c.eval(0), 0);
    try expectVec(.{ 0, 2, 0 }, c.eval(std.math.pi / 2.0), 1e-15);
    try expectDerivatives(c, 1.1);
    // The nearest point to (4, 2, 0): not at the seed angle (atan2(1, 1) = π/4) but a little
    // towards x; Newton lands where the tangent is perpendicular to the way to the target
    const t = c.project(.{ 4, 2, 0 }, 1e-12, 50);
    const s = c.sample(t);
    try testing.expectApproxEqAbs(@as(f64, 0), vec.dot(s.d1, vec.sub(s.p, .{ 4, 2, 0 })), 1e-9);
    try testing.expect(t < std.math.pi / 4.0);
    // A point on the ellipse is its own nearest, at the seed exactly
    const on = c.eval(2.3);
    try testing.expectApproxEqAbs(@as(f64, 2.3), c.project(on, 1e-12, 50), 1e-9);
    const box = c.bounds(0, types.TWO_PI);
    try expectVec(.{ -4, -2, 0 }, box.min, 1e-12);
    try expectVec(.{ 4, 2, 0 }, box.max, 1e-12);
}

test "PCurve: lines and circles in UV, and a NURBS pcurve, through the union" {
    const pcurves = @import("pcurves.zig");
    const line = pcurves.PCurve{ .line2 = pcurves.Line2.through(.{ 0, 0 }, .{ 3, 4 }).? };
    try testing.expectApproxEqAbs(@as(f64, 0.6), line.line2.d[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.8), line.line2.d[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 5), line.line2.project(.{ 3, 4 }), 1e-15);
    const at = line.sample(5);
    try testing.expectApproxEqAbs(@as(f64, 3), at.p[0], 1e-15);
    try testing.expectEqual(line.line2.d, at.d1);
    const circle = pcurves.PCurve{ .circle2 = .{ .c = .{ 1, 1 }, .r = 2 } };
    try testing.expect(circle.domain().periodic);
    const s = circle.sample(std.math.pi / 2.0);
    try testing.expectApproxEqAbs(@as(f64, 1), s.p[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3), s.p[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2), s.d1[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.0 * std.math.pi / 2.0), circle.circle2.project(.{ 1, -5 }), 1e-15);
    const quarter = circle.bounds(0, std.math.pi / 2.0);
    try testing.expectApproxEqAbs(@as(f64, 1), quarter.min[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3), quarter.max[1], 1e-15);
    // A quadratic NURBS pcurve: the parabola through (0,0), (1,2), (2,0)
    const knots = [_]f64{ 0, 0, 0, 1, 1, 1 };
    const points = [_]Vec3{ .{ 0, 0, 1 }, .{ 1, 2, 1 }, .{ 2, 0, 1 } };
    const para = pcurves.PCurve{ .nurbs2 = .{ .degree = 2, .knots = &knots, .points = &points } };
    try testing.expect(para.nurbs2.isValid());
    const mid = para.sample(0.5);
    try testing.expectApproxEqAbs(@as(f64, 1), mid.p[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), mid.p[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2), mid.d1[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), mid.d1[1], 1e-12);
    const box = para.bounds(0, 1);
    try testing.expect(box.contains(.{ 1, 1 }) and box.max[1] >= 1);
}

test "Domain: fit wraps a periodic parameter and clamps a bounded one" {
    const periodic = types.Domain{ .t0 = 0, .t1 = types.TWO_PI, .periodic = true };
    try testing.expectApproxEqAbs(@as(f64, 1), periodic.fit(1 + types.TWO_PI * 3), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, types.TWO_PI - 1), periodic.fit(-1), 1e-12);
    try testing.expectEqual(@as(f64, 0), periodic.fit(types.TWO_PI));
    const bounded = types.Domain{ .t0 = -1, .t1 = 1 };
    try testing.expectEqual(@as(f64, 1), bounded.fit(5));
    try testing.expectEqual(@as(f64, -1), bounded.fit(-5));
    try testing.expectEqual(@as(f64, 0.5), bounded.fit(0.5));
}

test "Box3 and Frame: the small shared types" {
    var box = types.Box3.empty;
    try testing.expect(box.isEmpty());
    box.grow(.{ 1, 2, 3 });
    box.grow(.{ -1, 5, 0 });
    try testing.expect(!box.isEmpty());
    try expectVec(.{ -1, 2, 0 }, box.min, 0);
    try expectVec(.{ 1, 5, 3 }, box.max, 0);
    try testing.expectEqual(@as(f64, 3), box.extent());
    try testing.expect(box.contains(.{ 0, 3, 1 }));
    try testing.expect(!box.contains(.{ 0, 3, 4 }));
    try testing.expect(box.overlaps(.{ .min = .{ 1, 5, 3 }, .max = .{ 2, 6, 4 } }));
    try testing.expect(!box.overlaps(.{ .min = .{ 1.1, 5, 3 }, .max = .{ 2, 6, 4 } }));
    const sum = types.Box3.sum(box, .{ .min = .{ 0, 0, 0 }, .max = .{ 0, 0, 10 } });
    try expectVec(.{ 1, 5, 13 }, sum.max, 0);

    const frame = types.Frame.fromAxis(.{ 1, 1, 1 }, vec.Z3);
    try expectVec(vec.X3, frame.x, 0);
    try expectVec(vec.Y3, frame.y, 0);
    const p = frame.toWorld(.{ 1, 2, 3 });
    try expectVec(.{ 2, 3, 4 }, p, 0);
    try expectVec(.{ 1, 2, 3 }, frame.toLocal(p), 0);
    try testing.expectEqual(@as(f64, 0), types.angleOf(0, 0));
    try testing.expectApproxEqAbs(@as(f64, 3.0 * std.math.pi / 2.0), types.angleOf(0, -1), 1e-15);
}
