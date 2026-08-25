const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const minkowski = @import("minkowski.zig");
const math = @import("math.zig");

test "Minkowski Sum: Cube + Cube" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Generate two 10x10x10 cubes
    const cube_a = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);
    const cube_b = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);

    // 2. Compute Minkowski Sum
    const minkowski_solid = try minkowski.minkowskiSumConvex(alloc, &t_arena, &g_arena, cube_a, cube_b);

    // 3. Validation
    // The arena now contains 3 solids (Cube A, Cube B, Minkowski Solid)
    try std.testing.expectEqual(@as(usize, 3), t_arena.solids.items.len);

    const final_solid = t_arena.solids.items[minkowski_solid];
    const final_shell = t_arena.shells.items[t_arena.solid_shells.items[final_solid.shells_start]];

    // A convex hull of a cube generates triangulated faces.
    // 6 square faces * 2 triangles = 12 topological faces.
    try std.testing.expectEqual(@as(usize, 12), final_shell.faces_len);
}

test "Minkowski Sum: Cube + Cylinder" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Generate a 10x10x10 Cube
    const cube = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);

    // 2. Generate a Cylinder (Radius 5, Height 20)
    const cyl = try generators.generateCylinder(&t_arena, &g_arena, 5, 20, true);

    // 3. Compute Minkowski Sum
    const sum_solid = try minkowski.minkowskiSumConvex(alloc, &t_arena, &g_arena, cube, cyl);

    // 4. Validation
    // The arena now contains 3 solids (Cube, Cylinder, Minkowski Sum)
    try std.testing.expectEqual(@as(usize, 3), t_arena.solids.items.len);

    const final_solid = t_arena.solids.items[sum_solid];
    const final_shell = t_arena.shells.items[t_arena.solid_shells.items[final_solid.shells_start]];

    // Verify the algorithm successfully mapped the convex hull back into the B-Rep topology graph
    // (We just ensure it generated a non-zero amount of faces without crashing or panicking)
    try std.testing.expect(final_shell.faces_len > 0);
}
