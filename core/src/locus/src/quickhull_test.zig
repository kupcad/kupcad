const std = @import("std");
const qh = @import("../src/quickhull.zig");
const math = @import("../src/math.zig");

test "Quickhull: Initial Tetrahedron Construction" {
    const alloc = std.testing.allocator;

    // A simple 3D point cloud of 6 points
    const points = [_]math.Vec3{
        .{ 0, 0, 0 },
        .{ 10, 0, 0 },
        .{ 0, 10, 0 },
        .{ 0, 0, 10 }, // These first 4 form a perfect tetrahedron
        .{ 2, 2, 2 }, // Inside point
        .{ 5, 5, 5 }, // Outside point (will expand hull)
    };

    var builder = qh.QuickhullBuilder.init(alloc, &points);
    defer builder.deinit();

    // Only build the initial tetrahedron so we can test its exact state
    try builder.buildInitialTetrahedron();

    // Verify it created the initial 4 faces
    try std.testing.expectEqual(@as(usize, 4), builder.faces.items.len);

    // Verify it created 12 half-edges (3 per face)
    try std.testing.expectEqual(@as(usize, 12), builder.half_edges.items.len);

    // Verify the first face (bottom, points 0, 1, 2) is facing down (-Z)
    const normal = builder.faces.items[0].plane_normal;

    try std.testing.expectApproxEqAbs(0.0, normal[0], math.MATH_EPSILON);
    try std.testing.expectApproxEqAbs(0.0, normal[1], math.MATH_EPSILON);
    try std.testing.expectApproxEqAbs(-1.0, normal[2], math.MATH_EPSILON);
}

test "Quickhull: Full Hull Generation (Cube with internal points)" {
    const alloc = std.testing.allocator;

    // 8 corners of a 10x10x10 cube, plus 3 internal garbage points
    const points = [_]math.Vec3{
        .{ 0, 0, 0 },  .{ 10, 0, 0 },  .{ 10, 10, 0 },  .{ 0, 10, 0 },
        .{ 0, 0, 10 }, .{ 10, 0, 10 }, .{ 10, 10, 10 }, .{ 0, 10, 10 },
        .{ 5, 5, 5 }, .{ 2, 8, 3 }, .{ 8, 2, 9 }, // Internal points (should be discarded)
    };

    var builder = qh.QuickhullBuilder.init(alloc, &points);
    defer builder.deinit();

    try builder.buildHull();

    // Count the active faces (deleted horizon faces are flagged as disabled)
    var active_faces: usize = 0;
    for (builder.faces.items) |f| {
        if (!f.disabled) active_faces += 1;
    }

    // A convex hull of a cube must triangulate into exactly 12 faces
    try std.testing.expectEqual(@as(usize, 12), active_faces);
}
