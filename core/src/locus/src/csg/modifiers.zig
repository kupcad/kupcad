const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const intersections = @import("intersections.zig");
const classify = @import("classify.zig");
const types = @import("types.zig");

const MathLine = types.MathLine;
const MathCircle = types.MathCircle;
const Segment3D = types.Segment3D;

pub fn splitHalfEdge(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    he_id: topo.HalfEdgeId,
    split_pt: math.Vec3,
    split_tol: f64,
) !struct { v_mid: topo.VertexId, he_new: topo.HalfEdgeId } {
    const he = t_arena.half_edges.items[he_id];
    var twin_id = he.twin;

    // Dynamic twin lookup fallback if twins were not pre-stitched
    if (twin_id == topo.NULL_ID) {
        const v_start = he.start_vertex;
        const v_end = t_arena.half_edges.items[he.next].start_vertex;
        for (t_arena.half_edges.items, 0..) |other_he, other_idx| {
            if (other_he.start_vertex == v_end) {
                const other_next_v = t_arena.half_edges.items[other_he.next].start_vertex;
                if (other_next_v == v_start) {
                    twin_id = @intCast(other_idx);
                    t_arena.half_edges.items[he_id].twin = twin_id;
                    t_arena.half_edges.items[twin_id].twin = he_id;
                    break;
                }
            }
        }
    }

    const v_mid_id: u32 = @intCast(t_arena.vertices.items.len);
    // Apply the fat vertex tolerance
    try t_arena.vertices.append(allocator, .{
        .point = split_pt,
        .tolerance = split_tol,
    });

    const end_pt = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;

    var new_curve_id = he.curve;
    switch (he.curve.curve_type) {
        .line => {
            const l_idx: u24 = @intCast(g_arena.lines.items.len);
            try g_arena.lines.append(allocator, .{ .start = split_pt, .end = end_pt });
            g_arena.lines.items[he.curve.index].end = split_pt;
            new_curve_id = .{ .index = l_idx, .curve_type = .line };
        },
        .circle_arc => {
            const arc_idx: u24 = @intCast(g_arena.circle_arcs.items.len);
            try g_arena.circle_arcs.append(allocator, g_arena.circle_arcs.items[he.curve.index]);
            new_curve_id = .{ .index = arc_idx, .curve_type = .circle_arc };
        },
        .nurbs => {
            const n_idx: u24 = @intCast(g_arena.nurbs_curves.items.len);
            try g_arena.nurbs_curves.append(allocator, g_arena.nurbs_curves.items[he.curve.index]);
            new_curve_id = .{ .index = n_idx, .curve_type = .nurbs };
        },
    }

    const he_new_id: u32 = @intCast(t_arena.half_edges.items.len);
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_mid_id,
        .twin = topo.NULL_ID,
        .next = he.next,
        .prev = he_id,
        .loop_id = he.loop_id,
        .curve = new_curve_id,
        .forward = he.forward,
    });

    t_arena.half_edges.items[he.next].prev = he_new_id;
    t_arena.half_edges.items[he_id].next = he_new_id;

    if (twin_id != topo.NULL_ID) {
        const twin = t_arena.half_edges.items[twin_id];
        var twin_new_curve_id = twin.curve;
        switch (twin.curve.curve_type) {
            .line => {
                const l_idx: u24 = @intCast(g_arena.lines.items.len);
                try g_arena.lines.append(allocator, .{ .start = split_pt, .end = t_arena.vertices.items[twin.start_vertex].point });
                g_arena.lines.items[twin.curve.index].end = split_pt;
                twin_new_curve_id = .{ .index = l_idx, .curve_type = .line };
            },
            .circle_arc => {
                const arc_idx: u24 = @intCast(g_arena.circle_arcs.items.len);
                try g_arena.circle_arcs.append(allocator, g_arena.circle_arcs.items[twin.curve.index]);
                twin_new_curve_id = .{ .index = arc_idx, .curve_type = .circle_arc };
            },
            .nurbs => {
                const n_idx: u24 = @intCast(g_arena.nurbs_curves.items.len);
                try g_arena.nurbs_curves.append(allocator, g_arena.nurbs_curves.items[twin.curve.index]);
                twin_new_curve_id = .{ .index = n_idx, .curve_type = .nurbs };
            },
        }

        const twin_new_id: u32 = @intCast(t_arena.half_edges.items.len);
        try t_arena.half_edges.append(allocator, .{
            .start_vertex = v_mid_id,
            .twin = he_id,
            .next = twin.next,
            .prev = twin_id,
            .loop_id = twin.loop_id,
            .curve = twin_new_curve_id,
            .forward = twin.forward,
        });

        t_arena.half_edges.items[twin.next].prev = twin_new_id;
        t_arena.half_edges.items[twin_id].next = twin_new_id;

        t_arena.half_edges.items[he_id].twin = twin_new_id;
        t_arena.half_edges.items[he_new_id].twin = twin_id;
        t_arena.half_edges.items[twin_id].twin = he_new_id;
    }

    return .{ .v_mid = v_mid_id, .he_new = he_new_id };
}

pub fn sliceFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    v_a: topo.VertexId,
    v_b: topo.VertexId,
) !?topo.FaceId {
    const face = t_arena.faces.items[face_id];
    if (face.loops_len != 1) return null;

    const loop_id = t_arena.face_loops.items[face.loops_start];
    const loop = t_arena.loops.items[loop_id];

    var he_a: ?topo.HalfEdgeId = null;
    var he_b: ?topo.HalfEdgeId = null;

    // Atomic traversal without safety counters
    var curr = loop.first_half_edge;
    while (true) {
        const he = t_arena.half_edges.items[curr];
        if (he.start_vertex == v_a) he_a = curr;
        if (he.start_vertex == v_b) he_b = curr;
        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }

    if (he_a == null or he_b == null or he_a.? == he_b.?) return null;

    const prev_a = t_arena.half_edges.items[he_a.?].prev;
    const prev_b = t_arena.half_edges.items[he_b.?].prev;
    if (prev_a == he_b.? or prev_b == he_a.?) return null;

    const l_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{
        .start = t_arena.vertices.items[v_a].point,
        .end = t_arena.vertices.items[v_b].point,
    });
    const curve_id = geom.CurveId{ .index = l_idx, .curve_type = .line };

    const h1_id: u32 = @intCast(t_arena.half_edges.items.len);
    const h2_id: u32 = h1_id + 1;

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_a,
        .twin = h2_id,
        .next = he_b.?,
        .prev = prev_a,
        .loop_id = loop_id,
        .curve = curve_id,
        .forward = true,
    });

    const new_loop_id: u32 = @intCast(t_arena.loops.items.len);
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_b,
        .twin = h1_id,
        .next = he_a.?,
        .prev = prev_b,
        .loop_id = new_loop_id,
        .curve = curve_id,
        .forward = false,
    });

    t_arena.half_edges.items[prev_a].next = h1_id;
    t_arena.half_edges.items[he_b.?].prev = h1_id;

    t_arena.half_edges.items[prev_b].next = h2_id;
    t_arena.half_edges.items[he_a.?].prev = h2_id;

    const new_face_id: u32 = @intCast(t_arena.faces.items.len);
    curr = h2_id;
    while (true) {
        t_arena.half_edges.items[curr].loop_id = new_loop_id;
        curr = t_arena.half_edges.items[curr].next;
        if (curr == h2_id) break;
    }

    try t_arena.loops.append(allocator, .{ .face_id = new_face_id, .first_half_edge = h2_id });
    const new_fl_start: u32 = @intCast(t_arena.face_loops.items.len);
    try t_arena.face_loops.append(allocator, new_loop_id);

    try t_arena.faces.append(allocator, .{
        .surface = face.surface,
        .forward = face.forward,
        .loops_start = new_fl_start,
        .loops_len = 1,
    });
    t_arena.loops.items[loop_id].first_half_edge = h1_id;
    return new_face_id;
}

/// Slices a face along a finite 3D line segment by splitting boundary edges and calling sliceFace.
pub fn sliceFaceWithSegment(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    segment: Segment3D,
    tol: math.Tolerance,
) !?topo.FaceId {
    const face = t_arena.faces.items[face_id];
    if (face.loops_len != 1) return null; // Single loop faces only for now

    const loop_id = t_arena.face_loops.items[face.loops_start];

    const v_a = try getOrSplitVertexAtPoint(allocator, t_arena, g_arena, loop_id, segment.start, tol) orelse return null;
    const v_b = try getOrSplitVertexAtPoint(allocator, t_arena, g_arena, loop_id, segment.end, tol) orelse return null;

    if (v_a == v_b) return null;

    return try sliceFace(allocator, t_arena, g_arena, face_id, v_a, v_b);
}

/// Finds an existing vertex or splits a half-edge at a given 3D point along a loop.
fn getOrSplitVertexAtPoint(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    loop_id: topo.LoopId,
    pt: math.Vec3,
    tol: math.Tolerance,
) !?topo.VertexId {
    const loop = t_arena.loops.items[loop_id];
    var curr = loop.first_half_edge;
    var safety: usize = 0;

    // 1. Strict spatial snapping pass to prevent degenerate micro-edges
    var snap_curr = loop.first_half_edge;
    var snap_safety: usize = 0;
    while (true) : (snap_safety += 1) {
        if (snap_safety > 10_000) return error.TopologyCorrupted;
        const he = t_arena.half_edges.items[snap_curr];
        const v_start = he.start_vertex;
        const p_start = t_arena.vertices.items[v_start].point;

        if (math.distSq(p_start, pt) < tol.absolute * tol.absolute) return v_start;

        snap_curr = he.next;
        if (snap_curr == loop.first_half_edge) break;
    }

    // 2. Projection and split pass
    while (true) : (safety += 1) {
        if (safety > 10_000) return error.TopologyCorrupted;

        const he = t_arena.half_edges.items[curr];
        const v_start = he.start_vertex;
        const p_start = t_arena.vertices.items[v_start].point;

        const p_end = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;
        const v_seg = math.sub(p_end, p_start);
        const len_sq = math.magSq(v_seg);

        if (len_sq > math.MATH_EPSILON) {
            const proj = math.dot(math.sub(pt, p_start), v_seg) / len_sq;
            if (proj > tol.parametric and proj < 1.0 - tol.parametric) {
                const closest = math.add(p_start, math.scale(v_seg, proj));
                if (math.distSq(pt, closest) < tol.absolute * tol.absolute) {
                    const split = try splitHalfEdge(allocator, t_arena, g_arena, curr, pt, tol.absolute);
                    return split.v_mid;
                }
            }
        }

        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }

    return null;
}

/// Replaces punchHole. Instead of destroying the face, this "imprints" the intersection.
/// It creates a perfectly twinned Inner Plug face and Outer Hole boundary.
pub fn imprintClosedLoop(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    pts: []const topo.VertexId,
    faces_list: *std.ArrayListUnmanaged(topo.FaceId),
) !void {
    const face = t_arena.faces.items[face_id];
    if (face.surface.surface_type != .plane) return;

    const plane = g_arena.planes.items[face.surface.index];
    var centroid_uv = [2]f64{ 0, 0 };
    for (pts) |v_id| {
        const uv = classify.projectToPlane(t_arena.vertices.items[v_id].point, plane.origin, plane.u_axis, plane.v_axis);
        centroid_uv[0] += uv[0];
        centroid_uv[1] += uv[1];
    }
    centroid_uv[0] /= @as(f64, @floatFromInt(pts.len));
    centroid_uv[1] /= @as(f64, @floatFromInt(pts.len));

    const SortPoint = struct { v_id: topo.VertexId, angle: f64 };
    var sorted = try allocator.alloc(SortPoint, pts.len);
    defer allocator.free(sorted);
    for (pts, 0..) |v_id, i| {
        const uv = classify.projectToPlane(t_arena.vertices.items[v_id].point, plane.origin, plane.u_axis, plane.v_axis);
        sorted[i] = .{ .v_id = v_id, .angle = std.math.atan2(uv[1] - centroid_uv[1], uv[0] - centroid_uv[0]) };
    }

    std.mem.sort(SortPoint, sorted, {}, struct {
        fn lessThan(_: void, a: SortPoint, b: SortPoint) bool {
            // Sort CCW for the plug (which makes the hole naturally CW)
            return a.angle < b.angle;
        }
    }.lessThan);

    const plug_loop_id: u32 = @intCast(t_arena.loops.items.len);
    const hole_loop_id: u32 = plug_loop_id + 1;
    const he_start: u32 = @intCast(t_arena.half_edges.items.len);
    const n = sorted.len;

    // 1. Build the Inner Plug Face Boundary (CCW)
    for (0..n) |i| {
        const v_start = sorted[i].v_id;
        const v_end = sorted[(i + 1) % n].v_id;
        const line_idx: u24 = @intCast(g_arena.lines.items.len);
        try g_arena.lines.append(allocator, .{ .start = t_arena.vertices.items[v_start].point, .end = t_arena.vertices.items[v_end].point });

        try t_arena.half_edges.append(allocator, .{
            .start_vertex = v_start,
            .twin = he_start + @as(u32, @intCast(n + i)), // Twin to the hole edge!
            .next = he_start + @as(u32, @intCast((i + 1) % n)),
            .prev = he_start + @as(u32, @intCast((i + n - 1) % n)),
            .loop_id = plug_loop_id,
            .curve = .{ .index = line_idx, .curve_type = .line },
            .forward = true,
        });
    }

    // 2. Build the Parent Face's Hole Boundary (CW)
    for (0..n) |i| {
        const v_start = sorted[(i + 1) % n].v_id; // Reversed for CW

        try t_arena.half_edges.append(allocator, .{
            .start_vertex = v_start,
            .twin = he_start + @as(u32, @intCast(i)), // Twin to the plug edge!
            .next = he_start + @as(u32, @intCast(n + ((i + n - 1) % n))),
            .prev = he_start + @as(u32, @intCast(n + ((i + 1) % n))),
            .loop_id = hole_loop_id,
            .curve = t_arena.half_edges.items[he_start + i].curve,
            .forward = false,
        });
    }

    // 3. Register the newly created Plug Face
    const plug_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.loops.append(allocator, .{ .face_id = plug_face_id, .first_half_edge = he_start });
    try t_arena.loops.append(allocator, .{ .face_id = face_id, .first_half_edge = he_start + @as(u32, @intCast(n)) });

    const plug_fl_start: u32 = @intCast(t_arena.face_loops.items.len);
    try t_arena.face_loops.append(allocator, plug_loop_id);
    try t_arena.faces.append(allocator, .{
        .surface = face.surface,
        .forward = face.forward,
        .loops_start = plug_fl_start,
        .loops_len = 1,
    });
    // Add the plug to the active tracking list so it gets ray-cast evaluated!
    try faces_list.append(allocator, plug_face_id);

    // 4. Mutate the Parent Face to absorb the new hole loop
    var mutable_face = &t_arena.faces.items[face_id];
    const old_start = mutable_face.loops_start;
    const old_len = mutable_face.loops_len;
    const new_start: u32 = @intCast(t_arena.face_loops.items.len);

    for (0..old_len) |j| {
        try t_arena.face_loops.append(allocator, t_arena.face_loops.items[old_start + j]);
    }
    try t_arena.face_loops.append(allocator, hole_loop_id);

    mutable_face.loops_start = new_start;
    mutable_face.loops_len = old_len + 1;
}

/// Welds coincident vertices within a solid to stitch topological seams.
pub fn weldSolidVertices(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    solid_id: topo.SolidId,
) !void {
    const solid = t_arena.solids.items[solid_id];
    var active_verts = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer active_verts.deinit();

    for (0..solid.shells_len) |s_off| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_off];
        const shell = t_arena.shells.items[shell_id];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];
            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];
                var curr_he = loop.first_half_edge;
                var safety: usize = 0;
                while (true) : (safety += 1) {
                    if (safety > 10_000) return error.TopologyCorrupted;
                    const he = t_arena.half_edges.items[curr_he];
                    try active_verts.put(he.start_vertex, {});
                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }

    const VertexData = struct { id: topo.VertexId, rep: topo.VertexId };
    var v_list = std.ArrayListUnmanaged(VertexData).empty;
    defer v_list.deinit(allocator);

    var it = active_verts.keyIterator();
    while (it.next()) |v_id| {
        try v_list.append(allocator, .{ .id = v_id.*, .rep = v_id.* });
    }

    // RESTORED: Strict geometric tolerance to prevent VertexNotOnSurface errors
    for (0..v_list.items.len) |i| {
        if (v_list.items[i].rep != v_list.items[i].id) continue;
        const v1 = t_arena.vertices.items[v_list.items[i].id];

        for (i + 1..v_list.items.len) |j| {
            if (v_list.items[j].rep != v_list.items[j].id) continue;
            const v2 = t_arena.vertices.items[v_list.items[j].id];

            if (math.entitiesCoincide(v1.point, v1.tolerance, v2.point, v2.tolerance)) {
                v_list.items[j].rep = v_list.items[i].id;
            }
        }
    }

    var replacement_map = std.AutoHashMap(topo.VertexId, topo.VertexId).init(allocator);
    defer replacement_map.deinit();
    for (v_list.items) |vd| {
        if (vd.id != vd.rep) try replacement_map.put(vd.id, vd.rep);
    }
    if (replacement_map.count() == 0) return;

    for (0..solid.shells_len) |s_off| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_off];
        const shell = t_arena.shells.items[shell_id];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];
            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = &t_arena.loops.items[loop_id];
                var curr_he = loop.first_half_edge;
                var safety: usize = 0;
                while (true) : (safety += 1) {
                    if (safety > 10_000) return error.TopologyCorrupted;
                    const he = &t_arena.half_edges.items[curr_he];
                    if (replacement_map.get(he.start_vertex)) |new_id| {
                        he.start_vertex = new_id;
                    }
                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }

    for (0..solid.shells_len) |s_off| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_off];
        const shell = t_arena.shells.items[shell_id];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];
            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = &t_arena.loops.items[loop_id];

                var removed_any = true;
                var safety_outer: usize = 0;
                while (removed_any) : (safety_outer += 1) {
                    if (safety_outer > 1000) return error.TopologyCorrupted;
                    removed_any = false;
                    var curr_id = loop.first_half_edge;
                    const start_id = curr_id;
                    var safety: usize = 0;

                    while (true) : (safety += 1) {
                        if (safety > 10_000) return error.TopologyCorrupted;
                        const he = t_arena.half_edges.items[curr_id];
                        const next_id = he.next;
                        const next_he = t_arena.half_edges.items[next_id];

                        if (he.start_vertex == next_he.start_vertex) {
                            if (next_id == curr_id) break;

                            const prev_id = he.prev;
                            t_arena.half_edges.items[prev_id].next = next_id;
                            t_arena.half_edges.items[next_id].prev = prev_id;

                            if (loop.first_half_edge == curr_id) {
                                loop.first_half_edge = next_id;
                            }
                            curr_id = next_id;
                            removed_any = true;
                            break;
                        }
                        curr_id = next_id;
                        if (curr_id == start_id) break;
                    }
                }
            }
        }
    }
}

/// Projects an infinite 3D line into the 2D surface of a Face and clips it against the boundary loops.
/// Returns a list of finite 3D segments that represent exactly where the line sits inside the face.
pub fn clipMathLineToFace(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    face_id: topo.FaceId,
    line: MathLine,
    tol: math.Tolerance,
) ![]Segment3D {
    const face = t_arena.faces.items[face_id];

    // Fallback: we only clip planar faces for now.
    if (face.surface.surface_type != .plane) return &[_]Segment3D{};

    const plane = g_arena.planes.items[face.surface.index];

    // Project infinite 3D line down to a 2D line on the plane
    const o_2d = classify.projectToPlane(line.origin, plane.origin, plane.u_axis, plane.v_axis);
    const pt2_2d = classify.projectToPlane(math.add(line.origin, line.direction), plane.origin, plane.u_axis, plane.v_axis);
    const d_2d = [2]f64{ pt2_2d[0] - o_2d[0], pt2_2d[1] - o_2d[1] };

    var t_vals: std.ArrayListUnmanaged(f64) = .empty;
    defer t_vals.deinit(allocator);

    // Cast the infinite line against every bounding half-edge of the face
    for (0..face.loops_len) |l_off| {
        const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
        const loop = t_arena.loops.items[loop_id];
        var curr_he = loop.first_half_edge;
        while (true) {
            const he = t_arena.half_edges.items[curr_he];
            const p1 = t_arena.vertices.items[he.start_vertex].point;
            const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;

            const p1_2d = classify.projectToPlane(p1, plane.origin, plane.u_axis, plane.v_axis);
            const p2_2d = classify.projectToPlane(p2, plane.origin, plane.u_axis, plane.v_axis);

            if (intersections.intersectInfiniteLineSegment2D(o_2d, d_2d, p1_2d, p2_2d, tol)) |t_hit| {
                try t_vals.append(allocator, t_hit);
            }

            curr_he = he.next;
            if (curr_he == loop.first_half_edge) break;
        }
    }

    if (t_vals.items.len < 2) return &[_]Segment3D{};

    // Sort crossing points by distance along the line
    std.mem.sort(f64, t_vals.items, {}, struct {
        fn lessThan(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.lessThan);

    // Deduplicate identical hits (e.g., ray passed exactly through a vertex sharing two edges)
    var deduped: std.ArrayListUnmanaged(f64) = .empty;
    defer deduped.deinit(allocator);
    for (t_vals.items) |t| {
        if (deduped.items.len == 0 or @abs(deduped.items[deduped.items.len - 1] - t) > tol.parametric) {
            try deduped.append(allocator, t);
        }
    }

    // Pair up entry/exit points to create finite internal segments
    var segments: std.ArrayListUnmanaged(Segment3D) = .empty;
    var i: usize = 0;
    while (i + 1 < deduped.items.len) : (i += 2) {
        const t_start = deduped.items[i];
        const t_end = deduped.items[i + 1];

        const p_start = math.add(line.origin, math.scale(line.direction, t_start));
        const p_end = math.add(line.origin, math.scale(line.direction, t_end));
        try segments.append(allocator, .{ .start = p_start, .end = p_end });
    }

    return segments.toOwnedSlice(allocator);
}

/// Computes the 3D sub-segments where two sets of 3D segments overlap along an infinite line.
pub fn overlapSegments3D(
    allocator: std.mem.Allocator,
    line: MathLine,
    segs_a: []const Segment3D,
    segs_b: []const Segment3D,
    tol: math.Tolerance,
) ![]Segment3D {
    var common: std.ArrayListUnmanaged(Segment3D) = .empty;
    errdefer common.deinit(allocator);

    const dir_norm = math.normalize(line.direction);

    for (segs_a) |sa| {
        const ta1 = math.dot(math.sub(sa.start, line.origin), dir_norm);
        const ta2 = math.dot(math.sub(sa.end, line.origin), dir_norm);
        const ta_min = @min(ta1, ta2);
        const ta_max = @max(ta1, ta2);

        for (segs_b) |sb| {
            const tb1 = math.dot(math.sub(sb.start, line.origin), dir_norm);
            const tb2 = math.dot(math.sub(sb.end, line.origin), dir_norm);
            const tb_min = @min(tb1, tb2);
            const tb_max = @max(tb1, tb2);

            const t_start = @max(ta_min, tb_min);
            const t_end = @min(ta_max, tb_max);

            if (t_start < t_end - tol.parametric) {
                const p_start = math.add(line.origin, math.scale(dir_norm, t_start));
                const p_end = math.add(line.origin, math.scale(dir_norm, t_end));
                try common.append(allocator, .{ .start = p_start, .end = p_end });
            }
        }
    }

    return common.toOwnedSlice(allocator);
}

/// Helper to clip a 3D MathLine against two faces and slice them along any overlapping segments.
pub fn processLineCollision(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    fa_id: topo.FaceId,
    fb_id: topo.FaceId,
    line: MathLine,
    faces_a: *std.ArrayListUnmanaged(topo.FaceId),
    faces_b: *std.ArrayListUnmanaged(topo.FaceId),
    tol: math.Tolerance,
) !void {
    const segs_a = try clipMathLineToFace(allocator, t_arena, g_arena, fa_id, line, tol);
    defer allocator.free(segs_a);

    const segs_b = try clipMathLineToFace(allocator, t_arena, g_arena, fb_id, line, tol);
    defer allocator.free(segs_b);

    const overlaps = try overlapSegments3D(allocator, line, segs_a, segs_b, tol);
    defer allocator.free(overlaps);

    if (overlaps.len > 0) {
        for (segs_a) |sa| {
            if (try sliceFaceWithSegment(allocator, t_arena, g_arena, fa_id, sa, tol)) |new_f| {
                try faces_a.append(allocator, new_f);
            }
        }
        for (segs_b) |sb| {
            if (try sliceFaceWithSegment(allocator, t_arena, g_arena, fb_id, sb, tol)) |new_f| {
                try faces_b.append(allocator, new_f);
            }
        }
    }
}

/// Slices faces along 3D polyline curves resulting from surface intersections
fn processSampledCollision(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    fa_id: topo.FaceId,
    fb_id: topo.FaceId,
    pts: []const math.Vec3,
    faces_a: *std.ArrayListUnmanaged(topo.FaceId),
    faces_b: *std.ArrayListUnmanaged(topo.FaceId),
    tol: math.Tolerance,
) !void {
    if (pts.len < 2) return;

    // Snap polyline vertices to any existing topological vertices within a loose
    // bounding tolerance to bridge sampled SSI curves to exact analytical boundaries.
    var snapped_pts = try allocator.alloc(math.Vec3, pts.len);
    defer allocator.free(snapped_pts);

    const snap_sq = 1.0; // 1.0mm sq radius to catch sampled ellipse endpoints

    for (pts, 0..) |pt, i| {
        var best_pt = pt;
        var min_d_sq: f64 = snap_sq;

        for (t_arena.vertices.items) |v| {
            const d_sq = math.distSq(pt, v.point);
            if (d_sq < min_d_sq) {
                min_d_sq = d_sq;
                best_pt = v.point;
            }
        }
        snapped_pts[i] = best_pt;
    }

    for (0..snapped_pts.len - 1) |i| {
        // Skip degenerate segments caused by snapping
        if (math.distSq(snapped_pts[i], snapped_pts[i + 1]) < tol.squared) continue;

        const seg = Segment3D{ .start = snapped_pts[i], .end = snapped_pts[i + 1] };
        if (try sliceFaceWithSegment(allocator, t_arena, g_arena, fa_id, seg, tol)) |new_f| {
            try faces_a.append(allocator, new_f);
        }
        if (try sliceFaceWithSegment(allocator, t_arena, g_arena, fb_id, seg, tol)) |new_f| {
            try faces_b.append(allocator, new_f);
        }
    }
}

/// Discretizes a 3D intersection circle into a polyline and slices colliding faces
fn processCircleCollision(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    fa_id: topo.FaceId,
    fb_id: topo.FaceId,
    circle: MathCircle,
    faces_a: *std.ArrayListUnmanaged(topo.FaceId),
    faces_b: *std.ArrayListUnmanaged(topo.FaceId),
    tol: math.Tolerance,
) !void {
    const samples: usize = 32;
    var pts = try allocator.alloc(math.Vec3, samples + 1);
    defer allocator.free(pts);

    const tau = 2.0 * std.math.pi;
    for (0..samples) |i| {
        const theta = tau * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples));
        const radial = math.add(
            math.scale(circle.x_axis, circle.radius * @cos(theta)),
            math.scale(circle.y_axis, circle.radius * @sin(theta)),
        );
        pts[i] = math.add(circle.center, radial);
    }
    pts[samples] = pts[0]; // Close circle loop

    try processSampledCollision(allocator, t_arena, g_arena, fa_id, fb_id, pts, faces_a, faces_b, tol);
}

/// Evaluates point inclusion against closed boundaries using first-hit normal orientation and multi-ray voting.
/// Utilizes a transient AABB cache to accelerate raycasting from O(N) face checks to O(log N) fast-slab rejections.
pub fn reverseFaceLoops(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    face_id: topo.FaceId,
) !void {
    const face = t_arena.faces.items[face_id];
    for (0..face.loops_len) |l_off| {
        const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
        const loop = t_arena.loops.items[loop_id];

        var curr = loop.first_half_edge;
        var edges = std.ArrayListUnmanaged(topo.HalfEdgeId).empty;
        defer edges.deinit(allocator);

        while (true) {
            try edges.append(allocator, curr);
            curr = t_arena.half_edges.items[curr].next;
            if (curr == loop.first_half_edge) break;
        }

        var verts = std.ArrayListUnmanaged(topo.VertexId).empty;
        defer verts.deinit(allocator);
        for (edges.items) |e| {
            try verts.append(allocator, t_arena.half_edges.items[e].start_vertex);
        }

        const n = edges.items.len;
        for (0..n) |i| {
            const e = edges.items[i];
            const prev_e = edges.items[(i + 1) % n]; // Old next becomes new prev
            const next_e = edges.items[(i + n - 1) % n]; // Old prev becomes new next

            var he = &t_arena.half_edges.items[e];
            he.next = next_e;
            he.prev = prev_e;
            he.start_vertex = verts.items[(i + 1) % n]; // Shift start vertex forward
            he.forward = !he.forward;
        }
    }
}

/// Crawls a newly created shell, cross-links half-edge twin pointers across Boolean seams,
/// and locks exact UV parameters for freeform boundary evaluation.
pub fn stitchSolidBoundaries(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *const geom.GeometryArena, // ADDED: Required for UV projection
    solid_id: topo.SolidId,
) !void {
    const EdgeKey = struct { start: topo.VertexId, end: topo.VertexId };
    var unmatched = std.AutoHashMap(EdgeKey, topo.HalfEdgeId).init(allocator);
    defer unmatched.deinit();

    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_off];
        const shell = t_arena.shells.items[shell_id];

        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];

            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];

                var curr_he = loop.first_half_edge;
                var safety: usize = 0;
                while (true) : (safety += 1) {
                    if (safety > 10_000) return error.TopologyCorrupted;

                    const he = &t_arena.half_edges.items[curr_he];
                    const next_he = t_arena.half_edges.items[he.next];

                    const v_start = he.start_vertex;
                    const v_end = next_he.start_vertex;

                    // PROJECT UV PARAMETERS:
                    // Force the half-edge to lock its 2D p-curve coordinate based on the final welded 3D vertex.
                    const pt3d = t_arena.vertices.items[v_start].point;
                    const uv = g_arena.surfaceProject(face.surface, pt3d);
                    he.start_uv = .{ uv[0], uv[1] };

                    const opp_key = EdgeKey{ .start = v_end, .end = v_start };
                    if (unmatched.get(opp_key)) |twin_id| {
                        he.twin = twin_id;
                        t_arena.half_edges.items[twin_id].twin = curr_he;
                        _ = unmatched.remove(opp_key);
                    } else {
                        he.twin = topo.NULL_ID;
                        try unmatched.put(EdgeKey{ .start = v_start, .end = v_end }, curr_he);
                    }

                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }
}

/// Topologically injects a closed mathematical circle into an existing face as an inner boundary (hole).
pub fn injectCircularHole(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    circle: MathCircle,
    tol: math.Tolerance,
) !void {
    _ = tol;

    // 1. Store the exact 3D geometry of the circular seam
    const arc_idx: u24 = @intCast(g_arena.circle_arcs.items.len);
    try g_arena.circle_arcs.append(allocator, .{
        .center = circle.center,
        .radius = circle.radius,
        .x_axis = circle.x_axis,
        .y_axis = circle.y_axis,
    });
    const curve_id = geom.CurveId{ .index = arc_idx, .curve_type = .circle_arc };

    // 2. Break the continuous loop into two topological half-edges to form a valid manifold cycle.
    // Vertex 1 at 0 degrees, Vertex 2 at 180 degrees.
    const p1 = math.add(circle.center, math.scale(circle.x_axis, circle.radius));
    const p2 = math.add(circle.center, math.scale(circle.x_axis, -circle.radius));

    const v1_id: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(allocator, .{ .point = p1 });

    const v2_id: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(allocator, .{ .point = p2 });

    const loop_id: u32 = @intCast(t_arena.loops.items.len);
    const he_start: u32 = @intCast(t_arena.half_edges.items.len);

    // 3. Winding Order: Holes must be wound backward relative to the outer boundary.
    // We set forward = false to designate this as a subtractive inner loop.
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v1_id,
        .twin = topo.NULL_ID,
        .next = he_start + 1,
        .prev = he_start + 1,
        .loop_id = loop_id,
        .curve = curve_id,
        .forward = false,
    });

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v2_id,
        .twin = topo.NULL_ID,
        .next = he_start,
        .prev = he_start,
        .loop_id = loop_id,
        .curve = curve_id,
        .forward = false,
    });

    // 4. Register the new inner loop
    try t_arena.loops.append(allocator, .{
        .face_id = face_id,
        .first_half_edge = he_start,
    });

    // 5. Safely attach the new loop to the existing Face.
    // Because Face loop arrays are flat contiguous slices, we copy the old ones
    // to the end of the arena and append the new one.
    var mutable_face = &t_arena.faces.items[face_id];
    const old_start = mutable_face.loops_start;
    const old_len = mutable_face.loops_len;
    const new_start: u32 = @intCast(t_arena.face_loops.items.len);

    for (0..old_len) |i| {
        try t_arena.face_loops.append(allocator, t_arena.face_loops.items[old_start + i]);
    }
    try t_arena.face_loops.append(allocator, loop_id);

    mutable_face.loops_start = new_start;
    mutable_face.loops_len = old_len + 1;
}

/// Scans the shell for the sharp corner vertex, verifies it is flanked by the fillet's
/// cap vertices, severs the 90-degree corner, and sews a transversal arc matching the fillet.
pub fn trimOrthogonalCap(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    solid_id: topo.SolidId,
    v_corner: topo.VertexId,
    cap_he: topo.HalfEdgeId,
) !void {
    const solid = t_arena.solids.items[solid_id];
    const shell_id = t_arena.solid_shells.items[solid.shells_start];
    const shell = t_arena.shells.items[shell_id];

    const cap_v_start = t_arena.half_edges.items[cap_he].start_vertex;
    const cap_v_end = t_arena.half_edges.items[t_arena.half_edges.items[cap_he].next].start_vertex;

    var corner_found_in_shell = false;

    for (0..shell.faces_len) |f_off| {
        const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
        const face = t_arena.faces.items[face_id];

        for (0..face.loops_len) |l_off| {
            const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
            const loop = &t_arena.loops.items[loop_id];

            var curr = loop.first_half_edge;
            var safety: usize = 0;
            while (true) : (safety += 1) {
                if (safety > 10_000) return error.TopologyCorrupted;

                const he = t_arena.half_edges.items[curr];

                if (he.start_vertex == v_corner) {
                    corner_found_in_shell = true;

                    const he_prev = t_arena.half_edges.items[he.prev];
                    const prev_v = he_prev.start_vertex;

                    const he_next = t_arena.half_edges.items[he.next];
                    const next_v = he_next.start_vertex;

                    if ((prev_v == cap_v_start and next_v == cap_v_end) or
                        (prev_v == cap_v_end and next_v == cap_v_start))
                    {
                        const new_he_id: u32 = @intCast(t_arena.half_edges.items.len);

                        try t_arena.half_edges.append(allocator, .{
                            .start_vertex = he_prev.start_vertex,
                            .twin = cap_he,
                            .next = he.next,
                            .prev = he_prev.prev,
                            .loop_id = loop_id,
                            .curve = t_arena.half_edges.items[cap_he].curve,
                            .forward = !t_arena.half_edges.items[cap_he].forward,
                        });

                        t_arena.half_edges.items[he_prev.prev].next = new_he_id;
                        t_arena.half_edges.items[he.next].prev = new_he_id;
                        t_arena.half_edges.items[cap_he].twin = new_he_id;

                        if (loop.first_half_edge == curr or loop.first_half_edge == he.prev) {
                            loop.first_half_edge = new_he_id;
                        }

                        return;
                    }
                }

                curr = he.next;
                if (curr == loop.first_half_edge) break;
            }
        }
    }

    if (corner_found_in_shell) {
        return error.TopologyCorrupted;
    }
}
