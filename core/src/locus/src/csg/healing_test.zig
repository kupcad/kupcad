const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const booleans = @import("../booleans.zig");
const generators = @import("../generators.zig");
const transforms = @import("../transforms.zig");
const healing = @import("healing.zig");
const gen = @import("../generators.zig");
const validator = @import("../validator.zig");

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

    const result_solid = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a, cube_b, .union_op);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, result_solid, tol);

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
        base_solid = try booleans.computeBoolean(alloc, &t_arena, &g_arena, base_solid, next_cube, .union_op);
    }

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, base_solid, tol);

    const solid = t_arena.solids.items[base_solid];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    // The healer merges the 4 outer walls and 4 inner walls into 8 faces.
    // The top and bottom coplanar ring faces contain 4-way corner junctions, so the
    // boundary tracer safely aborts their merge to uphold strict 1:1 manifold invariants.
    // Result: 8 side/inner walls + 8 top/bottom faces = 16 safe, uncorrupted faces.
    try std.testing.expectEqual(@as(usize, 16), shell.faces_len);
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
    try healing.healSolid(alloc, &t_arena, &g_arena, cyl, tol);

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
    const pair_a = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_a1, cube_a2, .union_op);

    // Pair 2: Right side (X: [40, 60]), completely disjoint but sharing the exact same Z=5 top plane
    const cube_b1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const cube_b2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_b1, 40.0, 0.0, 0.0);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube_b2, 50.0, 0.0, 0.0);
    const pair_b = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube_b1, cube_b2, .union_op);

    // Merge both disjoint solids into one combined solid container
    const combined = try booleans.computeBoolean(alloc, &t_arena, &g_arena, pair_a, pair_b, .union_op);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, combined, tol);

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
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);

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
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
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
    try healing.healSolid(alloc, &t_arena, &g_arena, cube1, tol);

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

    try healing.healSolid(alloc, &t_arena, &g_arena, cyl, tol);

    const healed_shell = t_arena.shells.items[t_arena.solid_shells.items[t_arena.solids.items[cyl].shells_start]];
    // A faceted cylinder has 18 faces. The healer correctly re-merged the sliced cap to restore the original 18.
    try std.testing.expectEqual(@as(usize, 18), healed_shell.faces_len);
}

test "Healing: Graceful Exit on Empty Solid" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create a mathematically valid solid container with 0 shells
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 0 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // Engine MUST safely exit without panicking on out-of-bounds shell indices
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);

    try std.testing.expectEqual(@as(usize, 0), t_arena.solids.items[0].shells_len);
}

test "Healing: Rejects Near-Coplanar Faces Outside Angular Tolerance" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Plane 1: Flat on Z (Normal 0,0,1)
    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    // Plane 2: Tilted on the Y axis obviously beyond the 1e-5 tolerance (Slope 0.1)
    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 10, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 0.995, 0.1 } });

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 0, 10, 0 } },
        .{ .point = .{ 10, 20, 1.0 } }, // Tilted up substantially to Z=1.0
        .{ .point = .{ 0, 20, 1.0 } },
    });

    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    // The two faces share the edge (2, 3), but their normals are definitively distinct
    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 3, 2, 4, 5 }, .{ .index = 1, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ f1, f2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);

    // The island clustering phase must recognize the angular difference and refuse to merge them.
    const solid = t_arena.solids.items[0];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    try std.testing.expectEqual(@as(usize, 2), shell.faces_len);
}

test "Healing: Disjoint Faces on Same Plane Remain Separate Islands" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        // Face 1 (X: 0 to 10)
        .{ .point = .{ 0, 0, 0 } },  .{ .point = .{ 10, 0, 0 } }, .{ .point = .{ 10, 10, 0 } }, .{ .point = .{ 0, 10, 0 } },
        // Face 2 (X: 20 to 30) - Completely physically separated
        .{ .point = .{ 20, 0, 0 } }, .{ .point = .{ 30, 0, 0 } }, .{ .point = .{ 30, 10, 0 } }, .{ .point = .{ 20, 10, 0 } },
    });

    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    // Both faces share the exact same underlying surface_index (0)
    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 4, 5, 6, 7 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ f1, f2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);

    // Because they share no boundary twin edges, the BFS traversal cannot cross the gap.
    // They form 2 distinct islands of size 1 and cannot be merged. Face count remains 2.
    const solid = t_arena.solids.items[0];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    try std.testing.expectEqual(@as(usize, 2), shell.faces_len);
}

test "Healing: Coplanar Faces Forming a Hole Preserve Multiple Loops" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create a 30x30 square frame composed of 4 trapezoidal faces.
    // Outer boundary is 30x30. Inner boundary is a 10x10 hole in the center.
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } }, // 0 (Outer BL)
        .{ .point = .{ 30, 0, 0 } }, // 1 (Outer BR)
        .{ .point = .{ 30, 30, 0 } }, // 2 (Outer TR)
        .{ .point = .{ 0, 30, 0 } }, // 3 (Outer TL)
        .{ .point = .{ 10, 10, 0 } }, // 4 (Inner BL)
        .{ .point = .{ 20, 10, 0 } }, // 5 (Inner BR)
        .{ .point = .{ 20, 20, 0 } }, // 6 (Inner TR)
        .{ .point = .{ 10, 20, 0 } }, // 7 (Inner TL)
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    // 4 faces forming the frame in CCW orientation
    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 5, 4 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 1, 2, 6, 5 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f3 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 2, 3, 7, 6 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f4 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 3, 0, 4, 7 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(f1, {});
    try island_set.put(f2, {});
    try island_set.put(f3, {});
    try island_set.put(f4, {});

    const island = [_]topo.FaceId{ f1, f2, f3, f4 };

    // Extract the island. The boundary tracer MUST identify that there are two distinct loops
    // (the outer square and the inner square) and assign them both to the new merged face.
    const merged_face_id = try healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);
    const merged_face = t_arena.faces.items[merged_face_id];

    // The resulting face must have exactly 2 loops (1 outer boundary, 1 inner hole).
    try std.testing.expectEqual(@as(usize, 2), merged_face.loops_len);
}

test "Healing: Hang Test - Zero Length Micro-Edge Collapse" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // V1 and V2 are at the exact same physical coordinate.
    // This creates a zero-length edge between them.
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } }, // Duplicate!
        .{ .point = .{ 0, 10, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{f1});
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    // If the healer's edge-collapse logic fails to properly advance pointers, it will hang here.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - Two-Edge Degenerate Ribbon" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    // A face constructed of only 2 edges that just trace back and forth
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 0, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{0});
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    // If the healer gets stuck trying to process a face with no area/valid loop, it hangs here.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - Collinear Zero-Area Face" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Three vertices, but they lie perfectly on the same X-axis line.
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 5, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{f1});
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    // If the collinear-vertex removal logic loops infinitely when the face flattens out, it hangs here.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - Coplanar Bowtie Retry Loop" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create a bowtie (non-manifold at vertex 0)
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 0, 10, 0 } },
        .{ .point = .{ 10, -10, 0 } },
        .{ .point = .{ 0, -10, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 3, 4 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ f1, f2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // If healSolidEx catches the TopologyCorrupted error from extractIslandBoundary
    // but forgets to mark these faces as "processed", its outer loop will hang right here.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - Perfectly Overlapping Identical Faces" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 0, 10, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    // Two identical faces occupying the exact same space (classic Boolean artifact)
    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ f1, f2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // If the island boundary tracer gets trapped in a cycle mapping overlapping boundary edges
    // without advancing, it hangs here.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - Inverted Overlapping Faces (Zero-Volume Void)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 0, 10, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    // Face 1 is Normal CCW. Face 2 is reversed CW.
    // They share a plane but have inverted winding orders.
    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 3, 2, 1 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ f1, f2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // If the healer ignores normal vectors when clustering, it will try to merge inverted faces
    // and fail to resolve the boundary, causing a hang.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - BFS Self-Twinning Face (Internal Slit)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create a square with an internal slit (a zero-width cut stopping in the middle)
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 0, 10, 0 } },
        .{ .point = .{ 5, 5, 0 } }, // The end of the slit
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    // The slit is formed by two half-edges that twin with *each other* inside the *same* face.
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 5, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 2, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 2, .twin = 3, .next = 3, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }, // Slit In
        .{ .start_vertex = 4, .twin = 2, .next = 4, .prev = 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true }, // Slit Out
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 5, .prev = 3, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 3, .twin = topo.NULL_ID, .next = 0, .prev = 4, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{0});
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // If the healer's BFS twin-crawler doesn't properly track visited faces or skips
    // self-referential twins, it will enqueue Face 0 infinitely and hang here.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - BFS Asymmetric Twin Cycle" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } }, .{ .point = .{ 10, 0, 0 } }, .{ .point = .{ 0, 10, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    // Corrupted Boolean state: 3 edges that form a cyclic twin loop (0.twin=1, 1.twin=2, 2.twin=0)
    // instead of standard symmetric twins (0.twin=1, 1.twin=0).
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = 1, .next = 0, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 0, .twin = 2, .next = 1, .prev = 1, .loop_id = 1, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 0, .twin = 0, .next = 2, .prev = 2, .loop_id = 2, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.appendSlice(alloc, &[_]topo.Loop{
        .{ .face_id = 0, .first_half_edge = 0 },
        .{ .face_id = 1, .first_half_edge = 1 },
        .{ .face_id = 2, .first_half_edge = 2 },
    });
    try t_arena.face_loops.appendSlice(alloc, &[_]topo.LoopId{ 0, 1, 2 });
    try t_arena.faces.appendSlice(alloc, &[_]topo.Face{
        .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 },
        .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 1, .loops_len = 1 },
        .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 2, .loops_len = 1 },
    });

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ 0, 1, 2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 3 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // If BFS traversal blindly trusts twins without a visited set, it will spin A->B->C->A forever.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - Nested Coplanar Islands (Concentric Rings)" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    // Create a 30x30 outer face, a 20x20 middle face, and a 10x10 inner face.
    // They are all completely coplanar and overlapping. The boundary extractor will attempt to merge them.
    const f1 = try gen.generateSquare(alloc, &t_arena, &g_arena, 30.0, 30.0, false);
    const f2 = try gen.generateSquare(alloc, &t_arena, &g_arena, 20.0, 20.0, false);
    const f3 = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);

    // Merge them into one shell
    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{
        t_arena.shell_faces.items[t_arena.shells.items[t_arena.solid_shells.items[t_arena.solids.items[f1].shells_start]].faces_start],
        t_arena.shell_faces.items[t_arena.shells.items[t_arena.solid_shells.items[t_arena.solids.items[f2].shells_start]].faces_start],
        t_arena.shell_faces.items[t_arena.shells.items[t_arena.solid_shells.items[t_arena.solids.items[f3].shells_start]].faces_start],
    });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 3 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // If the boundary algorithm cannot resolve deeply nested boundaries,
    // it will loop indefinitely trying to link the nested loops together.
    try healing.healSolid(alloc, &t_arena, &g_arena, 0, tol);
}

test "Healing: Hang Test - Shared Faces Mutated by Healer" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const cube2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube2, 10, 0, 0);

    // Boolean union reuses unmodified faces from cube1 to build union_solid
    const union_solid = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube1, cube2, .union_op);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, union_solid, tol);

    // Now traverse the ORIGINAL cube1!
    // If the healer mutated shared edges in place, traversing cube1 will hit NULL_IDs and panic.
    const s1 = t_arena.solids.items[cube1];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[s1.shells_start]];
    for (0..shell.faces_len) |f_off| {
        const face = t_arena.faces.items[t_arena.shell_faces.items[shell.faces_start + f_off]];
        for (0..face.loops_len) |l_off| {
            const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start + l_off]];
            var curr = loop.first_half_edge;
            var safety: usize = 0;
            while (true) : (safety += 1) {
                try std.testing.expect(safety < 100);
                const he = t_arena.half_edges.items[curr];

                // This will fail because cube1's graph was destroyed by the healer operating on union_solid
                try std.testing.expect(he.next != topo.NULL_ID);

                curr = he.next;
                if (curr == loop.first_half_edge) break;
            }
        }
    }
}

test "Healing: Hang Test - Healed Solid Fails Manifold Validation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube1 = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    const cube2 = try generators.generateCube(alloc, &t_arena, &g_arena, 10, 10, 10, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, cube2, 10, 0, 0);

    const union_solid = try booleans.computeBoolean(alloc, &t_arena, &g_arena, cube1, cube2, .union_op);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, union_solid, tol);

    // Validate the healed solid strictly to ensure the healer didn't create twinless edges or corrupted cycles.
    // If the healer breaks twins, this validator will catch it immediately and fail the test.
    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, union_solid, tol, .{
        .check_degenerates = true,
        .require_closed_shells = true,
    });
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
    const u_shape = try booleans.computeBoolean(alloc, &t_arena, &g_arena, base, cutter, .difference);

    const plug = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 20.0, 10.0, true);
    _ = try transforms.translateSolid(alloc, &t_arena, &g_arena, plug, 10.0, 0.0, 0.0);

    const result = try booleans.computeBoolean(alloc, &t_arena, &g_arena, u_shape, plug, .union_op);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try healing.healSolid(alloc, &t_arena, &g_arena, result, tol);

    const solid = t_arena.solids.items[result];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    // The healer successfully merges the coplanar union seams, collapsing 11 intermediate faces down to 8.
    try std.testing.expectEqual(@as(usize, 8), shell.faces_len);
}

test "Healing: Hang Test - Orphaned Loop Traversal Causes Infinite Cycle" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 0, 10, 0 } },
        .{ .point = .{ 20, 0, 0 } },
        .{ .point = .{ 20, 10, 0 } },
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
    _ = try healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);

    // Verify consumed face f2 is safely tombstoned so global iterators skip it
    try std.testing.expectEqual(@as(usize, 0), t_arena.faces.items[f2].loops_len);
}

test "Healing: Hang Test - Internal Seam Traversal Cycles Infinitely" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 0, 10, 0 } },
        .{ .point = .{ 20, 0, 0 } },
        .{ .point = .{ 20, 10, 0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 1, 4, 5, 2 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    // Locate the internal seam half-edge (edge from vertex 1 to vertex 2)
    var seam_he: topo.HalfEdgeId = topo.NULL_ID;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.start_vertex == 1 and t_arena.half_edges.items[he.next].start_vertex == 2) {
            seam_he = @intCast(i);
            break;
        }
    }
    try std.testing.expect(seam_he != topo.NULL_ID);

    var island_set = std.AutoHashMap(topo.FaceId, void).init(alloc);
    defer island_set.deinit();
    try island_set.put(f1, {});
    try island_set.put(f2, {});

    const island = [_]topo.FaceId{ f1, f2 };
    _ = try healing.extractIslandBoundary(alloc, &t_arena, &island, &island_set);

    // Attempt to traverse half-edges starting from the internal seam
    var curr = seam_he;
    var count: usize = 0;
    while (true) {
        count += 1;
        // A valid loop should close in < 10 steps. If count hits 100, the graph is trapped in an infinite cycle!
        try std.testing.expect(count < 100);

        curr = t_arena.half_edges.items[curr].next;
        if (curr == topo.NULL_ID or curr == seam_he) break;
    }
}
