const std = @import("std");
const topo = @import("../src/topology.zig");
const geom = @import("../src/geometry.zig");
const generators = @import("../src/generators.zig");
const transforms = @import("../src/transforms.zig");
const math = @import("../src/math.zig");

test "Deep Clone & Translate Solid" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();

    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Generate a Base Cube
    const base_cube = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, false);

    // Store the X coordinate of the very first vertex (should be 0.0)
    const base_vertex_id = t_arena.edges.items[0].front;
    const base_x = t_arena.vertices.items[base_vertex_id].point[0];
    try std.testing.expectEqual(@as(f64, 0.0), base_x);

    // 2. Clone and Translate by X = +50.0
    const cloned_cube = try transforms.translateSolid(alloc, &t_arena, &g_arena, base_cube, 50.0, 0.0, 0.0);

    // 3. Validation
    // The topology arena should now contain exactly TWO solids.
    try std.testing.expectEqual(@as(usize, 2), t_arena.solids.items.len);
    try std.testing.expectEqual(@as(u32, 1), cloned_cube);

    // Since a cube has 8 vertices, the cloned cube's vertices should start at index 8.
    // The translated vertex should be shifted precisely by +50.0.
    const cloned_vertex_id = t_arena.edges.items[12].front; // Edges of clone start at index 12
    const cloned_x = t_arena.vertices.items[cloned_vertex_id].point[0];

    try std.testing.expectEqual(@as(f64, 50.0), cloned_x);
}
