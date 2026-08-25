const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const minkowski = @import("minkowski.zig");

test "Minkowski Sum: Cube + Cube" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_a = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const cube_b = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    const minkowski_solid = try minkowski.minkowskiSumConvex(alloc, &t_arena, &g_arena, cube_a, cube_b);

    try std.testing.expectEqual(@as(usize, 3), t_arena.solids.items.len);

    const final_solid = t_arena.solids.items[minkowski_solid];
    const final_shell = t_arena.shells.items[t_arena.solid_shells.items[final_solid.shells_start]];

    try std.testing.expectEqual(@as(usize, 12), final_shell.faces_len);
}

test "Minkowski Sum: Cube + Cylinder" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const cyl = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5, 20, true);

    const sum_solid = try minkowski.minkowskiSumConvex(alloc, &t_arena, &g_arena, cube, cyl);

    try std.testing.expectEqual(@as(usize, 3), t_arena.solids.items.len);

    const final_solid = t_arena.solids.items[sum_solid];
    const final_shell = t_arena.shells.items[t_arena.solid_shells.items[final_solid.shells_start]];

    try std.testing.expect(final_shell.faces_len > 0);
}
