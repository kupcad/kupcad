const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const sweeps = @import("sweeps.zig");

test "Sweep: Extrude Cube Face" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, false);

    const base_face_id: u32 = 0;
    const swept_solid_id = try sweeps.extrudeFace(alloc, &t_arena, &g_arena, base_face_id, .{ 0, 0, 20 });

    try std.testing.expectEqual(@as(usize, 2), t_arena.solids.items.len);

    const swept_solid = t_arena.solids.items[swept_solid_id];
    const swept_shell = t_arena.shells.items[t_arena.solid_shells.items[swept_solid.shells_start]];

    try std.testing.expectEqual(@as(usize, 6), swept_shell.faces_len);
}
