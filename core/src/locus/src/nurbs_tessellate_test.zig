const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const nurbs_tessellate = @import("nurbs_tessellate.zig");

test "NURBS Tessellation: 2D UV to 3D Projection" {
    const alloc = std.testing.allocator;

    // Define a 10x10 bilinear patch at Z=5
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

    // A simple 2D UV square split into two triangles (covering U:0-1, V:0-1)
    const uv_tris = [_]nurbs_tessellate.UvTriangle{
        .{ .uv1 = .{ 0, 0 }, .uv2 = .{ 1, 0 }, .uv3 = .{ 1, 1 } },
        .{ .uv1 = .{ 0, 0 }, .uv2 = .{ 1, 1 }, .uv3 = .{ 0, 1 } },
    };

    var mesh = try nurbs_tessellate.projectUvMeshTo3D(alloc, &patch, &uv_tris);
    defer mesh.deinit(alloc);

    // Two triangles forming a square should deduplicate into exactly 4 unique vertices and 2 faces
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 2), mesh.indices.items.len);

    // Verify the 3D projection of UV (1, 1) mapped correctly to (10, 10, 5)
    var found_max_corner = false;
    for (mesh.vertices.items) |v| {
        if (@abs(v[0] - 10.0) < 1e-5 and @abs(v[1] - 10.0) < 1e-5 and @abs(v[2] - 5.0) < 1e-5) {
            found_max_corner = true;
        }
    }
    try std.testing.expect(found_max_corner);
}
