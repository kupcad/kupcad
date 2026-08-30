const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const generators = @import("generators.zig");
const minkowski = @import("minkowski.zig");
const validator = @import("validator.zig");

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

test "Minkowski Sum: Geometric Coincidence Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube = try generators.generateCube(alloc, &t_arena, &g_arena, 4.0, 12.0, 6.0, true);
    const sph = try generators.generateSphere(alloc, &t_arena, &g_arena, 2.0);

    const bumper = try minkowski.minkowskiSumConvex(alloc, &t_arena, &g_arena, cube, sph);

    // The validator will now run strict coincidence checks natively.
    // This should no longer throw VertexNotOnSurface!
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, bumper, tol, .{
        .check_coincidence = true,
        .check_degenerates = true,
        .require_closed_shells = true,
    });
}
