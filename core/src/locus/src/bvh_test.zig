const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const bvh = @import("bvh.zig");

test "BVH: Automatic Seed Generation for Curve/Surface Intersection" {
    const alloc = std.testing.allocator;

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

    // Shift line to X=6.25, Y=6.25 and Z from 0 to 8.
    // This makes it pierce Z=5 exactly at t = 5/8 = 0.625.
    const curve_cps = [_]math.Vec4{ .{ 6.25, 6.25, 0, 1 }, .{ 6.25, 6.25, 8, 1 } };
    const curve_knots = [_]f64{ 0, 0, 1, 1 };
    const line = geom.NurbsCurve{
        .degree = 1,
        .knots = &curve_knots,
        .control_points = &curve_cps,
    };

    // Subdivide curve into 4 segments and surface into a 4x4 grid
    const seeds = try bvh.generateCurveSurfaceSeeds(alloc, &line, &patch, 4, 4);
    defer alloc.free(seeds);

    // Because 0.625 is exactly in the center of the 3rd span (0.5 to 0.75),
    // it will overlap exactly 1 AABB combination.
    try std.testing.expectEqual(@as(usize, 1), seeds.len);
    try std.testing.expectApproxEqAbs(0.625, seeds[0].t, 1e-1);
    try std.testing.expectApproxEqAbs(0.625, seeds[0].u, 1e-1);
    try std.testing.expectApproxEqAbs(0.625, seeds[0].v, 1e-1);
}
