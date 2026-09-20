const std = @import("std");
const math = @import("../math.zig");
const topo_arena = @import("arena.zig");
const topo_types = @import("types.zig");
const geom_arena = @import("../geometry/arena.zig");
const verifier = @import("verifier.zig").Verifier;
const generators = @import("../operations/generators.zig");

test "Verifier: Validates perfectly watertight 2-manifold B-Rep" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    try verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
}

test "Verifier: Detects Dangling Twins (Out-of-bounds index)" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Corrupt graph: set twin to an out-of-bounds index
    t_arena.half_edges.items[0].twin = @enumFromInt(999999);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.DanglingTwin, err);
}

test "Verifier: Detects Open Boundary In Closed Shell (NULL twin)" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Corrupt graph: sever a twin link to NULL_HALF_EDGE
    t_arena.half_edges.items[0].twin = topo_types.NULL_HALF_EDGE;

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.OpenBoundaryInClosedShell, err);
}

test "Verifier: Detects Broken Linked Lists (Next/Prev sync)" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Corrupt graph: point `.next` to an invalid half-edge
    t_arena.half_edges.items[0].next = @enumFromInt(12);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.BrokenLinkedList, err);
}

test "Verifier: Detects Asymmetric Twin Links" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Corrupt twin reciprocity: HE 0 points to HE 1 as twin, but HE 1 points to HE 5
    const twin_of_0 = t_arena.half_edges.items[0].twin;
    t_arena.half_edges.items[@intFromEnum(twin_of_0)].twin = @enumFromInt(5);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.AsymmetricTwin, err);
}

test "Verifier: Detects Anti-Parallel Twin Orientation Violations" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Swap twin's start vertex so it is no longer opposite to the original edge direction
    const twin_idx = @intFromEnum(t_arena.half_edges.items[0].twin);
    t_arena.half_edges.items[twin_idx].start_vertex = @enumFromInt(0);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.AntiParallelTwin, err);
}

test "Verifier: Detects Loop-Face Discrepancies" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Mismatch loop's parent face_id reference
    t_arena.loops.items[0].face_id = @enumFromInt(99);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.LoopFaceMismatch, err);
}

test "Verifier: Detects NaN / Inf Memory Corruption" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Inject NaN into a vertex coordinate
    const pt_idx = @intFromEnum(t_arena.vertices.items[0].point);
    g_arena.points.items[pt_idx][0] = std.math.nan(f64);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.NaNOrInfCoordinate, err);
}

test "Verifier: Detects Degenerate Zero-Length Edges" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Collapse vertex 1 onto vertex 0 so the edge between them becomes zero length
    const pt0 = g_arena.points.items[@intFromEnum(t_arena.vertices.items[0].point)];
    const pt1_idx = @intFromEnum(t_arena.vertices.items[1].point);
    g_arena.points.items[pt1_idx] = pt0;

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .check_degenerates = true,
    });
    try std.testing.expectError(error.DegenerateEdge, err);
}

test "Verifier: Detects Vertex Displaced From Surface (Coincidence Check)" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Pull a vertex 50mm off its planar surface
    const pt_idx = @intFromEnum(t_arena.vertices.items[0].point);
    g_arena.points.items[pt_idx][2] += 50.0;

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .check_coincidence = true,
    });
    try std.testing.expectError(error.VertexNotOnSurface, err);
}

test "Verifier: Detects Infinite / Unclosed Half-Edge Cycles" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // First half edge is 0. Create a 1 <-> 2 cycle that never returns to 0.
    t_arena.half_edges.items[0].next = @enumFromInt(1);
    t_arena.half_edges.items[1].next = @enumFromInt(2);
    t_arena.half_edges.items[2].next = @enumFromInt(1);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .check_linked_lists = false, // Disable link sync
        .check_twins = false, // Disable twin check
        .check_euler = false, // Disable Euler check to isolate loop iteration limit
    });
    try std.testing.expectError(error.UnclosedLoop, err);
}

test "Verifier: Detects Euler-Poincare Characteristic Violations" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Artificially duplicate a face entry in shell_faces without adding vertices or edges
    const shell = &t_arena.shells.items[0];
    const dup_face_idx = t_arena.shell_faces.items[shell.faces_start];
    try t_arena.shell_faces.append(alloc, dup_face_idx);
    shell.faces_len += 1;

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .check_twins = false,
        .check_linked_lists = false,
        .check_coincidence = false,
        .check_euler = true,
        .mute_errors = true,
    });
    try std.testing.expectError(error.EulerCharacteristicMismatch, err);
}

test "Verifier: Detects Reverse Prev Link Inconsistency" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Corrupt `.prev` link on half-edge 1
    t_arena.half_edges.items[1].prev = @enumFromInt(99);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.BrokenLinkedList, err);
}

test "Verifier: Detects HalfEdge Loop Index Mismatch" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Corrupt half-edge 0's parent loop_id pointer
    t_arena.half_edges.items[0].loop_id = @enumFromInt(99);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.LoopFaceMismatch, err);
}

test "Verifier: Validates Cylinder Primitive Manifold Shell" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5, 20, true);

    try verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
}

test "Verifier: Solid Isolation Across Multi-Solid Arena" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const cube1_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const cube2_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 20, 20, 20, true);

    // Corrupt cube 2 by severing twin link bidirectionally to leave a true open boundary
    const last_he = t_arena.half_edges.items.len - 1;
    const twin_he = @intFromEnum(t_arena.half_edges.items[last_he].twin);
    t_arena.half_edges.items[last_he].twin = topo_types.NULL_HALF_EDGE;
    if (twin_he < t_arena.half_edges.items.len) {
        t_arena.half_edges.items[twin_he].twin = topo_types.NULL_HALF_EDGE;
    }

    // Cube 1 must still validate cleanly despite corruption in Cube 2
    try verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, cube1_idx, .{});

    // Cube 2 must fail validation with OpenBoundaryInClosedShell
    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, cube2_idx, .{});
    try std.testing.expectError(error.OpenBoundaryInClosedShell, err);
}

test "Verifier: Detects Invalid Winding Order on Inverted Outer Loop" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Invert normal flag without updating loop winding, creating an orientation mismatch
    t_arena.faces.items[0].forward = !t_arena.faces.items[0].forward;

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .check_winding = true,
        .check_coincidence = false, // Disable coincidence check to isolate winding calculation
    });
    try std.testing.expectError(error.InvalidWindingOrder, err);
}

test "Verifier: Detects Infinity in Vertex Coordinates" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Inject Infinity into point 0
    const pt_idx = @intFromEnum(t_arena.vertices.items[0].point);
    g_arena.points.items[pt_idx][1] = std.math.inf(f64);

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{});
    try std.testing.expectError(error.NaNOrInfCoordinate, err);
}

test "Verifier: Detects NURBS UV Drift Synchronization Error" {
    const alloc = std.testing.allocator;
    var t_arena = topo_arena.TopologyArena.init();
    defer t_arena.deinit(alloc);
    var g_arena = geom_arena.GeometryArena.init();
    defer g_arena.deinit(alloc);

    const solid_idx = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);

    // Change face 0's surface to a dummy NURBS surface
    const nurbs_idx: u24 = @intCast(g_arena.nurbs_surfaces.items.len);
    const knots = [_]f64{ 0, 0, 1, 1 };
    const cps = [_]math.Vec4{
        .{ 0, 0, 0, 1 },  .{ 10, 0, 0, 1 },
        .{ 0, 10, 0, 1 }, .{ 10, 10, 0, 1 },
    };
    try g_arena.nurbs_surfaces.append(alloc, .{
        .degree_u = 1,
        .degree_v = 1,
        .knots_u = try alloc.dupe(f64, &knots),
        .knots_v = try alloc.dupe(f64, &knots),
        .num_cp_u = 2,
        .num_cp_v = 2,
        .control_points = try alloc.dupe(math.Vec4, &cps),
    });

    t_arena.faces.items[0].surface = .{
        .index = @enumFromInt(nurbs_idx),
        .surface_type = .nurbs,
    };

    // Attach an inaccurate start_uv to half-edge 0 that maps far away from point 0
    t_arena.half_edges.items[0].start_uv = .{ 99.0, 99.0 };

    const err = verifier.validateSolid(alloc, &t_arena, &g_arena, .{}, solid_idx, .{
        .check_coincidence = false,
        .check_uv_sync = true,
    });
    try std.testing.expectError(error.UvDrift, err);
}
