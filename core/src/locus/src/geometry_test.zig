const std = @import("std");
const geom = @import("../src/geometry.zig");
const math = @import("../src/math.zig");

test "NURBS Curve Evaluation (Cox-de Boor)" {
    const knots = [_]f64{ 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 };
    const control_points = [_]math.Vec4{
        .{ 0.0, 0.0, 0.0, 1.0 },
        .{ 1.0, 1.0, 0.0, 1.0 }, // Midpoint pulled to (1,1)
        .{ 2.0, 0.0, 0.0, 1.0 },
    };

    const curve = geom.NurbsCurve{
        .degree = 2,
        .knots = &knots,
        .control_points = &control_points,
    };

    const pt_start = geom.evaluateNurbsCurve(curve, 0.0);
    const pt_mid = geom.evaluateNurbsCurve(curve, 0.5);
    const pt_end = geom.evaluateNurbsCurve(curve, 1.0);

    const TEST_TOLERANCE = 1.0e-6;

    try std.testing.expectApproxEqAbs(0.0, pt_start[0], TEST_TOLERANCE);
    try std.testing.expectApproxEqAbs(1.0, pt_mid[0], TEST_TOLERANCE);
    try std.testing.expectApproxEqAbs(0.5, pt_mid[1], TEST_TOLERANCE); // Parabola peak
    try std.testing.expectApproxEqAbs(2.0, pt_end[0], TEST_TOLERANCE);
}
