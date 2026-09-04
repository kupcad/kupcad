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

test "Blends: Full Edge Blend Topology Rewiring" {
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

    // 3. Apply the Edge Blend
    const radius = 2.0;
    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, radius);

    // 4. Validate Shell Faces Count
    const solid = t_arena.solids.items[result.new_solid];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    // Original cube = 6 faces.
    // Slicing 2 adjacent faces yields +2 faces.
    // Deleting the 2 sharp corner strips yields -2 faces.
    // Inserting the filleted NURBS wrapper yields +1 face.
    // Total = 7 closed faces.
    try std.testing.expectEqual(@as(usize, 7), shell.faces_len);

    // 5. Run Strict B-Rep Validation
    const validator = @import("validator.zig");
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // The sanitizer verifies half-edge pairing, pointer integrity, and the Euler characteristic
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result.new_solid, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
        .check_twins = true,
    });
}

test "Blends: Fillet Cap Topology Verification" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const radius = 2.0;
    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, radius);

    // Verify the newly allocated Fillet Face has exactly 4 boundary edges
    const fillet_face = t_arena.faces.items[result.fillet_face];
    const loop = t_arena.loops.items[t_arena.face_loops.items[fillet_face.loops_start]];

    var edge_count: usize = 0;
    var curr = loop.first_half_edge;
    while (true) {
        edge_count += 1;
        curr = t_arena.half_edges.items[curr].next;
        if (curr == loop.first_half_edge) break;
    }

    try std.testing.expectEqual(@as(usize, 4), edge_count);
}

test "Blends: 3-Way Corner Setback Surface Math" {
    const alloc = std.testing.allocator;
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const p_corner = math.Vec3{ 10.0, 10.0, 10.0 };
    const radius = 2.0;

    // Orthogonal cube corner face normals
    const normals = [_]math.Vec3{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    };

    const surf_idx = try blends.createCornerSetbackPatch(alloc, &g_arena, p_corner, radius, normals);
    const surf = g_arena.nurbs_surfaces.items[surf_idx];

    // Verify patch order and CP count
    try std.testing.expectEqual(@as(u32, 2), surf.degree_u);
    try std.testing.expectEqual(@as(u32, 2), surf.degree_v);
    try std.testing.expectEqual(@as(usize, 9), surf.control_points.len);

    // Evaluate surface mid-point (center of the corner sphere patch)
    const mid_pt = surf.evaluate(0.5, 0.5);
    try std.testing.expect(math.mag(mid_pt) > 0.0);
}
