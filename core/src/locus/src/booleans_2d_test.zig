const std = @import("std");
const testing = std.testing;
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const transforms = @import("transforms.zig");
const booleans_2d = @import("booleans_2d.zig");
const sweeps = @import("sweeps.zig");
const tessellate = @import("tessellate.zig");

test "Booleans 2D: Union and Extrude 2D Profiles" {
    const alloc = testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq1 = try generators.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const sq2 = try generators.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);

    // Shift sq2 by [5, 5] using the proper transform function
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, sq2, 5.0, 5.0, 0.0);

    const union_2d = try booleans_2d.crossSectionBoolean(alloc, &t_arena, &g_arena, sq1, sq2, .union_op);
    const solid_id = try sweeps.extrudeFace(alloc, &t_arena, &g_arena, union_2d, .{ 0, 0, 10 });

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, solid_id, &mesh, .{});

    var vol: f64 = 0.0;
    for (mesh.triangles.items) |t| {
        const p0 = mesh.vertices.items[t[0]];
        const p1 = mesh.vertices.items[t[1]];
        const p2 = mesh.vertices.items[t[2]];
        const cross_x = p1[1] * p2[2] - p1[2] * p2[1];
        const cross_y = p1[2] * p2[0] - p1[0] * p2[2];
        const cross_z = p1[0] * p2[1] - p1[1] * p2[0];
        vol += (p0[0] * cross_x + p0[1] * cross_y + p0[2] * cross_z) / 6.0;
    }
    try testing.expectApproxEqAbs(1750.0, @abs(vol), 1e-4);
}
