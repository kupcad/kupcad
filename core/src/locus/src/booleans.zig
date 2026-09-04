const std = @import("std");
const builtin = @import("builtin");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const nurbs_ssi = @import("nurbs_ssi.zig");
const classify = @import("csg/classify.zig");
const intersections = @import("csg/intersections.zig");
const modifiers = @import("csg/modifiers.zig");
const types = @import("csg/types.zig");

pub const BooleanOp = types.BooleanOp;
pub const FaceTracker = types.FaceTracker;
const BooleanError = types.BooleanError;
const IntersectionEvent = types.IntersectionEvent;
const MathCircle = types.MathCircle;

pub const isPointInsideSolid = classify.isPointInsideSolid;
pub const isPointInsideSolidFaces = classify.isPointInsideSolidFaces;

fn collectPiercings(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_edges: topo.SolidId,
    solid_faces: topo.SolidId,
    out_events: *std.ArrayListUnmanaged(IntersectionEvent),
    tol: math.Tolerance,
) !void {
    const s_edges = t_arena.solids.items[solid_edges];
    const s_faces = t_arena.solids.items[solid_faces];

    for (0..s_faces.shells_len) |sf_off| {
        const shell_f = t_arena.shells.items[t_arena.solid_shells.items[s_faces.shells_start + sf_off]];
        for (0..shell_f.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell_f.faces_start + f_off];
            const face = t_arena.faces.items[face_id];

            for (0..s_edges.shells_len) |se_off| {
                const shell_e = t_arena.shells.items[t_arena.solid_shells.items[s_edges.shells_start + se_off]];
                for (0..shell_e.faces_len) |fe_off| {
                    const t_face = t_arena.faces.items[t_arena.shell_faces.items[shell_e.faces_start + fe_off]];
                    for (0..t_face.loops_len) |we_off| {
                        const t_loop = t_arena.loops.items[t_arena.face_loops.items[t_face.loops_start + we_off]];

                        var target_he_id = t_loop.first_half_edge;
                        while (true) {
                            const edge = t_arena.half_edges.items[target_he_id];

                            if (edge.twin == topo.NULL_ID or target_he_id < edge.twin) {
                                const v_start = t_arena.vertices.items[edge.start_vertex].point;
                                const v_end = t_arena.vertices.items[t_arena.half_edges.items[edge.next].start_vertex].point;

                                var hit_pts: []math.Vec3 = &[_]math.Vec3{};
                                defer if (hit_pts.len > 0) allocator.free(hit_pts);

                                if (face.surface.surface_type == .plane) {
                                    const plane = g_arena.planes.items[face.surface.index];
                                    var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
                                    if (!face.forward) normal = math.scale(normal, -1.0);

                                    var hit_pt_opt: ?math.Vec3 = null;
                                    switch (edge.curve.curve_type) {
                                        .line => hit_pt_opt = intersections.intersectLinePlane(g_arena.lines.items[edge.curve.index].start, g_arena.lines.items[edge.curve.index].end, plane.origin, normal, tol),
                                        .circle_arc => hit_pt_opt = intersections.intersectArcPlane(g_arena.circle_arcs.items[edge.curve.index], v_start, v_end, plane.origin, normal, edge.forward, tol),
                                        .nurbs => hit_pt_opt = intersections.intersectNurbsPlane(g_arena.nurbs_curves.items[edge.curve.index], plane.origin, normal, tol),
                                    }
                                    if (hit_pt_opt) |hp| {
                                        var slice = try allocator.alloc(math.Vec3, 1);
                                        slice[0] = hp;
                                        hit_pts = slice;
                                    }
                                } else {
                                    // Quadric Surface Piercings (.cylinder, .cone, .sphere, .torus)
                                    hit_pts = try intersections.intersectSegmentSurface(allocator, g_arena, face.surface, v_start, v_end, tol);
                                }

                                for (hit_pts) |hit_pt| {
                                    const uv_hit = g_arena.surfaceProject(face.surface, hit_pt);
                                    // Evaluate exact grazing angle for fat-vertex tolerance
                                    const edge_tangent = math.normalize(math.sub(v_end, v_start));
                                    const face_normal = g_arena.surfaceNormal(face.surface, uv_hit[0], uv_hit[1]);
                                    const sin_theta = @abs(math.dot(edge_tangent, face_normal));
                                    const dynamic_tol = @max(tol.absolute, tol.absolute / @max(sin_theta, 1e-6));
                                    // Test point inclusion against all loops (outer boundary + inner holes)
                                    if (classify.isPointInFaceUV(allocator, t_arena, g_arena, face_id, uv_hit, tol) catch false) {
                                        const hit_vec = math.sub(hit_pt, v_start);
                                        try out_events.append(allocator, .{
                                            .he_id = target_he_id,
                                            .edge_solid = solid_edges,
                                            .face_id = face_id,
                                            .pt = hit_pt,
                                            .t = math.magSq(hit_vec),
                                            .dynamic_tol = dynamic_tol,
                                        });
                                    }
                                }
                            }
                            target_he_id = edge.next;
                            if (target_he_id == t_loop.first_half_edge) break;
                        }
                    }
                }
            }
        }
    }
}

/// Iterates over face pairs between Solid A and Solid B, calculates exact SSI,
/// and topologically splits colliding faces along the intersection seam.
pub fn intersectAndSplitFaces3D(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
    faces_a: *std.ArrayListUnmanaged(topo.FaceId),
    faces_b: *std.ArrayListUnmanaged(topo.FaceId),
    tol: math.Tolerance,
) !void {
    _ = solid_a;
    _ = solid_b;
    var i_a: usize = 0;
    while (i_a < faces_a.items.len) : (i_a += 1) {
        var i_b: usize = 0;
        while (i_b < faces_b.items.len) : (i_b += 1) {
            const fa_id = faces_a.items[i_a];
            const fb_id = faces_b.items[i_b];
            const face_a = t_arena.faces.items[fa_id];
            const face_b = t_arena.faces.items[fb_id];

            // --- FREEFORM NURBS FACE COLLISION PATH ---
            if (face_a.surface.surface_type == .nurbs and face_b.surface.surface_type == .nurbs) {
                const surf_a = &g_arena.nurbs_surfaces.items[face_a.surface.index];
                const surf_b = &g_arena.nurbs_surfaces.items[face_b.surface.index];

                const seams = nurbs_ssi.findAllIntersectionSeams(allocator, surf_a, surf_b, 0.5) catch continue;
                defer {
                    for (seams) |s| {
                        allocator.free(s.points_3d);
                        allocator.free(s.uvs_a);
                        allocator.free(s.uvs_b);
                    }
                    allocator.free(seams);
                }

                for (seams) |seam| {
                    if (seam.points_3d.len < 2) continue;

                    // Slice face_a with seam.uvs_a and seam.points_3d
                    const seg = types.Segment3D{
                        .start = seam.points_3d[0],
                        .end = seam.points_3d[seam.points_3d.len - 1],
                    };

                    if (modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, fa_id, seg, tol) catch null) |new_fa| {
                        try faces_a.append(allocator, new_fa);
                    }

                    if (modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, fb_id, seg, tol) catch null) |new_fb| {
                        try faces_b.append(allocator, new_fb);
                    }
                }
                continue;
            }

            // --- ANALYTIC SURFACE COLLISION PATH ---
            const res = try intersections.intersectSurfaces(allocator, g_arena, face_a.surface, face_b.surface, tol);
            switch (res) {
                .line => |line| {
                    try modifiers.processLineCollision(allocator, t_arena, g_arena, fa_id, fb_id, line, faces_a, faces_b, tol);
                },
                .two_lines => |lines| {
                    try modifiers.processLineCollision(allocator, t_arena, g_arena, fa_id, fb_id, lines[0], faces_a, faces_b, tol);
                    try modifiers.processLineCollision(allocator, t_arena, g_arena, fa_id, fb_id, lines[1], faces_a, faces_b, tol);
                },
                else => {},
            }
        }
    }
}

pub fn computeBoolean(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
    op: BooleanOp,
    config: anytype,
) BooleanError!topo.SolidId {
    _ = config;

    var min_b = math.Vec3{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var max_b = math.Vec3{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (t_arena.vertices.items) |v| {
        min_b[0] = @min(min_b[0], v.point[0]);
        min_b[1] = @min(min_b[1], v.point[1]);
        min_b[2] = @min(min_b[2], v.point[2]);
        max_b[0] = @max(max_b[0], v.point[0]);
        max_b[1] = @max(max_b[1], v.point[1]);
        max_b[2] = @max(max_b[2], v.point[2]);
    }
    const tol = math.Tolerance.fromBoundingBox(min_b, max_b);

    var faces_a: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer faces_a.deinit(allocator);
    const s_a = t_arena.solids.items[solid_a];
    for (0..s_a.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[s_a.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            faces_a.append(allocator, t_arena.shell_faces.items[shell.faces_start + f_off]) catch {};
        }
    }

    var faces_b: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer faces_b.deinit(allocator);
    const s_b = t_arena.solids.items[solid_b];
    for (0..s_b.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[s_b.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            faces_b.append(allocator, t_arena.shell_faces.items[shell.faces_start + f_off]) catch {};
        }
    }

    // PHASE 1: COLLECT PIERCINGS (0D Nodes split 1D Edges)
    var intersection_events = std.ArrayListUnmanaged(IntersectionEvent).empty;
    defer intersection_events.deinit(allocator);

    collectPiercings(allocator, t_arena, g_arena, solid_a, solid_b, &intersection_events, tol) catch {};
    collectPiercings(allocator, t_arena, g_arena, solid_b, solid_a, &intersection_events, tol) catch {};

    std.mem.sort(IntersectionEvent, intersection_events.items, {}, struct {
        fn lessThan(_: void, lhs: IntersectionEvent, rhs: IntersectionEvent) bool {
            if (lhs.he_id == rhs.he_id) return lhs.t < rhs.t;
            return lhs.he_id < rhs.he_id;
        }
    }.lessThan);

    var active_original_he: topo.HalfEdgeId = std.math.maxInt(u32);
    var current_sub_he: topo.HalfEdgeId = 0;
    var last_split_pt: ?math.Vec3 = null;
    var face_piercings = std.AutoHashMap(topo.FaceId, std.ArrayListUnmanaged(topo.VertexId)).init(allocator);

    defer {
        var pit = face_piercings.iterator();
        while (pit.next()) |entry| entry.value_ptr.deinit(allocator);
        face_piercings.deinit();
    }

    // Inject points into edges
    for (intersection_events.items) |event| {
        if (event.he_id != active_original_he) {
            active_original_he = event.he_id;
            current_sub_he = event.he_id;
            last_split_pt = null;
        }

        if (last_split_pt) |last_pt| {
            if (math.distSq(last_pt, event.pt) < tol.squared) continue;
        }
        last_split_pt = event.pt;

        const parent_face = t_arena.loops.items[t_arena.half_edges.items[current_sub_he].loop_id].face_id;
        const twin_id = t_arena.half_edges.items[current_sub_he].twin;
        const twin_face = if (twin_id != topo.NULL_ID) t_arena.loops.items[t_arena.half_edges.items[twin_id].loop_id].face_id else null;

        const split = modifiers.splitHalfEdge(allocator, t_arena, g_arena, current_sub_he, event.pt, event.dynamic_tol) catch continue;
        current_sub_he = split.he_new;

        var res1 = face_piercings.getOrPut(event.face_id) catch continue;
        if (!res1.found_existing) res1.value_ptr.* = .empty;
        res1.value_ptr.append(allocator, split.v_mid) catch {};

        var res2 = face_piercings.getOrPut(parent_face) catch continue;
        if (!res2.found_existing) res2.value_ptr.* = .empty;
        res2.value_ptr.append(allocator, split.v_mid) catch {};

        if (twin_face) |tf| {
            var res3 = face_piercings.getOrPut(tf) catch continue;
            if (!res3.found_existing) res3.value_ptr.* = .empty;
            res3.value_ptr.append(allocator, split.v_mid) catch {};
        }
    }

    // Process nodes into either Holes (Imprints) or Edge Slices
    var face_it = face_piercings.iterator();
    while (face_it.next()) |entry| {
        const face_id = entry.key_ptr.*;
        const pts = entry.value_ptr.items;

        var source_solid: ?topo.SolidId = null;
        var target_list: ?*std.ArrayListUnmanaged(topo.FaceId) = null;

        // Find which solid this face belongs to
        for (faces_a.items) |fa| {
            if (fa == face_id) {
                source_solid = solid_a;
                target_list = &faces_a;
                break;
            }
        }
        if (source_solid == null) {
            for (faces_b.items) |fb| {
                if (fb == face_id) {
                    source_solid = solid_b;
                    target_list = &faces_b;
                    break;
                }
            }
        }
        if (source_solid == null) continue;

        if (pts.len >= 3) {
            const face = t_arena.faces.items[face_id];
            var coplanar = false;

            // Check true mathematical coplanarity
            if (face.surface.surface_type == .plane) {
                const plane = g_arena.planes.items[face.surface.index];
                coplanar = true;
                const plane_normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
                for (pts) |p_id| {
                    const pt = t_arena.vertices.items[p_id].point;
                    const dist = @abs(math.dot(plane_normal, math.sub(pt, plane.origin)));
                    if (dist > 1e-3) {
                        coplanar = false;
                        break;
                    }
                }
            }

            if (coplanar) {
                // It's a planar boundary face. Imprint the hole and plug.
                modifiers.imprintClosedLoop(allocator, t_arena, g_arena, face_id, pts, target_list.?) catch {};
            } else {
                // It is a perpendicular wall pierced multiple times. Group by Z-axis projection.
                var z_groups = std.AutoHashMap(i64, std.ArrayListUnmanaged(topo.VertexId)).init(allocator);
                const cyl = if (face.surface.surface_type == .cylinder) g_arena.cylinders.items[face.surface.index] else null;

                for (pts) |p_id| {
                    const p = t_arena.vertices.items[p_id].point;
                    var axis_proj = p[2];
                    if (cyl) |c| {
                        axis_proj = math.dot(math.sub(p, c.origin), math.normalize(c.axis));
                    }
                    const z_key = @as(i64, @intFromFloat(@round(axis_proj * 1000.0)));
                    var res = z_groups.getOrPut(z_key) catch continue;
                    if (!res.found_existing) res.value_ptr.* = .empty;
                    res.value_ptr.append(allocator, p_id) catch {};
                }

                // Track active sub-faces because sliceFace moves vertices to new face IDs
                var active_sub_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
                defer active_sub_faces.deinit(allocator);
                active_sub_faces.append(allocator, face_id) catch {};

                var zit = z_groups.iterator();
                while (zit.next()) |g| {
                    if (g.value_ptr.items.len == 2) {
                        const vA = g.value_ptr.items[0];
                        const vB = g.value_ptr.items[1];
                        var new_face_opt: ?topo.FaceId = null;

                        for (active_sub_faces.items) |sub_face| {
                            if (modifiers.sliceFace(allocator, t_arena, g_arena, sub_face, vA, vB) catch null) |new_face| {
                                new_face_opt = new_face;
                                break;
                            }
                        }
                        if (new_face_opt) |nf| {
                            active_sub_faces.append(allocator, nf) catch {};
                        }
                    }
                    g.value_ptr.deinit(allocator);
                }
                z_groups.deinit();

                for (active_sub_faces.items) |sub_face| {
                    if (sub_face != face_id) {
                        target_list.?.append(allocator, sub_face) catch {};
                    }
                }
            }
        } else if (pts.len == 2) {
            if (modifiers.sliceFace(allocator, t_arena, g_arena, face_id, pts[0], pts[1]) catch null) |new_face_id| {
                target_list.?.append(allocator, new_face_id) catch {};
            }
        }
    }

    // PHASE 2: INTERSECT FACES (1D SSI curves connect the 0D Nodes)
    intersectAndSplitFaces3D(allocator, t_arena, g_arena, solid_a, solid_b, &faces_a, &faces_b, tol) catch {};

    // PHASE 3: CLASSIFY SURVIVING FACES
    var faces_to_classify = std.ArrayListUnmanaged(FaceTracker).empty;
    defer faces_to_classify.deinit(allocator);

    var seen_a = std.AutoHashMap(topo.FaceId, void).init(allocator);
    defer seen_a.deinit();
    for (faces_a.items) |fa| {
        if (!seen_a.contains(fa)) {
            try seen_a.put(fa, {});
            try faces_to_classify.append(allocator, .{ .face = fa, .source_solid = solid_a });
        }
    }

    var seen_b = std.AutoHashMap(topo.FaceId, void).init(allocator);
    defer seen_b.deinit();
    for (faces_b.items) |fb| {
        if (!seen_b.contains(fb)) {
            try seen_b.put(fb, {});
            try faces_to_classify.append(allocator, .{ .face = fb, .source_solid = solid_b });
        }
    }

    var selected_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer selected_faces.deinit(allocator);

    for (faces_to_classify.items) |item| {
        const face_id = item.face;
        const s_id = item.source_solid;
        const target_faces = if (s_id == solid_a) faces_b.items else faces_a.items;
        const class = classify.classifyFace(allocator, t_arena, g_arena, face_id, target_faces, tol);

        const keep = if (s_id == solid_a) switch (op) {
            .union_op => class == .outside or class == .same,
            .difference => class == .outside or class == .opposite,
            .intersection => class == .inside or class == .same,
        } else switch (op) {
            .union_op => class == .outside,
            .difference => class == .inside,
            .intersection => class == .inside,
        };

        if (keep) {
            const area = classify.calculateFaceArea(t_arena, face_id);
            if (area < tol.squared) continue;

            if (s_id == solid_b and op == .difference) {
                t_arena.faces.items[face_id].forward = !t_arena.faces.items[face_id].forward;
                try modifiers.reverseFaceLoops(allocator, t_arena, face_id);
            }
            try selected_faces.append(allocator, face_id);
        }
    }

    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.appendSlice(allocator, selected_faces.items);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = @intCast(selected_faces.items.len) });

    const new_solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_start);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    try modifiers.weldSolidVertices(allocator, t_arena, new_solid_id);
    try modifiers.stitchSolidBoundaries(allocator, t_arena, new_solid_id);

    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        const validator = @import("validator.zig");
        validator.BRepSanitizer.validateSolid(allocator, t_arena, g_arena, new_solid_id, tol, .{
            .enable_checks = true,
            .check_twins = true,
            .check_linked_lists = true,
            .check_euler = false,
            .require_closed_shells = false,
            .check_coincidence = true,
            .check_degenerates = true,
        }) catch |err| {
            std.log.warn("BRepSanitizer failed after {s} operation: {s}", .{ @tagName(op), @errorName(err) });
            return error.TopologyCorrupted;
        };
    }

    return new_solid_id;
}
