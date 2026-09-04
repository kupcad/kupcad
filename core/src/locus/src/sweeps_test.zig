const std = @import("std");
const math = @import("math.zig");
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

test "Sweep Math: RMF Generation Orthogonality" {
    const alloc = std.testing.allocator;
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create a circular arc rail in the XZ plane
    try g_arena.circle_arcs.append(alloc, .{
        .center = .{ 0, 0, 0 },
        .radius = 10.0,
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 0, 1 }, // Note: Sweep is X to Z
    });
    const rail = geom.CurveId{ .index = 0, .curve_type = .circle_arc };

    const samples = 16;
    const frames = try sweeps.generateRMF(alloc, &g_arena, rail, samples);
    defer alloc.free(frames);

    try std.testing.expectEqual(samples, frames.len);

    // Verify orthogonality and normalization of every transported frame
    for (frames) |f| {
        try std.testing.expectApproxEqAbs(0.0, math.dot(f.tangent, f.normal), 1e-7);
        try std.testing.expectApproxEqAbs(0.0, math.dot(f.normal, f.binormal), 1e-7);
        try std.testing.expectApproxEqAbs(0.0, math.dot(f.tangent, f.binormal), 1e-7);

        try std.testing.expectApproxEqAbs(1.0, math.mag(f.tangent), 1e-7);
        try std.testing.expectApproxEqAbs(1.0, math.mag(f.normal), 1e-7);
        try std.testing.expectApproxEqAbs(1.0, math.mag(f.binormal), 1e-7);
    }
}

test "Sweep Math: NURBS Profile Sweeping" {
    const alloc = std.testing.allocator;
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // 1. Rail: Line from (0,0,0) to (0,0,20)
    try g_arena.lines.append(alloc, .{ .start = .{ 0, 0, 0 }, .end = .{ 0, 0, 20 } });
    const rail = geom.CurveId{ .index = 0, .curve_type = .line };

    // 2. Profile: A 2D straight line from X=-5 to X=5 in the local frame
    var profile_knots = [_]f64{ 0.0, 0.0, 1.0, 1.0 };
    var profile_cps = [_]math.Vec4{
        .{ -5.0, 0.0, 0.0, 1.0 },
        .{ 5.0, 0.0, 0.0, 1.0 },
    };
    const profile = geom.NurbsCurve{
        .degree = 1,
        .knots = &profile_knots,
        .control_points = &profile_cps,
    };

    // 3. Sweep
    const samples = 4;
    const surf_idx = try sweeps.sweepProfileAlongCurve(alloc, &g_arena, profile, rail, samples);
    const surf = g_arena.nurbs_surfaces.items[surf_idx];

    // Profile CP count * Rail Sample count
    try std.testing.expectEqual(@as(usize, 8), surf.control_points.len);
    try std.testing.expectEqual(@as(u32, 2), surf.num_cp_u);
    try std.testing.expectEqual(@as(u32, 4), surf.num_cp_v);

    // 4. Evaluate generated surface bounding points
    const start_mid = surf.evaluate(0.5, 0.0);
    try std.testing.expectApproxEqAbs(0.0, start_mid[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, start_mid[1], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, start_mid[2], 1e-5);

    const end_mid = surf.evaluate(0.5, 1.0);
    try std.testing.expectApproxEqAbs(0.0, end_mid[0], 1e-5);
    try std.testing.expectApproxEqAbs(0.0, end_mid[1], 1e-5);
    try std.testing.expectApproxEqAbs(20.0, end_mid[2], 1e-5); // Swept exactly 20 units along Z
}
