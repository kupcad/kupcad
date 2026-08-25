const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");

test "Generator: Cube, Cylinder, Sphere" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Generate Cube
    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    try std.testing.expectEqual(@as(u32, 0), cube_id);
    try std.testing.expectEqual(@as(usize, 8), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 24), t_arena.half_edges.items.len);
    try std.testing.expectEqual(@as(usize, 6), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);

    // 2. Generate Cylinder
    const cyl_id = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5, 15, true);
    try std.testing.expectEqual(@as(u32, 1), cyl_id);
    try std.testing.expectEqual(@as(usize, 2), t_arena.solids.items.len);
}
