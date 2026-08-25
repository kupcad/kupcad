const std = @import("std");
const topo = @import("../src/topology.zig");
const geom = @import("../src/geometry.zig");
const generators = @import("../src/generators.zig");

test "Generator: Cube, Cylinder, Sphere" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();

    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Generate Cube
    const cube_id = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);
    try std.testing.expectEqual(@as(u32, 0), cube_id);

    // Validate Cube topological counts
    try std.testing.expectEqual(@as(usize, 8), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), t_arena.edges.items.len);
    try std.testing.expectEqual(@as(usize, 6), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);

    // Validate Cube geometric counts
    try std.testing.expectEqual(@as(usize, 12), g_arena.lines.items.len);
    try std.testing.expectEqual(@as(usize, 6), g_arena.planes.items.len);

    // 2. Generate Cylinder
    const cyl_id = try generators.generateCylinder(&t_arena, &g_arena, 5, 15, true);
    try std.testing.expectEqual(@as(u32, 1), cyl_id);

    // Validate accumulated Cylinder topological counts (+4 verts, +6 edges, +4 faces, +1 solid)
    try std.testing.expectEqual(@as(usize, 12), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 18), t_arena.edges.items.len);
    try std.testing.expectEqual(@as(usize, 10), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 2), t_arena.solids.items.len);

    // Validate accumulated Cylinder geometric counts
    try std.testing.expectEqual(@as(usize, 4), g_arena.circle_arcs.items.len);
    try std.testing.expectEqual(@as(usize, 1), g_arena.cylinders.items.len);

    // 3. Generate Sphere
    const sphere_id = try generators.generateSphere(&t_arena, &g_arena, 5);
    try std.testing.expectEqual(@as(u32, 2), sphere_id);

    // Validate accumulated Sphere topological counts (+2 verts, +2 edges, +2 faces, +1 solid)
    try std.testing.expectEqual(@as(usize, 14), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 20), t_arena.edges.items.len);
    try std.testing.expectEqual(@as(usize, 12), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 3), t_arena.solids.items.len);

    // Validate accumulated Sphere geometric counts
    try std.testing.expectEqual(@as(usize, 6), g_arena.circle_arcs.items.len); // 4 from cyl, 2 from sphere
    try std.testing.expectEqual(@as(usize, 1), g_arena.spheres.items.len);
}
