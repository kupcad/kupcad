const std = @import("std");
const math = @import("../math.zig");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const gen = @import("../generators.zig");
const types = @import("types.zig");
const modifiers = @import("modifiers.zig");

test "Modifiers Math: overlapSegments3D Exact and Partial" {
    const alloc = std.testing.allocator;
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const line = types.MathLine{ .origin = .{ 0, 0, 0 }, .direction = .{ 1, 0, 0 } };
    const segs_a = [_]types.Segment3D{.{ .start = .{ -5, 0, 0 }, .end = .{ 5, 0, 0 } }};
    const segs_b = [_]types.Segment3D{.{ .start = .{ 0, 0, 0 }, .end = .{ 10, 0, 0 } }};

    const overlap = try modifiers.overlapSegments3D(alloc, line, &segs_a, &segs_b, tol);
    defer alloc.free(overlap);

    try std.testing.expectEqual(@as(usize, 1), overlap.len);
    try std.testing.expectApproxEqAbs(0.0, overlap[0].start[0], 1e-5);
    try std.testing.expectApproxEqAbs(5.0, overlap[0].end[0], 1e-5);
}

test "Modifiers Topology: clipMathLineToFace" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const solid = t_arena.solids.items[sq_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const line = types.MathLine{ .origin = .{ 0, 5, 0 }, .direction = .{ 1, 0, 0 } };

    const segs = try modifiers.clipMathLineToFace(alloc, &t_arena, &g_arena, face_id, line, tol);
    defer alloc.free(segs);

    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectApproxEqAbs(0.0, segs[0].start[0], 1e-5);
    try std.testing.expectApproxEqAbs(10.0, segs[0].end[0], 1e-5);
}

test "Modifiers: Face Slicing Topological Stability" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const solid = t_arena.solids.items[sq_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const seg = types.Segment3D{ .start = .{ 0, 5, 0 }, .end = .{ 10, 5, 0 } };

    const new_face = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_id, seg, tol);
    try std.testing.expect(new_face != null);

    const area1 = @import("classify.zig").calculateFaceArea(&t_arena, face_id);
    const area2 = @import("classify.zig").calculateFaceArea(&t_arena, new_face.?);

    try std.testing.expectApproxEqAbs(50.0, area1, 1e-3);
    try std.testing.expectApproxEqAbs(50.0, area2, 1e-3);
}

test "Modifiers: weldSolidVertices Collapses Degenerate Edge" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
        .{ .point = .{ 10, 10, 0 } },
        .{ .point = .{ 1e-7, 1e-7, 0 } },
    });

    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 3, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 2, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 2, .twin = topo.NULL_ID, .next = 3, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 3, .twin = topo.NULL_ID, .next = 0, .prev = 2, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });
    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    try modifiers.weldSolidVertices(alloc, &t_arena, 0);
    const he = t_arena.half_edges.items[3];
    try std.testing.expect(he.start_vertex == 0);
}

test "Modifiers: reverseFaceLoops" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const solid = t_arena.solids.items[sq_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];

    const face = t_arena.faces.items[face_id];
    const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];
    const he_original = t_arena.half_edges.items[loop.first_half_edge];

    // Invert the loops
    try modifiers.reverseFaceLoops(alloc, &t_arena, face_id);

    const he_reversed = t_arena.half_edges.items[loop.first_half_edge];

    // The forward flag must be inverted
    try std.testing.expect(he_original.forward != he_reversed.forward);
    // The previous target vertex is now the current start vertex
    try std.testing.expect(he_reversed.start_vertex != he_original.start_vertex);
}

test "Modifiers: injectCircularHole Topological Linking" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 20.0, 20.0, true);
    const solid = t_arena.solids.items[sq_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];

    const circle = types.MathCircle{
        .center = .{ 0, 0, 0 },
        .radius = 5.0,
        .normal = .{ 0, 0, 1 },
        .x_axis = .{ 1, 0, 0 },
        .y_axis = .{ 0, 1, 0 },
    };

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    try modifiers.injectCircularHole(alloc, &t_arena, &g_arena, face_id, circle, tol);

    const modified_face = t_arena.faces.items[face_id];
    // The face must now have 2 loops (1 outer boundary, 1 inner circular hole)
    try std.testing.expectEqual(@as(usize, 2), modified_face.loops_len);
}

test "Modifiers: weldSolidVertices Collapses Multi-Vertex Chain" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Chain of 4 vertices with microscopic positional steps < 1e-6
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0.0, 0.0, 0.0 } },
        .{ .point = .{ 1.0e-7, 0.0, 0.0 } },
        .{ .point = .{ 2.0e-7, 0.0, 0.0 } },
        .{ .point = .{ 3.0e-7, 0.0, 0.0 } },
        .{ .point = .{ 10.0, 0.0, 0.0 } },
        .{ .point = .{ 10.0, 10.0, 0.0 } },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f_id = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3, 4, 5 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(alloc, f_id);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    try modifiers.weldSolidVertices(alloc, &t_arena, 0);

    const face = t_arena.faces.items[f_id];
    const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];

    var edge_count: usize = 0;
    var curr = loop.first_half_edge;
    while (true) {
        edge_count += 1;
        curr = t_arena.half_edges.items[curr].next;
        if (curr == loop.first_half_edge) break;
    }

    // Micro-chain (0->1->2->3) collapses down to 1 vertex, leaving a clean 3-vertex triangle
    try std.testing.expectEqual(@as(usize, 3), edge_count);
}

test "Modifiers: sliceFaceWithSegment Rejects Grazing Boundary Segment" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const solid = t_arena.solids.items[sq_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // Segment lies directly ON the bottom boundary edge [0, 0] -> [10, 0]
    const grazing_seg = types.Segment3D{ .start = .{ 0, 0, 0 }, .end = .{ 10, 0, 0 } };

    // Slicing an edge that is already a boundary MUST safely return null without corrupting topology
    const result = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_id, grazing_seg, tol);
    try std.testing.expectEqual(@as(?topo.FaceId, null), result);
}

test "Modifiers: Safety Counter Termination on Cyclic Infinite Loops in weldSolidVertices" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 } },
        .{ .point = .{ 10, 0, 0 } },
    });

    // Edge 0 -> Edge 1 -> Edge 1 (Self-loop cycle that never returns to first_half_edge)
    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 1, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });
    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const res = modifiers.weldSolidVertices(alloc, &t_arena, 0);
    try std.testing.expectError(error.TopologyCorrupted, res);
}

test "Modifiers: Safety Counter Termination on Infinite Traversal in stitchSolidBoundaries" {
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

    try t_arena.half_edges.appendSlice(alloc, &[_]topo.HalfEdge{
        .{ .start_vertex = 0, .twin = topo.NULL_ID, .next = 1, .prev = 1, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
        .{ .start_vertex = 1, .twin = topo.NULL_ID, .next = 1, .prev = 0, .loop_id = 0, .curve = .{ .index = 0, .curve_type = .line }, .forward = true },
    });

    try t_arena.loops.append(alloc, .{ .face_id = 0, .first_half_edge = 0 });
    try t_arena.face_loops.append(alloc, 0);
    try t_arena.faces.append(alloc, .{ .surface = .{ .index = 0, .surface_type = .plane }, .forward = true, .loops_start = 0, .loops_len = 1 });
    try t_arena.shell_faces.append(alloc, 0);
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 1 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    const res = modifiers.stitchSolidBoundaries(alloc, &t_arena, &g_arena, 0);
    try std.testing.expectError(error.TopologyCorrupted, res);
}

test "Modifiers: Safety Counter Termination in reverseFaceLoops" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);

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

    const res = modifiers.reverseFaceLoops(alloc, &t_arena, 0);
    try std.testing.expectError(error.TopologyCorrupted, res);
}

test "Modifiers: Redundant Segment Slicing Rejection" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const solid = t_arena.solids.items[sq_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const seg = types.Segment3D{ .start = .{ 0, 5, 0 }, .end = .{ 10, 5, 0 } };

    // Slice 1: Valid split
    const new_face = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_id, seg, tol);
    try std.testing.expect(new_face != null);

    // Slice 2: Duplicate slice along exact same line must return null without re-splitting or infinite queueing
    const duplicate_slice = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_id, seg, tol);
    try std.testing.expectEqual(@as(?topo.FaceId, null), duplicate_slice);
}

test "Modifiers: weldSolidVertices Enables Subsequent Stitching" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    // Create 2 faces that are separated by a microscopic gap (1e-7)
    try t_arena.vertices.appendSlice(alloc, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, 0 }, .tolerance = 1e-5 },
        .{ .point = .{ 10, 0, 0 }, .tolerance = 1e-5 },
        .{ .point = .{ 10, 10, 0 }, .tolerance = 1e-5 },
        .{ .point = .{ 0, 10, 0 }, .tolerance = 1e-5 },
        // Face 2 starts slightly detached
        .{ .point = .{ 10.0000001, 0, 0 }, .tolerance = 1e-5 },
        .{ .point = .{ 20, 0, 0 }, .tolerance = 1e-5 },
        .{ .point = .{ 20, 10, 0 }, .tolerance = 1e-5 },
        .{ .point = .{ 10.0000001, 10, 0 }, .tolerance = 1e-5 },
    });

    try g_arena.planes.append(alloc, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(gen.EdgeKey, topo.HalfEdgeId).init(alloc);
    defer twin_map.deinit();

    const f1 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 0, 1, 2, 3 }, .{ .index = 0, .surface_type = .plane }, &twin_map);
    const f2 = try gen.addPolygonFace(alloc, &t_arena, &g_arena, &[_]topo.VertexId{ 4, 5, 6, 7 }, .{ .index = 0, .surface_type = .plane }, &twin_map);

    try t_arena.shell_faces.appendSlice(alloc, &[_]topo.FaceId{ f1, f2 });
    try t_arena.shells.append(alloc, .{ .faces_start = 0, .faces_len = 2 });
    try t_arena.solid_shells.append(alloc, 0);
    try t_arena.solids.append(alloc, .{ .shells_start = 0, .shells_len = 1 });

    // 1. Weld vertices. It must snap vertices 4->1 and 7->2.
    try modifiers.weldSolidVertices(alloc, &t_arena, 0);

    // 2. Stitch boundaries. Now that vertices match exactly, it must twin the shared edge.
    try modifiers.stitchSolidBoundaries(alloc, &t_arena, &g_arena, 0);

    // Verify the inner seam has successfully twinned
    var twin_found = false;
    for (t_arena.half_edges.items) |he| {
        if (he.twin != topo.NULL_ID) {
            twin_found = true;
            break;
        }
    }

    try std.testing.expect(twin_found);
}

test "Modifiers: Diagonal Slice Correctly Bisects Face" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const sq_id = try gen.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const solid = t_arena.solids.items[sq_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    // Slice exactly diagonally from (0,0) to (10,10)
    const seg = types.Segment3D{ .start = .{ 0, 0, 0 }, .end = .{ 10, 10, 0 } };

    const new_face = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_id, seg, tol);
    try std.testing.expect(new_face != null);

    // The original 100-area square should now be split into two 50-area triangles
    const area1 = @import("classify.zig").calculateFaceArea(&t_arena, face_id);
    const area2 = @import("classify.zig").calculateFaceArea(&t_arena, new_face.?);

    try std.testing.expectApproxEqAbs(50.0, area1, 1e-3);
    try std.testing.expectApproxEqAbs(50.0, area2, 1e-3);
}
