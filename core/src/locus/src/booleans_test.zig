const std = @import("std");
const topo = @import("topology.zig");
const generators = @import("generators.zig");
const geom = @import("geometry.zig");
const booleans = @import("booleans.zig");
const math = @import("math.zig");

test "March Intersection (Perpendicular Cylinders)" {
    // Cylinder A: Along Z axis
    const cyl_a = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
        .radius = 5.0,
    };

    // Cylinder B: Along Y axis
    const cyl_b = geom.Cylinder{
        .origin = .{ 0, 0, 0 },
        .axis = .{ 0, 1, 0 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 0, 1 },
        .radius = 5.0,
    };

    var g_arena = geom.GeometryArena.init(std.testing.allocator);
    defer g_arena.deinit();

    // Push directly to the densely packed cylinders array
    try g_arena.cylinders.append(std.testing.allocator, cyl_a);
    try g_arena.cylinders.append(std.testing.allocator, cyl_b);

    const start_pt = math.Vec3{ 5.0, 0.0, 0.0 };

    // Construct the 32-bit packed IDs
    const id_a = geom.SurfaceId{ .index = 0, .surface_type = .cylinder };
    const id_b = geom.SurfaceId{ .index = 1, .surface_type = .cylinder };

    const curve_id = try booleans.marchIntersection(std.testing.allocator, &g_arena, id_a, id_b, start_pt, 0.5, 10, 1e-5);

    // Using .index to verify it returned the first generated curve
    try std.testing.expectEqual(@as(u32, 0), curve_id.index);
}

test "CSG Pipeline: High-Level Operations (Stubbed)" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // 1. Generate two 10x10x10 cubes
    const cube_a = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);
    const cube_b = try generators.generateCube(&t_arena, &g_arena, 10, 10, 10, true);

    const mock_config = .{};

    // --- TEST 1: UNION ---
    // With `classifyFace` defaulting to `.outside`, Union keeps all faces of A and B.
    const union_solid_id = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a, cube_b, .union_op, mock_config);
    const union_solid = t_arena.solids.items[union_solid_id];
    const union_shell = t_arena.shells.items[t_arena.solid_shells.items[union_solid.shells_start]];

    // Expect 6 (Cube A) + 6 (Cube B) = 12 faces
    try std.testing.expectEqual(@as(usize, 12), union_shell.faces_len);

    // --- TEST 2: DIFFERENCE ---
    // Difference keeps A (outside) and discards B (since it needs inside).
    const diff_solid_id = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a, cube_b, .difference, mock_config);
    const diff_solid = t_arena.solids.items[diff_solid_id];
    const diff_shell = t_arena.shells.items[t_arena.solid_shells.items[diff_solid.shells_start]];

    // Expect 6 faces (Just Cube A)
    try std.testing.expectEqual(@as(usize, 6), diff_shell.faces_len);

    // --- TEST 3: INTERSECTION ---
    // Intersection requires faces to be `.inside`. Both A and B are discarded.
    const int_solid_id = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a, cube_b, .intersection, mock_config);
    const int_solid = t_arena.solids.items[int_solid_id];
    const int_shell = t_arena.shells.items[t_arena.solid_shells.items[int_solid.shells_start]];

    // Expect 0 faces (Empty Solid)
    try std.testing.expectEqual(@as(usize, 0), int_shell.faces_len);
}

test "CSG: Topological Edge Splitting" {
    const alloc = std.testing.allocator;

    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit();
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit();

    // Setup an isolated Edge spanning X=0 to X=10
    const v0 = @as(u32, @intCast(t_arena.vertices.items.len));
    try t_arena.vertices.append(alloc, .{ .point = .{ 0, 0, 0 } });

    const v1 = @as(u32, @intCast(t_arena.vertices.items.len));
    try t_arena.vertices.append(alloc, .{ .point = .{ 10, 0, 0 } });

    const l_idx = @as(u24, @intCast(g_arena.lines.items.len));
    try g_arena.lines.append(alloc, .{ .start = .{ 0, 0, 0 }, .end = .{ 10, 0, 0 } });

    const edge_id = @as(u32, @intCast(t_arena.edges.items.len));
    try t_arena.edges.append(alloc, .{
        .front = v0,
        .back = v1,
        .curve = .{ .index = l_idx, .curve_type = .line },
    });

    // Simulate an intersection at X=5
    const split_pt = math.Vec3{ 5, 0, 0 };

    // This is the private function, we declare it public temporarily or use @call if needed,
    // but since they are in the same module in a real build, it works.
    const result = try booleans.splitEdgeTopologically(alloc, &t_arena, &g_arena, edge_id, split_pt);

    // Validation
    try std.testing.expectEqual(@as(usize, 3), t_arena.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 3), t_arena.edges.items.len); // Original + 2 New

    const new_e1 = t_arena.edges.items[result.e1];
    const new_e2 = t_arena.edges.items[result.e2];

    try std.testing.expectEqual(v0, new_e1.front);
    try std.testing.expectEqual(result.v_mid, new_e1.back);

    try std.testing.expectEqual(result.v_mid, new_e2.front);
    try std.testing.expectEqual(v1, new_e2.back);
}
