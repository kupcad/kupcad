const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const validator = @import("validator.zig");

test "Validator: Catch Dangling Twin and Euler Violations" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });
    try t_arena.vertices.append(alloc, .{ .point = .{ 1, 0, 0 } });
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 1, 0 } });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    try t_arena.half_edges.append(alloc, .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true });
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 2, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true });
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 0, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .parametric = 1e-5, .squared = 1e-10 };

    const err = validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, 0, tol, .{});
    try std.testing.expectError(error.OpenBoundaryInClosedShell, err);

    const euler_err = validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, 0, tol, .{
        .check_twins = false,
        .mute_errors = true,
    });
    try std.testing.expectError(error.EulerCharacteristicMismatch, euler_err);
}

test "Validator: Catch AntiParallelTwin" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });
    try t_arena.vertices.append(alloc, .{ .point = .{ 1, 0, 0 } });
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 1, 0 } });

    // Face 0: 0 -> 1 -> 2
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 0, .twin = 3, .next = 1, .prev = 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }); // HE0
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 2, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }); // HE1
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 0, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }); // HE2

    // Face 1 (Anti-parallel): 0 -> 1 -> 2
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 0, .twin = 0, .next = 4, .prev = 5, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }); // HE3
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 5, .prev = 3, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }); // HE4
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 3, .prev = 4, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }); // HE5

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.loops.append(alloc, .{ .face_id = 1, .first_half_edge = 3 });

    try t_arena.face_loops.append(alloc, 0);
    try t_arena.face_loops.append(alloc, 1);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 1, .loops_len = 1 });

    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shell_faces.append(alloc, 1);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .parametric = 1e-5, .squared = 1e-10 };

    const err = validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, 0, tol, .{
        .check_linked_lists = false,
        .check_coincidence = false,
        .check_degenerates = false,
        .check_winding = false,
        .require_closed_shells = false,
        .check_euler = false,
    });
    try std.testing.expectError(error.AntiParallelTwin, err);
}

test "Validator: Catch InvalidWindingOrder" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 0, 1, 0 } },
        .{ .point = .{ 1, 1, 0 } },
        .{ .point = .{ 1, 0, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    try t_arena.half_edges.append(alloc, .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 3, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true });
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 2, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true });
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 3, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true });
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 3, .twin = topo.NULL_ID, .next = 0, .prev = 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .parametric = 1e-5, .squared = 1e-10 };

    const err = validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, 0, tol, .{
        .check_twins = false,
        .require_closed_shells = false,
        .check_euler = false,
        .check_coincidence = false,
        .check_winding = true,
    });
    try std.testing.expectError(error.InvalidWindingOrder, err);
}

test "Validator: Catch UvDrift" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });
    try t_arena.vertices.append(alloc, .{ .point = .{ 1, 0, 0 } });

    const knots = [_]f64{ 0, 0, 1, 1 };
    const cps = [_]math.Vec4{
        .{ 10, 10, 10, 1 }, .{ 10, 10, 10, 1 },
        .{ 10, 10, 10, 1 }, .{ 10, 10, 10, 1 },
    };
    const cps_dupe = try alloc.dupe(math.Vec4, &cps);
    const knots_u = try alloc.dupe(f64, &knots);
    const knots_v = try alloc.dupe(f64, &knots);

    try g_arena.nurbs_surfaces.append(alloc, .{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = knots_u,
        .knots_v = knots_v,
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = cps_dupe,
    });

    try t_arena.half_edges.append(alloc, .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true, .start_uv = .{ 0.5, 0.5 } });
    try t_arena.half_edges.append(alloc, .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 0, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true, .start_uv = .{ 0.5, 0.5 } });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .nurbs }, .forward = true, .loops_start = 0, .loops_len = 1 });

    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .parametric = 1e-5, .squared = 1e-10 };

    const err = validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, 0, tol, .{
        .check_twins = false,
        .check_linked_lists = false,
        .check_winding = false,
        .check_degenerates = false,
        .require_closed_shells = false,
        .check_euler = false,
        .check_coincidence = false, // MUST be false to bypass VertexNotOnSurface and cleanly trigger UvDrift
        .check_uv_sync = true,
    });
    try std.testing.expectError(error.UvDrift, err);
}
