const std = @import("std");
const geom = @import("geometry.zig");
const math = @import("math.zig");

test "Geometry Plane Projection & Normals" {
    const alloc = std.testing.allocator;
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const plane = geom.Plane{
        .origin = .{ 0, 0, 0 },
        .u_axis = .{ 1, 0, 0 },
        .v_axis = .{ 0, 1, 0 },
    };
    try g_arena.planes.append(alloc, plane);

    const surf_id = geom.SurfaceId{ .index = 0, .surface_type = .plane };
    const pt = math.Vec3{ 3.0, 4.0, 5.0 };

    const uv = g_arena.surfaceProject(surf_id, pt);
    try std.testing.expectApproxEqAbs(3.0, uv[0], math.MATH_EPSILON);
    try std.testing.expectApproxEqAbs(4.0, uv[1], math.MATH_EPSILON);

    const norm = g_arena.surfaceNormal(surf_id, uv[0], uv[1]);
    try std.testing.expectApproxEqAbs(0.0, norm[0], math.MATH_EPSILON);
    try std.testing.expectApproxEqAbs(0.0, norm[1], math.MATH_EPSILON);
    try std.testing.expectApproxEqAbs(1.0, norm[2], math.MATH_EPSILON);
}
