const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const locus_gen = @import("generators.zig");
const locus_trans = @import("transforms.zig");

test "In-Place Translate Solid" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const solid_id = try locus_gen.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    const transformed_id = try locus_trans.translateSolid(alloc, &t_arena, &g_arena, solid_id, 10, 0, 0);

    try std.testing.expectEqual(solid_id, transformed_id);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);
}
