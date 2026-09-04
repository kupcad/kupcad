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

test "NURBS SSI: Full Boundary-to-Boundary Seam Tracing" {
    const alloc = std.testing.allocator;

    const a_cps = [_]math.Vec4{
        .{ 0, 0, 0, 1 },  .{ 10, 0, 0, 1 },
        .{ 0, 10, 0, 1 }, .{ 10, 10, 0, 1 },
    };
    const b_cps = [_]math.Vec4{
        .{ 0, 5, -5, 1 }, .{ 10, 5, -5, 1 },
        .{ 0, 5, 5, 1 },  .{ 10, 5, 5, 1 },
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
    const surf_b = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &b_cps,
    };

    // Seed near the middle: X=4 (uA=0.4, uB=0.4), intersection is at Y=5 (vA=0.5, vB=0.5)
    const seed = [4]f64{ 0.4, 0.5, 0.4, 0.5 };

    // Trace with a large step size to quickly reach the boundaries
    const seam = try nurbs_ssi.traceIntersectionCurve(alloc, &surf_a, &surf_b, seed, 2.0);
    defer alloc.free(seam.points_3d);
    defer alloc.free(seam.uvs_a);
    defer alloc.free(seam.uvs_b);

    // Ensure it correctly traced to both edges of the 10x10 patches
    try std.testing.expect(seam.points_3d.len > 4);

    // The first point should be at X=0 boundary, last point at X=10 boundary
    try std.testing.expectApproxEqAbs(0.0, seam.points_3d[0][0], 1e-1);
    try std.testing.expectApproxEqAbs(10.0, seam.points_3d[seam.points_3d.len - 1][0], 1e-1);
}
