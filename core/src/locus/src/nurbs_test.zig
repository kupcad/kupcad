const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");

test "NURBS: Exact Circle Evaluation (Rational Curve)" {
    // A perfect quarter-circle in the XY plane requires degree 2 and a specific weight
    const w = @sqrt(2.0) / 2.0;

    // Homogeneous control points: [x*w, y*w, z*w, w]
    const cps = [_]math.Vec4{
        .{ 1.0, 0.0, 0.0, 1.0 }, // P0: (1,0,0), w=1
        .{ 1.0 * w, 1.0 * w, 0.0, w }, // P1: (1,1,0), w=0.707
        .{ 0.0, 1.0, 0.0, 1.0 }, // P2: (0,1,0), w=1
    };
    const knots = [_]f64{ 0, 0, 0, 1, 1, 1 };

    const arc = geom.NurbsCurve{
        .degree = 2,
        .knots = &knots,
        .control_points = &cps,
    };

    // Evaluate exactly at the midpoint (u = 0.5)
    const pt = arc.evaluate(0.5);

    // The midpoint of a unit circle quadrant should be at (sqrt(2)/2, sqrt(2)/2, 0)
    try std.testing.expectApproxEqAbs(w, pt[0], 1e-6);
    try std.testing.expectApproxEqAbs(w, pt[1], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, pt[2], 1e-6);

    // The radius distance from origin must be exactly 1.0
    const dist = @sqrt(pt[0] * pt[0] + pt[1] * pt[1] + pt[2] * pt[2]);
    try std.testing.expectApproxEqAbs(1.0, dist, 1e-6);
}

test "NURBS: Bilinear Surface Evaluation" {
    // 2x2 grid (degree 1x1) flat patch in the XY plane at Z=5
    const cps = [_]math.Vec4{
        .{ 0, 0, 5, 1 },  .{ 10, 0, 5, 1 },
        .{ 0, 10, 5, 1 }, .{ 10, 10, 5, 1 },
    };
    const knots = [_]f64{ 0, 0, 1, 1 };

    const patch = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &cps,
    };

    // Center point (0.5, 0.5) should map linearly to (5, 5, 5)
    const pt = patch.evaluate(0.5, 0.5);
    try std.testing.expectApproxEqAbs(5.0, pt[0], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, pt[1], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, pt[2], 1e-6);
}
