const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const nurbs_ssi = @import("nurbs_ssi.zig");
const tessellate = @import("tessellate.zig");
const classify = @import("csg/classify.zig");

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

    // Allocate separate memory slices for U and V knots to prevent double-free
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

test "NURBS Solid Tessellation Pipeline" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const surf_cps = try alloc.dupe(math.Vec4, &[_]math.Vec4{
        .{ 0, 0, 5, 1 },  .{ 10, 0, 5, 1 },
        .{ 0, 10, 5, 1 }, .{ 10, 10, 5, 1 },
    });
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

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 5 } },
        .{ .point = .{ 10, 0, 5 } },
        .{ .point = .{ 10, 10, 5 } },
        .{ .point = .{ 0, 10, 5 } },
    });

    const pcurve_idx = @as(u24, @intCast(g_arena.lines_2d.items.len));
    try g_arena.lines_2d.appendSlice(alloc, &[_]geom.Line2D{
        .{ .start = .{ 0, 0 }, .end = .{ 1, 0 } },
        .{ .start = .{ 1, 0 }, .end = .{ 1, 1 } },
        .{ .start = .{ 1, 1 }, .end = .{ 0, 1 } },
        .{ .start = .{ 0, 1 }, .end = .{ 0, 0 } },
    });

    const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = he_start + 1, .prev = he_start + 3, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .p_curve = .{ .index = pcurve_idx, .curve_type = .line_2d }, .start_uv = .{ 0, 0 }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = he_start + 2, .prev = he_start, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .p_curve = .{ .index = pcurve_idx + 1, .curve_type = .line_2d }, .start_uv = .{ 1, 0 }, .forward = true },
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = he_start + 3, .prev = he_start + 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .p_curve = .{ .index = pcurve_idx + 2, .curve_type = .line_2d }, .start_uv = .{ 1, 1 }, .forward = true },
        .{ .start_vertex = 3, .twin = topo.NULL_ID, .next = he_start, .prev = he_start + 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .p_curve = .{ .index = pcurve_idx + 3, .curve_type = .line_2d }, .start_uv = .{ 0, 1 }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = he_start });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .nurbs }, .forward = true, .loops_start = 0, .loops_len = 1 });

    // Wire into solid wrapper to emulate realistic CSG output
    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, 0, &mesh, .{});

    // Validates that the NURBS-specific UV path successfully populated the mesh object
    try std.testing.expectEqual(@as(usize, 2), mesh.triangles.items.len);
    try std.testing.expect(mesh.vertices.items.len > 4); // Original 4 topological pts + dynamically generated projection pts
}

test "Single-Seed Saddle Marching Termination" {
    const alloc = std.testing.allocator;

    const a_cps = [_]math.Vec4{
        .{ 0, 0, 5, 1 },   .{ 5, 0, 2.5, 1 },  .{ 10, 0, 5, 1 },
        .{ 0, 5, 7.5, 1 }, .{ 5, 5, 5, 1 },    .{ 10, 5, 7.5, 1 },
        .{ 0, 10, 5, 1 },  .{ 5, 10, 2.5, 1 }, .{ 10, 10, 5, 1 },
    };
    const knots = [_]f64{ 0, 0, 0, 1, 1, 1 };
    const saddle = geom.NurbsSurface{
        .degree_u = 2,
        .degree_v = 2,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 3,
        .num_cp_v = 3,
        .control_points = &a_cps,
    };

    const b_cps = [_]math.Vec4{
        .{ -2, -2, 5, 1 }, .{ 12, -2, 5, 1 },
        .{ -2, 12, 5, 1 }, .{ 12, 12, 5, 1 },
    };
    const plane_knots = [_]f64{ 0, 0, 1, 1 };
    const cutting_plane = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &plane_knots,
        .knots_v = &plane_knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &b_cps,
    };

    // Seed at UV (0.5, 0.5) on saddle surface
    const seed = [4]f64{ 0.5, 0.5, 0.5, 0.5 };
    const seam = try nurbs_ssi.traceIntersectionCurve(alloc, &saddle, &cutting_plane, seed, 0.5);
    defer alloc.free(seam.points_3d);
    defer alloc.free(seam.uvs_a);
    defer alloc.free(seam.uvs_b);

    try std.testing.expect(seam.points_3d.len > 0);
}

test "Saddle Surface SSI Marching" {
    const alloc = std.testing.allocator;

    // Surface A: Hyperbolic Paraboloid (Saddle Patch) Z = (X-5)^2/10 - (Y-5)^2/10 + 5
    const a_cps = [_]math.Vec4{
        .{ 0, 0, 5, 1 },   .{ 5, 0, 2.5, 1 },  .{ 10, 0, 5, 1 },
        .{ 0, 5, 7.5, 1 }, .{ 5, 5, 5, 1 },    .{ 10, 5, 7.5, 1 },
        .{ 0, 10, 5, 1 },  .{ 5, 10, 2.5, 1 }, .{ 10, 10, 5, 1 },
    };
    const knots = [_]f64{ 0, 0, 0, 1, 1, 1 };
    const saddle = geom.NurbsSurface{
        .degree_u = 2,
        .degree_v = 2,
        .knots_u = &knots,
        .knots_v = &knots,
        .num_cp_u = 3,
        .num_cp_v = 3,
        .control_points = &a_cps,
    };

    // Surface B: Flat cutting plane at Z = 5
    const b_cps = [_]math.Vec4{
        .{ -2, -2, 5, 1 }, .{ 12, -2, 5, 1 },
        .{ -2, 12, 5, 1 }, .{ 12, 12, 5, 1 },
    };
    const plane_knots = [_]f64{ 0, 0, 1, 1 };
    const cutting_plane = geom.NurbsSurface{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = &plane_knots,
        .knots_v = &plane_knots,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = &b_cps,
    };

    const seams = try nurbs_ssi.findAllIntersectionSeams(alloc, &saddle, &cutting_plane, 0.5);
    defer {
        for (seams) |s| {
            alloc.free(s.points_3d);
            alloc.free(s.uvs_a);
            alloc.free(s.uvs_b);
        }
        alloc.free(seams);
    }

    // A saddle intersecting a plane at Z=5 produces intersecting hyperbolic branches
    try std.testing.expect(seams.len >= 1);
    for (seams[0].points_3d) |pt| {
        try std.testing.expectApproxEqAbs(5.0, pt[2], 1e-3);
    }
}

test "Trimmed NURBS Surface with Inner Hole Tessellation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 10x10 bilinear patch at Z=0
    const surf_cps = try alloc.dupe(math.Vec4, &[_]math.Vec4{
        .{ 0, 0, 0, 1 },  .{ 10, 0, 0, 1 },
        .{ 0, 10, 0, 1 }, .{ 10, 10, 0, 1 },
    });
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

    // Outer Loop: UV (0,0) -> (1,0) -> (1,1) -> (0,1)
    // Inner Hole: UV (0.25, 0.25) -> (0.25, 0.75) -> (0.75, 0.75) -> (0.75, 0.25)
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },     .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },   .{ .point = .{ 0, 10, 0 } },
        .{ .point = .{ 2.5, 2.5, 0 } }, .{ .point = .{ 2.5, 7.5, 0 } },
        .{ .point = .{ 7.5, 7.5, 0 } }, .{ .point = .{ 7.5, 2.5, 0 } },
    });

    const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));

    // Outer Loop Half-Edges (CW/CCW orientation)
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = he_start + 1, .prev = he_start + 3, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0, 0 }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = he_start + 2, .prev = he_start, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 1, 0 }, .forward = true },
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = he_start + 3, .prev = he_start + 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 1, 1 }, .forward = true },
        .{ .start_vertex = 3, .twin = topo.NULL_ID, .next = he_start, .prev = he_start + 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0, 1 }, .forward = true },
    });

    // Inner Hole Half-Edges (Reversed winding: 4 -> 5 -> 6 -> 7 -> 4)
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 4, .twin = topo.NULL_ID, .next = he_start + 5, .prev = he_start + 7, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0.25, 0.25 }, .forward = true },
        .{ .start_vertex = 7, .twin = topo.NULL_ID, .next = he_start + 6, .prev = he_start + 4, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0.75, 0.25 }, .forward = true },
        .{ .start_vertex = 6, .twin = topo.NULL_ID, .next = he_start + 7, .prev = he_start + 5, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0.75, 0.75 }, .forward = true },
        .{ .start_vertex = 5, .twin = topo.NULL_ID, .next = he_start + 4, .prev = he_start + 6, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0.25, 0.75 }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = he_start });
    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = he_start + 4 });
    try t_arena.face_loops.appendSlice(alloc, &[_]u32{ 0, 1 });
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .nurbs }, .forward = true, .loops_start = 0, .loops_len = 2 });

    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    var mesh = tessellate.Mesh{};
    defer mesh.deinit(alloc);
    try tessellate.tessellateSolid(alloc, &t_arena, &g_arena, 0, &mesh, .{});

    // Mesh area must equal Outer Square (100) - Hole Square (25) = 75
    var total_area: f64 = 0.0;
    for (mesh.triangles.items) |tri| {
        const p0 = mesh.vertices.items[tri[0]];
        const p1 = mesh.vertices.items[tri[1]];
        const p2 = mesh.vertices.items[tri[2]];
        const v1 = math.sub(p1, p0);
        const v2 = math.sub(p2, p0);
        total_area += 0.5 * math.mag(math.cross(v1, v2));
    }

    try std.testing.expectApproxEqAbs(75.0, total_area, 1e-3);
}

test "NURBS Face Classification" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const surf_cps = try alloc.dupe(math.Vec4, &[_]math.Vec4{
        .{ 0, 0, 5, 1 },  .{ 10, 0, 5, 1 },
        .{ 0, 10, 5, 1 }, .{ 10, 10, 5, 1 },
    });
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

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 5 } },
        .{ .point = .{ 10, 0, 5 } },
        .{ .point = .{ 10, 10, 5 } },
        .{ .point = .{ 0, 10, 5 } },
    });

    const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = he_start + 1, .prev = he_start + 3, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0, 0 }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = he_start + 2, .prev = he_start, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 1, 0 }, .forward = true },
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = he_start + 3, .prev = he_start + 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 1, 1 }, .forward = true },
        .{ .start_vertex = 3, .twin = topo.NULL_ID, .next = he_start, .prev = he_start + 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .start_uv = .{ 0, 1 }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = he_start });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .nurbs }, .forward = true, .loops_start = 0, .loops_len = 1 });

    const proj = classify.projectPointToSurface(&g_arena, .{ .index = 0, .surface_type = .nurbs }, .{ 5, 5, 0 });
    try std.testing.expectApproxEqAbs(5.0, proj[0], 1e-3);
    try std.testing.expectApproxEqAbs(5.0, proj[1], 1e-3);
    try std.testing.expectApproxEqAbs(5.0, proj[2], 1e-3);
}
