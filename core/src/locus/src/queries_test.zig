const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const gen = @import("generators.zig");
const query = @import("queries.zig");
const trans = @import("transforms.zig");

test "Queries: Raycasting Against Solid Boundary" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Cast ray starting at Z=20 shooting down to Z=-20 directly through origin
    const hits_opt = try query.rayCast(alloc, &t_arena, &g_arena, cube_id, .{ 0, 0, 20 }, .{ 0, 0, -20 });
    try std.testing.expect(hits_opt != null);
    const hits = hits_opt.?;
    defer alloc.free(hits);

    try std.testing.expect(hits.len >= 2);
    // Ray origin is at Z=20. Top face is at Z=5. Distance to first hit = 15 units.
    try std.testing.expectApproxEqAbs(15.0, hits[0].distance, 1e-4);
    try std.testing.expectApproxEqAbs(1.0, hits[0].normal[2], 1e-4);
}

test "Queries: Minimum Gap Between Disconnected Solids" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube1 = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const cube2 = try gen.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // Shift cube2 by 20 units on X axis (face gap = 20 - 5 - 5 = 10 units)
    _ = try trans.translateSolid(alloc, &t_arena, &g_arena, cube2, 20.0, 0.0, 0.0);

    const gap = query.minGap(alloc, &t_arena, &g_arena, cube1, cube2);
    try std.testing.expectApproxEqAbs(10.0, gap, 1e-4);
}
