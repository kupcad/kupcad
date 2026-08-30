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

    // 1. Manually construct a structurally corrupt shell (single open face)
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });
    try t_arena.vertices.append(alloc, .{ .point = .{ 1, 0, 0 } });
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 1, 0 } });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    // Create 3 half-edges missing their twins
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

    // 2. Expect the OpenBoundary constraint to trigger
    const err = validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, 0, tol, .{});
    try std.testing.expectError(error.OpenBoundaryInClosedShell, err);

    // 3. Disable twin checks and expect Euler characteristic (V-E+F = 3 - 3 + 1 = 1 != 2) to trigger
    const euler_err = validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, 0, tol, .{
        .check_twins = false,
        .mute_errors = true,
    });
    try std.testing.expectError(error.EulerCharacteristicMismatch, euler_err);
}
