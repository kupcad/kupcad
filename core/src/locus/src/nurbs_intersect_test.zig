const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const nurbs_intersect = @import("nurbs_intersect.zig");

test "NURBS Intersect: Orthogonal Line through Bilinear Patch" {
    // 1. Define a flat 10x10 patch on the Z=5 plane
    const surf_cps = [_]math.Vec4{
        .{ 0, 0, 5, 1 },  .{ 10, 0, 5, 1 },
        .{ 0, 10, 5, 1 }, .{ 10, 10, 5, 1 },
    };
    const surf_knots = [_]f64{ 0, 0, 1, 1 };
    const patch = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &surf_knots,
        .knots_v = &surf_knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &surf_cps,
    };

    // 2. Define a vertical line from (5,5,0) to (5,5,10) moving along the Z axis
    const curve_cps = [_]math.Vec4{ .{ 5, 5, 0, 1 }, .{ 5, 5, 10, 1 } };
    const curve_knots = [_]f64{ 0, 0, 1, 1 };
    const line = geom.NurbsCurve{
        .degree = 1,
        .knots = &curve_knots,
        .control_points = &curve_cps,
    };

    // Seed the solver slightly off the true intersection to force optimization
    const result = try nurbs_intersect.intersectCurveSurface(&line, &patch, 0.1, 0.8, 0.2);

    // The line passes through Z=5 at exactly t=0.5
    // The patch's (5,5) coordinate corresponds to u=0.5, v=0.5
    try std.testing.expectApproxEqAbs(0.5, result[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.5, result[1], 1e-5);
    try std.testing.expectApproxEqAbs(0.5, result[2], 1e-5);
}
