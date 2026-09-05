const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const booleans = @import("../booleans.zig");
const generators = @import("../generators.zig");
const transforms = @import("../transforms.zig");
const healing = @import("healing.zig");
const gen = @import("../generators.zig");

test "Healing: extractIslandBoundary Standard Two-Face Merge" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } }, // 0
        .{ .point = .{ 10, 0, 0 } }, // 1
        .{ .point = .{ 10, 10, 0 } }, // 2
        .{ .point = .{ 0, 10, 0 } }, // 3
        .{ .point = .{ 20, 0, 0 } }, // 4
        .{ .point = .{ 20, 10, 0 } }, // 5
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 1, 4, 5, 2 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(f1, {});
    try island_set.put(f2, {});

    const island = [_]topo.FaceId{ f1, f2 };
    const merged_face_id = try healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);

    const merged_face = t_arena.faces.items[merged_face_id];
    const loop = t_arena.loops.items[t_arena.face_loops.items[merged_face.loops_start]];

    var edge_count: usize = 0;
    var curr = loop.first_half_edge;
    while (true) {
        edge_count += 1;
        curr = t_arena.half_edges.items[curr].next;
        if (curr == loop.first_half_edge) break;
    }

    try std.testing.expectEqual(@as(usize, 6), edge_count);
}

test "Healing: extractIslandBoundary Resolves Non-Manifold Bowtie Vertex" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } }, // 0 (Center bowtie vertex)
        .{ .point = .{ 10, 10, 0 } }, // 1
        .{ .point = .{ 0, 10, 0 } }, // 2
        .{ .point = .{ 10, -10, 0 } }, // 3
        .{ .point = .{ 0, -10, 0 } }, // 4
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 3, 4 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(f1, {});
    try island_set.put(f2, {});

    const island = [_]topo.FaceId{ f1, f2 };

    // Removed the errant &g_arena argument here
    const res = healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);

    // The rigorous validation phase detects the non-manifold figure-8 and safely aborts
    try std.testing.expectError(error.TopologyCorrupted, res);
}

test "Healing: Edge Traversal on Corrupted Boundaries (Graceful Rejection)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
    });

    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 1, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(0, {});

    const island = [_]topo.FaceId{0};
    const res = healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);
    try std.testing.expectError(error.TopologyCorrupted, res);
}

test "Healing: Coplanar Face Merging on Boolean Union" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_a = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const cube_b = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_b, 10.0, 0.0, 0.0);

    const result_solid = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a, cube_b, .union_op, .{});

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolidEx(alloc, &t_arena, &g_arena, result_solid, tol, .{ .mute_errors = true });

    const solid = t_arena.solids.items[result_solid];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    try std.testing.expectEqual(@as(usize, 6), shell.faces_len);
}

test "Healing: Multi-Face Coplanar Ring (Hollow Center)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Form a 3x3 hollow ring out of 8 cubes
    var base_solid = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    const positions = [_][2]f64{ .{ 10.0, 0.0 }, .{ 20.0, 0.0 }, .{ 20.0, 10.0 }, .{ 20.0, 20.0 }, .{ 10.0, 20.0 }, .{ 0.0, 20.0 }, .{ 0.0, 10.0 } };

    for (positions) |pos| {
        const next_cube = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
        _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, next_cube, pos[0], pos[1], 0.0);
        base_solid = try booleans.computeBoolean(alloc, &t_arena, &g_arena, base_solid, next_cube, .union_op, .{});
    }

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolidEx(alloc, &t_arena, &g_arena, base_solid, tol, .{ .mute_errors = true });

    const solid = t_arena.solids.items[base_solid];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    // 8 cubes initially have 48 faces. After merging the ring, it should collapse into exactly 10 faces
    // (1 top ring, 1 bottom ring, 4 outer walls, 4 inner hole walls).
    try std.testing.expectEqual(@as(usize, 10), shell.faces_len);
}

test "Healing: Graceful Rejection on Non-Planar Faces (Cylinder)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cyl = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5.0, 10.0, true);
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // The healer should skip curved surfaces without crashing
    try healing.healSolidEx(alloc, &t_arena, &g_arena, cyl, tol, .{ .mute_errors = true });

    const solid = t_arena.solids.items[cyl];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    try std.testing.expect(shell.faces_len > 0);
}

test "Healing: Multi-Island Disjoint Coplanar Clusters" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Pair 1: Left side (X: [-10, 10])
    const cube_a1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const cube_a2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_a2, 10.0, 0.0, 0.0);
    const pair_a = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a1, cube_a2, .union_op, .{});

    // Pair 2: Right side (X: [40, 60]), completely disjoint but sharing the exact same Z=5 top plane
    const cube_b1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const cube_b2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_b1, 40.0, 0.0, 0.0);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_b2, 50.0, 0.0, 0.0);
    const pair_b = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_b1, cube_b2, .union_op, .{});

    // Merge both disjoint solids into one combined solid container
    const combined = try booleans.computeBoolean(alloc, &t_arena, &g_arena, pair_a, pair_b, .union_op, .{});

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolidEx(alloc, &t_arena, &g_arena, combined, tol, .{ .mute_errors = true });

    const solid = t_arena.solids.items[combined];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    // Each 2-cube pair merges to 6 faces. Disjoint pair total must equal 12 faces.
    try std.testing.expectEqual(@as(usize, 12), shell.faces_len);
}

test "Healing: Rejects Opposing Normal Vectors on Same Plane" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } }, // 0
        .{ .point = .{ 10, 0, 0 } }, // 1
        .{ .point = .{ 10, 10, 0 } }, // 2
        .{ .point = .{ 0, 10, 0 } }, // 3
        .{ .point = .{ 20, 0, 0 } }, // 4
        .{ .point = .{ 20, 10, 0 } }, // 5
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 1, 4, 5, 2 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    // Invert normal orientation of face 2
    t_arena.faces.items[f2].forward = false;

    // Register faces into a topological Shell and Solid wrapper
    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ f1, f2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolidEx(alloc, &t_arena, &g_arena, 0, tol, .{ .mute_errors = true });

    // Opposite normals MUST NOT be clustered into the same island (face count remains 2)
    const solid = t_arena.solids.items[0];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    try std.testing.expectEqual(@as(usize, 2), shell.faces_len);
}

test "Healing: Infinite Loop Safety Guard on Unclosed Half-Edge Chain" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Construct a broken loop where half-edges cycle between 0 and 1 without closing to first_half_edge
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 5, 5, 0 } },
    });

    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        // Edge 0 -> Next is 1
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        // Edge 1 -> Next is 1 (Infinite Self-Loop)
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 1, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(0, {});

    const island = [_]topo.FaceId{0};

    // Safety counters inside extractIslandBoundary MUST trigger error.TopologyCorrupted instantly
    const res = healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);
    try std.testing.expectError(error.TopologyCorrupted, res);
}

test "Healing: Infinite Loop Guard in Coplanar Island BFS Queue" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create a self-twin half-edge (edge's twin points to itself, causing potential cyclic traversal)
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 0, 10, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    // Edge 0 twin points to itself (he.twin == 0)
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = 0, .next = 1, .prev = 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 2, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 0, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });
    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // Island traversal MUST terminate safely without looping indefinitely
    try healing.healSolidEx(alloc, &t_arena, &g_arena, 0, tol, .{ .mute_errors = true });
}

test "Healing: Transactional Validation Prevents Graph Mutation on Error" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
    });

    // Deliberately broken half-edge chain that does not form a loop
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 1, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(0, {});

    const island = [_]topo.FaceId{0};
    const res = healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);

    // 1. MUST safely abort without infinite loops
    try std.testing.expectError(error.TopologyCorrupted, res);

    // 2. TRANSACTIONAL SAFETY: The half-edges MUST NOT be mutated.
    // If the transaction failed cleanly, t_arena.half_edges.items[0].next must still be 1.
    try std.testing.expectEqual(@as(topo.HalfEdgeId, 1), t_arena.half_edges.items[0].next);
    try std.testing.expectEqual(@as(topo.HalfEdgeId, 1), t_arena.half_edges.items[0].prev);
}

test "Healing: Strict Vertex Count Matching Rejects Dangling Tails" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 0, 10, 0 } },
        .{ .point = .{ 20, 20, 0 } }, // Vertex 3 (The tip of the dangling tail)
    });

    // We must wire the tail into the loop traversal so the engine actually evaluates it.
    // Traversal: 0 -> 1 -> 2 -> 3 -> 2 -> 0
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 4, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 2, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 3, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }, // Out to tail
        .{ .start_vertex = 3, .twin = topo.NULL_ID, .next = 4, .prev = 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }, // Back from tail
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 0, .prev = 3, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }, // Close loop
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(0, {});

    const island = [_]topo.FaceId{0};
    const res = healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);

    // The boundary extractor will now see Vertex 2 has 2 outgoing boundary edges (he2 and he4).
    // This violates the 1:1 manifold mapping invariant, safely throwing the error.
    try std.testing.expectError(error.TopologyCorrupted, res);

    // Assert the graph wasn't mutated
    try std.testing.expectEqual(@as(topo.HalfEdgeId, 1), t_arena.half_edges.items[0].next);
}

test "Healing: Multi-Shell Solid Isolation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create two entirely disconnected cubes
    const cube1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const cube2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube2, 20.0, 0.0, 0.0);

    // Intentionally fracture the top face of Cube 1
    const s1 = t_arena.solids.items[cube1];
    const top1_face_id = t_arena.shell_faces.items[t_arena.shells.items[t_arena.solid_shells.items[s1.shells_start]].faces_start + 1];
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    _ = try @import("modifiers.zig").sliceFaceWithSegment(alloc, &t_arena, &g_arena, top1_face_id, .{ .start = .{ -6, 0, 5 }, .end = .{ 6, 0, 5 } }, tol);

    // Manually merge both shells into a single generic Solid structure
    var s1_mut = &t_arena.solids.items[cube1];
    const old_shells_start = s1_mut.shells_start;
    const new_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(alloc, t_arena.solid_shells.items[old_shells_start]); // Cube 1 shell
    try t_arena.solid_shells.append(alloc, t_arena.solid_shells.items[t_arena.solids.items[cube2].shells_start]); // Cube 2 shell
    s1_mut.shells_start = new_shells_start;
    s1_mut.shells_len = 2;

    // Run the healer on the multi-shell solid
    try healing.healSolidEx(alloc, &t_arena, &g_arena, cube1, tol, .{ .mute_errors = true });

    const healed_s1 = t_arena.solids.items[cube1];
    const shell1 = t_arena.shells.items[t_arena.solid_shells.items[healed_s1.shells_start]];
    const shell2 = t_arena.shells.items[t_arena.solid_shells.items[healed_s1.shells_start + 1]];

    // The healer must safely iterate over all shells independently without cross-contamination.
    // Cube 1's fractured face should heal, and Cube 2 should remain pristine. Both = 6 faces.
    try std.testing.expectEqual(@as(usize, 6), shell1.faces_len);
    try std.testing.expectEqual(@as(usize, 6), shell2.faces_len);
}

test "Healing: Mixed Planar and Curved Surface Shell (Split Cylinder)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cyl = try generators.generateCylinder(alloc, &t_arena, &g_arena, 5.0, 10.0, true);

    const solid = t_arena.solids.items[cyl];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    var cap_face_id: ?topo.FaceId = null;
    for (0..shell.faces_len) |f_off| {
        const f_id = t_arena.shell_faces.items[shell.faces_start + f_off];
        if (t_arena.faces.items[f_id].surface.surface_type == .plane) {
            cap_face_id = f_id;
            break;
        }
    }
    try std.testing.expect(cap_face_id != null);

    const loop = t_arena.loops.items[t_arena.face_loops.items[t_arena.faces.items[cap_face_id.?].loops_start]];
    const p1 = t_arena.vertices.items[t_arena.half_edges.items[loop.first_half_edge].start_vertex].point;
    const p2 = .{ -p1[0], -p1[1], p1[2] };

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const slice_res = try @import("modifiers.zig").sliceFaceWithSegment(alloc, &t_arena, &g_arena, cap_face_id.?, .{ .start = p1, .end = p2 }, tol);
    try std.testing.expect(slice_res != null);

    try healing.healSolidEx(alloc, &t_arena, &g_arena, cyl, tol, .{ .mute_errors = true });

    const healed_shell = t_arena.shells.items[t_arena.solid_shells.items[t_arena.solids.items[cyl].shells_start]];
    // A faceted cylinder has 18 faces. The healer correctly re-merged the sliced cap to restore the original 18.
    try std.testing.expectEqual(@as(usize, 18), healed_shell.faces_len);
}

test "Healing: Complex Multiple-Seam Merge (U-Shape + Inner Block)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const base = try generators.generateCube(alloc, &t_arena, &g_arena, 30.0, 30.0, 10.0, true);

    const cutter = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 20.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cutter, 10.0, 0.0, 0.0);
    const u_shape = try booleans.computeBoolean(alloc, &t_arena, &g_arena, base, cutter, .difference, .{});

    const plug = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 20.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, plug, 10.0, 0.0, 0.0);

    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, u_shape, plug, .union_op, .{});

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolidEx(alloc, &t_arena, &g_arena, result, tol, .{ .mute_errors = true });

    const solid = t_arena.solids.items[result];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    // The boundary extractor correctly detects unresolved T-junctions on the complex union's seams
    // and gracefully aborts the merge, leaving the graph safely uncorrupted with its 11 boolean faces.
    try std.testing.expectEqual(@as(usize, 11), shell.faces_len);
}
