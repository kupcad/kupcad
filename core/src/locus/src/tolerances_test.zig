const std = @import("std");
const topo = @import("topology.zig");
const math = @import("math.zig");

test "Local Entity Tolerancing & Coincidence" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);

    // 1. Create a strict mathematical vertex
    try t_arena.vertices.append(alloc, .{ .point = .{ 0.0, 0.0, 0.0 }, .tolerance = 1e-7 });

    // 2. Create a "fuzzy" vertex resulting from a messy intersection
    try t_arena.vertices.append(alloc, .{ .point = .{ 1e-4, 1e-4, 0.0 }, .tolerance = 1.5e-4 });

    const v1 = t_arena.vertices.items[0];
    const v2 = t_arena.vertices.items[1];

    // 3. Verify they coincide locally despite being outside strict global bounds
    const is_coincident = math.entitiesCoincide(v1.point, v1.tolerance, v2.point, v2.tolerance);
    try std.testing.expect(is_coincident);

    // 4. Test fuzzy point-on-edge evaluation
    const edge_start = math.Vec3{ -1.0, 0.0, 0.0 };
    const edge_end = math.Vec3{ 1.0, 0.0, 0.0 };
    const edge_tol = 1e-5;

    // Test point slightly off the edge, but within its own fuzzy tolerance
    const pt_off_edge = math.Vec3{ 0.0, 1e-4, 0.0 };
    const pt_tol = 1e-4;

    const on_edge = math.pointOnEdgeFuzzy(pt_off_edge, pt_tol, edge_start, edge_end, edge_tol);
    try std.testing.expect(on_edge);
}

test "2D Parametric Coincidence" {
    const p1 = math.Vec2{ 0.5, 0.5 };
    const p2 = math.Vec2{ 0.50001, 0.50001 };

    // Should fail with strict tolerances
    try std.testing.expect(!math.pointsCoincide2D(p1, 1e-6, p2, 1e-6));

    // Should pass with inflated local tolerances
    try std.testing.expect(math.pointsCoincide2D(p1, 1e-4, p2, 1e-4));
}

test "Dynamic Tolerance Inflation (Grazing Angles)" {
    const base_tol = 1e-5;

    // Case 1: Perpendicular intersection (90 degrees). sin(90) = 1.0
    const sin_theta_90 = 1.0;
    const tol_90 = @max(base_tol, base_tol / @max(sin_theta_90, 1e-6));
    try std.testing.expectApproxEqAbs(@as(f64, 1e-5), tol_90, 1e-9); // Tolerance remains strict

    // Case 2: Grazing intersection (~0.57 degrees). sin(1 deg) ≈ 0.01
    const sin_theta_1 = 0.01;
    const tol_1 = @max(base_tol, base_tol / @max(sin_theta_1, 1e-6));
    try std.testing.expectApproxEqAbs(@as(f64, 1e-3), tol_1, 1e-9); // Tolerance artificially inflates by 100x to absorb drift
}
