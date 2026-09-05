const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const generators = @import("../generators.zig");
const validator = @import("../validator.zig");
const blends = @import("blends.zig");
const modifiers = @import("modifiers.zig");
const types = @import("types.zig");

test "Blends: Constant Radius Fillet Surface Generation" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const radius = 2.0;
    const surf_id = try blends.createConstantFilletSurface(alloc, &t_arena, &g_arena, target_he, radius);

    const surf = g_arena.nurbs_surfaces.items[surf_id];

    try std.testing.expectEqual(@as(u32, 2), surf.degree_u);
    try std.testing.expectEqual(@as(u32, 3), surf.num_cp_u);

    const mid_pt = surf.evaluate(0.5, 0.5);
    try std.testing.expect(math.mag(mid_pt) > 0.0);
}

test "Blends: Apply Edge Blend Topological Trimming" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const radius = 2.0;
    const initial_face_count = t_arena.faces.items.len;

    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, radius);

    try std.testing.expect(t_arena.faces.items.len >= initial_face_count + 3);

    const fillet_face = t_arena.faces.items[result.fillet_face];
    try std.testing.expectEqual(.nurbs, fillet_face.surface.surface_type);

    const surf = g_arena.nurbs_surfaces.items[fillet_face.surface.index];
    try std.testing.expectEqual(@as(u32, 2), surf.degree_u);
}

test "Blends: Full Edge Blend Topology Rewiring" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const radius = 2.0;
    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, radius);

    const solid = t_arena.solids.items[result.new_solid];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    try std.testing.expectEqual(@as(usize, 7), shell.faces_len);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result.new_solid, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
        .check_twins = true,
    });
}

test "Blends: Fillet Cap Topology Verification" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const radius = 2.0;
    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, radius);

    const fillet_face = t_arena.faces.items[result.fillet_face];
    const loop = t_arena.loops.items[t_arena.face_loops.items[fillet_face.loops_start]];

    var edge_count: usize = 0;
    var curr = loop.first_half_edge;
    while (true) {
        edge_count += 1;
        curr = t_arena.half_edges.items[curr].next;
        if (curr == loop.first_half_edge) break;
    }

    try std.testing.expectEqual(@as(usize, 4), edge_count);
}

test "Blends: 3-Way Corner Setback Surface Math" {
    const alloc = std.testing.allocator;
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const p_corner = math.Vec3{ 10.0, 10.0, 10.0 };
    const radius = 2.0;

    const normals = [_]math.Vec3{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    };

    const surf_idx = try blends.createCornerSetbackPatch(alloc, &g_arena, p_corner, radius, normals);
    const surf = g_arena.nurbs_surfaces.items[surf_idx];

    try std.testing.expectEqual(@as(u32, 2), surf.degree_u);
    try std.testing.expectEqual(@as(u32, 2), surf.degree_v);
    try std.testing.expectEqual(@as(usize, 9), surf.control_points.len);

    const mid_pt = surf.evaluate(0.5, 0.5);
    try std.testing.expect(math.mag(mid_pt) > 0.0);
}

test "Blends: Setback Endpoint Location vs Boundary Edges" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);

    const p_corner = t_arena.vertices.items[0].point;
    try std.testing.expectEqual(math.Vec3{ 0.0, 0.0, 0.0 }, p_corner);

    const d: f64 = 2.0;
    const setback: f64 = 2.0;
    const seg_start = math.Vec3{ setback, d, 0.0 };

    const tol: f64 = 1e-5;
    try std.testing.expect(seg_start[0] > tol);
    try std.testing.expect(seg_start[1] > tol);
}

test "Blends: Extended Boundary Setback Slice" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);

    const face_0_id: topo.FaceId = 0;
    const extended_seg = types.Segment3D{
        .start = .{ 0.0, 2.0, 0.0 },
        .end = .{ 10.0, 2.0, 0.0 },
    };

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
    const sliced = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_0_id, extended_seg, tol);

    try std.testing.expect(sliced != null);
}

test "Blends: Multi-Edge Axis Selection" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);
    const corner_v: topo.VertexId = 0; // Origin (0,0,0)

    const axes = [_]math.Vec3{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    };

    for (axes) |axis| {
        var found = false;
        for (t_arena.half_edges.items) |he| {
            if (he.twin != topo.NULL_ID) {
                const p_start = t_arena.vertices.items[he.start_vertex].point;
                const twin = t_arena.half_edges.items[he.twin];
                const p_end = t_arena.vertices.items[twin.start_vertex].point;

                if (math.distSq(p_start, t_arena.vertices.items[corner_v].point) < 1e-5) {
                    const dir = math.normalize(math.sub(p_end, p_start));
                    if (math.dot(dir, axis) > 0.99) {
                        found = true;
                        break;
                    }
                }
            }
        }
        try std.testing.expect(found);
    }
}

test "Blends: Double-Ended Setback Rail Splitting" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);

    var target_he: ?topo.HalfEdgeId = null;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID and he.start_vertex == 0) {
            const twin = t_arena.half_edges.items[he.twin];
            const p_end = t_arena.vertices.items[twin.start_vertex].point;

            if (p_end[0] > 9.9 and p_end[1] < 0.1 and p_end[2] < 0.1) {
                target_he = @intCast(i);
                break;
            }
        }
    }

    const he_id = target_he orelse return error.TopologyCorrupted;

    const result = try blends.applyEdgeBlendEx(alloc, &t_arena, &g_arena, cube_id, he_id, 2.0, .{
        .setback_start = 2.0,
        .setback_end = 2.0,
    });

    const fillet_face = t_arena.faces.items[result.fillet_face];
    try std.testing.expectEqual(.nurbs, fillet_face.surface.surface_type);
}

test "Blends Sub-Method: Sequential Face Cross-Slicing" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const face_0_id: topo.FaceId = 0;
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    const line_1 = types.MathLine{ .origin = .{ 2.0, 0.0, 0.0 }, .direction = .{ 0.0, 1.0, 0.0 } };
    const segs_1 = try modifiers.clipMathLineToFace(alloc, &t_arena, &g_arena, face_0_id, line_1, tol);
    defer alloc.free(segs_1);
    try std.testing.expectEqual(@as(usize, 1), segs_1.len);

    const new_face_1 = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_0_id, segs_1[0], tol);
    try std.testing.expect(new_face_1 != null);

    const line_2 = types.MathLine{ .origin = .{ 0.0, 2.0, 0.0 }, .direction = .{ 1.0, 0.0, 0.0 } };
    const segs_2 = try modifiers.clipMathLineToFace(alloc, &t_arena, &g_arena, face_0_id, line_2, tol);
    defer alloc.free(segs_2);
    try std.testing.expectEqual(@as(usize, 1), segs_2.len);

    const new_face_2 = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_0_id, segs_2[0], tol);
    try std.testing.expect(new_face_2 != null);
}

test "Blends Sub-Method: Boundary Vertex Projection & Snapping" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);
    const face_0_id: topo.FaceId = 0;
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    const seg_1 = types.Segment3D{
        .start = .{ 2.0, 0.0, 0.0 },
        .end = .{ 2.0, 10.0, 0.0 },
    };
    _ = try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_0_id, seg_1, tol);

    const loop_id = t_arena.face_loops.items[t_arena.faces.items[face_0_id].loops_start];
    const snap_pt = math.Vec3{ 2.0, 0.0, 0.0 };

    var found_v: ?topo.VertexId = null;
    const loop = t_arena.loops.items[loop_id];
    var curr = loop.first_half_edge;
    while (true) {
        const v = t_arena.half_edges.items[curr].start_vertex;
        if (math.distSq(t_arena.vertices.items[v].point, snap_pt) < tol.squared) {
            found_v = v;
            break;
        }
        curr = t_arena.half_edges.items[curr].next;
        if (curr == loop.first_half_edge) break;
    }

    try std.testing.expect(found_v != null);
}

test "Blends Sub-Method: Shared Edge Discovery Across Split Faces" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    _ = try generators.generateSquare(alloc, &t_arena, &g_arena, 10.0, 10.0, false);
    const face_0_id: topo.FaceId = 0;
    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    const seg_1 = types.Segment3D{
        .start = .{ 2.0, 0.0, 0.0 },
        .end = .{ 2.0, 10.0, 0.0 },
    };
    const new_face_id = (try modifiers.sliceFaceWithSegment(alloc, &t_arena, &g_arena, face_0_id, seg_1, tol)).?;

    const shared_he = blends.findSharedHalfEdge(&t_arena, face_0_id, new_face_id);
    try std.testing.expect(shared_he != null);
}

test "Blends: Sequential Edge Blend Boundary Stability" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);
    const radius = 1.0;

    const res1 = try blends.applyEdgeBlendEx(alloc, &t_arena, &g_arena, cube_id, 0, radius, .{
        .skip_trim_start = true,
        .skip_trim_end = true,
    });
    try std.testing.expect(res1.fillet_face != topo.NULL_ID);

    var target_he2: ?topo.HalfEdgeId = null;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID and i != 0) {
            const face_id = t_arena.loops.items[he.loop_id].face_id;
            if (t_arena.faces.items[face_id].surface.surface_type == .plane) {
                target_he2 = @intCast(i);
                break;
            }
        }
    }

    if (target_he2) |he2| {
        const res2 = try blends.applyEdgeBlendEx(alloc, &t_arena, &g_arena, cube_id, he2, radius, .{
            .skip_trim_start = true,
            .skip_trim_end = true,
        });
        try std.testing.expect(res2.fillet_face != topo.NULL_ID);
    }
}

test "Blends: Shell Face Registration Post-Slice" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, 2.0);

    const solid_after = t_arena.solids.items[result.new_solid];
    const shell_after = t_arena.shells.items[t_arena.solid_shells.items[solid_after.shells_start]];

    try std.testing.expectEqual(@as(usize, 7), shell_after.faces_len);
}

test "Blends: Trace Twin Symmetry and Cap Adjacency" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, 2.0);

    const solid = t_arena.solids.items[result.new_solid];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    for (0..shell.faces_len) |f_off| {
        const f_id = t_arena.shell_faces.items[shell.faces_start + f_off];
        const face = t_arena.faces.items[f_id];

        for (0..face.loops_len) |l_off| {
            const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
            const loop = t_arena.loops.items[loop_id];

            var curr = loop.first_half_edge;
            while (true) {
                const he = t_arena.half_edges.items[curr];
                try std.testing.expect(he.twin != topo.NULL_ID);
                const twin_he = t_arena.half_edges.items[he.twin];
                try std.testing.expectEqual(curr, twin_he.twin);

                curr = he.next;
                if (curr == loop.first_half_edge) break;
            }
        }
    }
}

test "Blends: Euler Invariant Verification Step-by-Step" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, true);

    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, cube_id, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
    });

    var target_he: topo.HalfEdgeId = 0;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            target_he = @intCast(i);
            break;
        }
    }

    const result = try blends.applyEdgeBlend(alloc, &t_arena, &g_arena, cube_id, target_he, 1.5);

    try validator.BRepSanitizer.validateSolid(alloc, &t_arena, &g_arena, result.new_solid, tol, .{
        .check_euler = true,
        .require_closed_shells = true,
        .check_twins = true,
    });
}

test "Diagnostic: Verify Edge Severing Behavior During Sequential Setbacks" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);
    const radius = 2.0;

    // Blend X-axis edge (0 to 10)
    var he_x: topo.HalfEdgeId = undefined;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            const p1 = t_arena.vertices.items[he.start_vertex].point;
            const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.twin].start_vertex].point;
            if (math.distSq(p1, .{ 0, 0, 0 }) < 1e-5 and math.distSq(p2, .{ 10, 0, 0 }) < 1e-5) {
                he_x = @intCast(i);
                break;
            }
        }
    }
    _ = try blends.applyEdgeBlendEx(alloc, &t_arena, &g_arena, cube_id, he_x, radius, .{
        .setback_start = 2.0,
        .skip_trim_start = true,
    });

    const solid = t_arena.solids.items[cube_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start]];

    var faces_with_origin: usize = 0;
    for (0..shell.faces_len) |f_off| {
        const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
        const face = t_arena.faces.items[face_id];
        for (0..face.loops_len) |l_off| {
            const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start + l_off]];
            var curr = loop.first_half_edge;
            var found_in_face = false;
            while (true) {
                const he = t_arena.half_edges.items[curr];
                const pt = t_arena.vertices.items[he.start_vertex].point;
                if (math.distSq(pt, .{ 0, 0, 0 }) < 1e-5) found_in_face = true;
                curr = he.next;
                if (curr == loop.first_half_edge) break;
            }
            if (found_in_face) faces_with_origin += 1;
        }
    }

    // The origin started in 3 faces. After blending 1 edge with a setback and skipping the cap trim,
    // the 2 longitudinal strips are removed. The origin MUST remain exactly in the 1 orthogonal cap face.
    try std.testing.expectEqual(@as(usize, 1), faces_with_origin);
}

test "Blends: 3-Way Corner Setback Topological Integration" {
    const alloc = std.testing.allocator;
    var t_arena = topo.TopologyArena.init(alloc);
    defer t_arena.deinit(alloc);
    var g_arena = geom.GeometryArena.init(alloc);
    defer g_arena.deinit(alloc);

    const cube_id = try generators.generateCube(alloc, &t_arena, &g_arena, 10.0, 10.0, 10.0, false);
    const radius = 2.0;

    // 1. Blend X-axis edge (Original length 10.0)
    var he_x: topo.HalfEdgeId = undefined;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            const p1 = t_arena.vertices.items[he.start_vertex].point;
            const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.twin].start_vertex].point;
            if (math.distSq(p1, .{ 0, 0, 0 }) < 1e-5 and math.distSq(p2, .{ 10, 0, 0 }) < 1e-5) {
                he_x = @intCast(i);
                break;
            }
        }
    }

    _ = try blends.applyEdgeBlendEx(alloc, &t_arena, &g_arena, cube_id, he_x, radius, .{
        .setback_start = 2.0,
        .setback_end = 0.0,
        .skip_trim_start = true,
    });

    // 2. Blend Y-axis edge (Surviving active segment is now 8.0mm long, spanning Y: 2 to 10)
    var he_y: topo.HalfEdgeId = undefined;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            const face_id = t_arena.loops.items[he.loop_id].face_id;
            // Ensure we strictly pick edges belonging to active planar face bodies, not severed strips
            if (t_arena.faces.items[face_id].surface.surface_type == .plane) {
                const p1 = t_arena.vertices.items[he.start_vertex].point;
                const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.twin].start_vertex].point;
                if (math.distSq(p1, .{ 0, 2, 0 }) < 1e-5 and math.distSq(p2, .{ 0, 10, 0 }) < 1e-5) {
                    he_y = @intCast(i);
                    break;
                }
            }
        }
    }

    _ = try blends.applyEdgeBlendEx(alloc, &t_arena, &g_arena, cube_id, he_y, radius, .{
        .setback_start = 0.0, // Vertex already rests at the precise 2.0 offset boundary
        .setback_end = 0.0,
        .skip_trim_start = true,
    });

    // 3. Blend Z-axis edge (Surviving active segment is now 8.0mm long, spanning Z: 2 to 10)
    var he_z: topo.HalfEdgeId = undefined;
    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin != topo.NULL_ID) {
            const face_id = t_arena.loops.items[he.loop_id].face_id;
            if (t_arena.faces.items[face_id].surface.surface_type == .plane) {
                const p1 = t_arena.vertices.items[he.start_vertex].point;
                const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.twin].start_vertex].point;
                if (math.distSq(p1, .{ 0, 0, 2 }) < 1e-5 and math.distSq(p2, .{ 0, 0, 10 }) < 1e-5) {
                    he_z = @intCast(i);
                    break;
                }
            }
        }
    }

    _ = try blends.applyEdgeBlendEx(alloc, &t_arena, &g_arena, cube_id, he_z, radius, .{
        .setback_start = 0.0,
        .setback_end = 0.0,
        .skip_trim_start = true,
    });

    // 4. Seal the 3-Way Corner Setback
    const corner_v = 0; // The geometric origin still functions as the spatial locus center
    const setback_face = try blends.applyCornerSetback3Way(alloc, &t_arena, &g_arena, cube_id, corner_v, radius);

    // Validate Corner Patch Topology
    const face = t_arena.faces.items[setback_face];
    try std.testing.expectEqual(.nurbs, face.surface.surface_type);

    const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];
    var edge_count: usize = 0;
    var curr = loop.first_half_edge;
    while (true) {
        edge_count += 1;
        try std.testing.expect(t_arena.half_edges.items[curr].twin != topo.NULL_ID);
        curr = t_arena.half_edges.items[curr].next;
        if (curr == loop.first_half_edge) break;
    }

    // Valid corner cap must form a perfectly manifold 3-sided patch
    try std.testing.expectEqual(@as(usize, 3), edge_count);
}
