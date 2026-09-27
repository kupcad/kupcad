const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const generators = @import("generators.zig");
const verifier = @import("../topology/verifier.zig");

test "Generator: Cube Strict Topology Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const cube_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    verifier.assertValidTestOnly(alloc, &t_arena, &g_arena, .{}, cube_idx);
}

test "Generator: buildPolyhedron Strict Topology Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    // Simple 4-point tetrahedron
    const pts = [_][3]f64{
        .{ 0, 0, 0 },
        .{ 10, 0, 0 },
        .{ 0, 10, 0 },
        .{ 0, 0, 10 },
    };
    // Proper CCW winding oriented outwards
    const faces = [_][3]u32{
        .{ 0, 2, 1 }, // Bottom
        .{ 0, 1, 3 }, // Front
        .{ 1, 2, 3 }, // Right
        .{ 2, 0, 3 }, // Left
    };

    const poly_idx = try generators.buildPolyhedron(alloc, &t_arena, &g_arena, &pts, &faces);
    verifier.assertValidTestOnly(alloc, &t_arena, &g_arena, .{}, poly_idx);

    try std.testing.expectEqual(@as(usize, 4), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), t_arena.half_edges.items.len); // 4 faces * 3 edges
    try std.testing.expectEqual(@as(usize, 4), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);
}

test "Generator: Cylinder Strict Topology Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const cyl_idx = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5.0, 15.0, true);

    // Verify generation metrics for an analytical B-Rep cylinder
    // Vertices: 2 top + 2 bottom = 4
    // Half-edges: 2 (bot cap) + 2 (top cap) + 4 (front half) + 4 (back half) = 12
    // Faces: 2 planar caps + 2 quadric half-cylinders = 4
    // Solids: 1
    try std.testing.expectEqual(@as(usize, 4), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), t_arena.half_edges.items.len);
    try std.testing.expectEqual(@as(usize, 4), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);

    // Validate Manifold Invariants
    verifier.assertValidTestOnly(alloc, &t_arena, &g_arena, .{}, cyl_idx);
}

test "Generator: Sphere Strict Topology Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const sphere_idx = try generators.generateSphere(alloc, &t_arena, &g_arena, 10.0);

    // Verify generation metrics for an 8-ring x 16-segment UV sphere
    // Vertices: 2 poles + 7 rings * 16 segments = 114
    // Faces: 16 top tris + 6*16 quads + 16 bot tris = 128
    // Half-edges: 16*3 + 96*4 + 16*3 = 480
    try std.testing.expectEqual(@as(usize, 114), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 480), t_arena.half_edges.items.len);
    try std.testing.expectEqual(@as(usize, 128), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);

    // Validate Manifold Invariants
    verifier.assertValidTestOnly(alloc, &t_arena, &g_arena, .{}, sphere_idx);
}

test "Generator: 2D Square (Open Manifold)" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, true);

    try std.testing.expectEqual(@as(usize, 4), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 4), t_arena.half_edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.faces.items.len);

    // Assert graph integrity (disabling require_closed_shells since it's just a 2D sheet)
    try verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .require_closed_shells = false,
        .check_twins = false,
    });
}

test "Generator: 2D Multi-Loop Face (Even-Odd Polygons)" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    // Outer 20x20 boundary, Inner 10x10 hole
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const solid_idx = try generators.generatePolygonsEvenOdd(alloc, &t_arena, &g_arena, &contours);

    try std.testing.expectEqual(@as(usize, 8), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 8), t_arena.half_edges.items.len);
    try std.testing.expectEqual(@as(usize, 2), t_arena.loops.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.faces.items.len);

    const face = t_arena.faces.items[0];
    try std.testing.expectEqual(@as(u32, 2), face.loops_len);

    try verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .require_closed_shells = false,
        .check_twins = false,
    });
}

test "Generator: 2D Polygon (Triangle)" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    // An asymmetrical 3-point polygon (triangle)
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 10 } };
    const solid_idx = try generators.generatePolygon(alloc, &t_arena, &g_arena, &pts);

    // Verify generation metrics
    try std.testing.expectEqual(@as(usize, 3), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 3), t_arena.half_edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.loops.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);

    // Assert open manifold graph integrity
    try verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .require_closed_shells = false,
        .check_twins = false,
    });
}

test "Generator: 2D Circle" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    // Generate a 12-segment faceted circle
    const solid_idx = try generators.generateCircle(alloc, &t_arena, &g_arena, 5.0, 12);

    // Verify generation metrics
    try std.testing.expectEqual(@as(usize, 12), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), t_arena.half_edges.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.loops.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.faces.items.len);
    try std.testing.expectEqual(@as(usize, 1), t_arena.solids.items.len);

    // Assert open manifold graph integrity
    try verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .require_closed_shells = false,
        .check_twins = false,
    });
}
