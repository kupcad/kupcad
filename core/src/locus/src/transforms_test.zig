const std = @import("std");
const topo = @import("../src/topology.zig");
const geom = @import("../src/geometry.zig");
const locus_gen = @import("../src/generators.zig");
const locus_trans = @import("../src/transforms.zig");
const math = @import("../src/math.zig");

test "In-Place Translate Solid" {
    var t_arena = topo.TopologyArena.init(std.testing.allocator);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(std.testing.allocator);
    defer g_arena.deinit();

    const solid_id = try locus_gen.generateCube(&t_arena, &g_arena, 10, 10, 10, true);

    // Translate it
    const transformed_id = try locus_trans.translateSolid(std.testing.allocator, &t_arena, &g_arena, solid_id, 10, 0, 0);

    // Assert it modified the solid in place (ID remains the same, arena length remains 1)
    try std.testing.expectEqual(solid_id, transformed_id);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);
}
