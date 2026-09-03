const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const gen = @import("generators.zig");
const prop = @import("properties.zig");

test "Properties: Volume, Surface Area, Bounding Box, and Genus" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Centered 10x10x10 cube
    const cube_id = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Bounding Box Validation
    const bbox_opt = prop.boundingBox(&t_arena, cube_id);
    try std.testing.expect(bbox_opt != null);
    const bbox = bbox_opt.?;
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[0], 1e-5);
    try std.testing.expectApproxEqAbs(5.0, bbox.max[0], 1e-5);

    // Physical Volume & Area Validation
    const vol = prop.volume(alloc, &t_arena, &g_arena, cube_id);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-4);

    const sa = prop.surfaceArea(alloc, &t_arena, &g_arena, cube_id);
    try std.testing.expectApproxEqAbs(600.0, sa, 1e-4);

    // Topology Invariant: Genus of a solid cube must be 0
    const g = prop.genus(alloc, &t_arena, cube_id);
    try std.testing.expectEqual(@as(i32, 0), g);
}

test "Properties: 2D Cross Section Area and Bounding Box" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 20.0, true);

    const area = prop.crossSectionArea(&t_arena, sq_id);
    try std.testing.expectApproxEqAbs(200.0, area, 1e-4);

    const bounds = prop.crossSectionBounds(&t_arena, sq_id);
    try std.testing.expectApproxEqAbs(-5.0, bounds.min[0], 1e-4);
    try std.testing.expectApproxEqAbs(5.0, bounds.max[0], 1e-4);
    try std.testing.expectApproxEqAbs(-10.0, bounds.min[1], 1e-4);
    try std.testing.expectApproxEqAbs(10.0, bounds.max[1], 1e-4);
}

test "Properties: High-Poly Parallel Volume (Sphere)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Generate a high-resolution sphere to stress the parallelFor loop
    // (e.g., using the cylinder generator with high segment count as the sphere fallback)
    const sphere_id = try gen.generateSphere(alloc, &t_arena, &g_arena, 10.0);

    // Calculate volume concurrently
    const vol = prop.volume(alloc, &t_arena, &g_arena, sphere_id);
    try std.testing.expect(vol > 3000.0); // 4/3 * pi * r^3 ≈ 4188.7
}
