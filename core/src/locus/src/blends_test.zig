const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const generators = @import("generators.zig");
const blends = @import("csg/blends.zig");

test "Blends: Constant Radius Fillet Surface Generation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Generate a Base Cube
    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // 2. Select an Edge (e.g., a top bounding edge of the cube)
    // Finding a valid edge with a twin that connects two perpendicular faces
    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    // 3. Generate the 3D Fillet Surface
    const radius = 2.0;
    const surf_id = try blends.createConstantFilletSurface(alloc, &t_arena, &g_arena, target_he, radius);

    // 4. Validate the resulting swept NURBS surface
    const surf = g_arena.nurbs_surfaces.items[surf_id];

    // Degree U (Profile) must be quadratic (2) for an exact circular arc
    try std.testing.expectEqual(@as(u32, 2), surf.degree_u);
    // Profile requires exactly 3 control points
    try std.testing.expectEqual(@as(u32, 3), surf.num_cp_u);

    // Check midpoint evaluation (the deepest point of the fillet)
    const mid_pt = surf.evaluate(0.5, 0.5);
    try std.testing.expect(math.mag(mid_pt) > 0.0);
}

test "Blends: Apply Edge Blend Topological Trimming" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Generate a Base Cube
    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    // 2. Select an Edge with a valid twin
    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    // 3. Apply the Edge Blend (Phase 6.2 Trimming)
    const radius = 2.0;
    const initial_face_count = t_arena.faces.items.len;

    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, radius);

    // 4. Validate the topological additions
    // Slicing two adjacent faces adds 2 new faces, plus the 1 new fillet face wrapper.
    try std.testing.expect(t_arena.faces.items.len >= initial_face_count + 3);

    // Verify the newly allocated fillet face correctly maps to the NURBS geometry
    const fillet_face = t_arena.faces.items[result.fillet_face];
    try std.testing.expectEqual(.nurbs, fillet_face.surface.surface_type);

    const surf = g_arena.nurbs_surfaces.items[fillet_face.surface.index];
    try std.testing.expectEqual(@as(u32, 2), surf.degree_u);
}
