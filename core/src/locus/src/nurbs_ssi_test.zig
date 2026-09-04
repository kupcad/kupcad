const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const nurbs_ssi = @import("nurbs_ssi.zig");

test "NURBS SSI: Marching Intersecting Orthogonal Planes" {
    // Surface A: Flat 10x10 patch on the Z=0 plane
    const a_cps = [_]math.Vec4{
        .{ 0, 0, 0, 1 },  .{ 10, 0, 0, 1 },
        .{ 0, 10, 0, 1 }, .{ 10, 10, 0, 1 },
    };
    const knots = [_]f64{ 0, 0, 1, 1 };
    const surf_a = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &a_cps,
    };

    // Surface B: Flat 10x10 patch on the Y=5 plane, rising in Z
    const b_cps = [_]math.Vec4{
        .{ 0, 5, -5, 1 }, .{ 10, 5, -5, 1 },
        .{ 0, 5, 5, 1 },  .{ 10, 5, 5, 1 },
    };
    const surf_b = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &b_cps,
    };

    // The intersection is a straight line at Y=5, Z=0.
    // Start seed at X=2.0 (u_A=0.2, v_A=0.5 | u_B=0.2, v_B=0.5)
    var current_uv = [4]f64{ 0.2, 0.5, 0.2, 0.5 };

    // March 3 steps of 1.0 unit each along the intersection curve
    for (0..3) |_| {
        current_uv = try nurbs_ssi.stepIntersection(&surf_a, &surf_b, current_uv, 1.0);
        const pt = surf_a.evaluate(current_uv[0], current_uv[1]);

        // Validate 3D positional exactness
        try std.testing.expectApproxEqAbs(5.0, pt[1], 1e-5); // Stays on Y=5
        try std.testing.expectApproxEqAbs(0.0, pt[2], 1e-5); // Stays on Z=0
    }

    // After starting at X=2 and taking 3 steps of 1.0, X must be exactly 5.0
    const final_pt = surf_a.evaluate(current_uv[0], current_uv[1]);
    try std.testing.expectApproxEqAbs(5.0, final_pt[0], 1e-5);
}
