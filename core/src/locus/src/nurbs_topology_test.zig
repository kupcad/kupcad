const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

test "Freeform B-Rep Trimmed Face Construction" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Create a 10x10 NURBS patch at Z=5
    const surf_cps = try alloc.dupe(math.Vec4, &[_]math.Vec4{
        .{ 0, 0, 5, 1 },  .{ 10, 0, 5, 1 },
        .{ 0, 10, 5, 1 }, .{ 10, 10, 5, 1 },
    });

    // FIXED: Allocate separate memory slices for U and V knots to prevent double-free
    const knots_u = try alloc.dupe(f64, &[_]f64{ 0, 0, 1, 1 });
    const knots_v = try alloc.dupe(f64, &[_]f64{ 0, 0, 1, 1 });

    try g_arena.nurbs_surfaces.append(alloc, .{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = knots_u,
        .knots_v = knots_v,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = surf_cps,
    });
    const surf_id = geom.SurfaceId{ .index = 0, .surface_type = .nurbs };

    // 2. Add 3D Vertices (A triangle in 3D space: (0,0,5), (5,0,5), (0,5,5))
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 5 } },
        .{ .point = .{ 5, 0, 5 } },
        .{ .point = .{ 0, 5, 5 } },
    });

    // 3. Define the 2D p-curves for the trim (triangle in UV space: (0,0), (0.5,0), (0,0.5))
    const pcurve_idx = @as(u24, @intCast(g_arena.lines_2d.items.len));
    try g_arena.lines_2d.appendSlice(alloc, &[_]geom.Line2D{
        .{ .start = .{ 0, 0 }, .end = .{ 0.5, 0 } },
        .{ .start = .{ 0.5, 0 }, .end = .{ 0, 0.5 } },
        .{ .start = .{ 0, 0.5 }, .end = .{ 0, 0 } },
    });

    // 4. Construct Half-Edges with explicitly assigned start_uvs
    const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = he_start + 1, .prev = he_start + 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .p_curve = .{ .index = pcurve_idx, .curve_type = .line_2d }, .start_uv = .{ 0, 0 }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = he_start + 2, .prev = he_start, .loop_id = 0, .curve = .{ .index = 1, .curve_type = .line }, .p_curve = .{ .index = pcurve_idx + 1, .curve_type = .line_2d }, .start_uv = .{ 0.5, 0 }, .forward = true },
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = he_start, .prev = he_start + 1, .loop_id = 0, .curve = .{ .index = 2, .curve_type = .line }, .p_curve = .{ .index = pcurve_idx + 2, .curve_type = .line_2d }, .start_uv = .{ 0, 0.5 }, .forward = true },
    });

    // 5. Connect Loop and Face
    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = he_start });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = surf_id, .forward = true, .loops_start = 0, .loops_len = 1 });

    // Ensure custom UV coordinates correctly bypass the heavy surface projection solver
    const evaluated_uv = t_arena.getHalfEdgeStartUV(&g_arena, he_start + 1);
    try std.testing.expectEqual(0.5, evaluated_uv[0]);
    try std.testing.expectEqual(0.0, evaluated_uv[1]);
}
