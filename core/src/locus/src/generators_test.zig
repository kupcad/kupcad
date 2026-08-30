const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const generators = @import("generators.zig");
const validator = @import("validator.zig");

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

test "Generator: Strict Base Primitive Watertightness" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // If generators fail to produce perfectly closed, non-degenerate shells,
    // the internal validation block will now catch it and return an error here.
    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 5, 5, 5, true);
    const cyl_id = try generators.generateCylinder(alloc, &t_arena, &g_arena, 2.5, 10, true);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, cube_id, tol, .{
        .require_closed_shells = true,
        .check_twins = true,
        .check_degenerates = true,
    });

    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, cyl_id, tol, .{
        .require_closed_shells = true,
        .check_twins = true,
        .check_degenerates = true,
    });
}
