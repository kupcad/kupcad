const std = @import("std");
const topo = @import("../src/topology.zig");
const geom = @import("../src/geometry.zig");
const generators = @import("../src/generators.zig");
const sweeps = @import("../src/sweeps.zig");

test "Sweep: Extrude Cube Face" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Generate a Base Cube
    _ = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, false);

    // 2. Select Face 0 (The bottom face of the cube)
    const base_face_id: u32 = 0;

    // 3. Extrude the face by 20 units on the Z axis
    const swept_solid_id = try sweeps.extrudeFace(&t_arena, &g_arena, base_face_id, .{ 0, 0, 20 });

    // 4. Validation
    // Arena should now have 2 Solids
    try std.testing.expectEqual(@as(usize, 2), t_arena.solids.items.len);

    const swept_solid = t_arena.solids.items[swept_solid_id];
    const swept_shell = t_arena.shells.items[t_arena.solid_shells.items[swept_solid.shells_start]];

    // The swept solid (extruding a 4-sided face) should have exactly 6 faces
    // (1 bottom + 1 top + 4 sides).
    try std.testing.expectEqual(@as(usize, 6), swept_shell.faces_len);
}
