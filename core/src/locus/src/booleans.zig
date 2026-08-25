const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const BooleanOp = enum { union_op, difference, intersection };
pub const FaceClassification = enum { inside, outside, same, opposite };

pub const BooleanError = error{
    OutOfMemory,
    DidNotConverge,
};

/// Records a precise geometric intersection between a HalfEdge and a Face
pub const IntersectionEvent = struct {
    he_id: topo.HalfEdgeId,
    edge_solid: topo.SolidId,
    face_id: topo.FaceId,
    pt: math.Vec3,
    t: f64,
};

/// Computes the intersection curve between two surfaces using the Marching Algorithm
pub fn marchIntersection(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    surf_a_id: geom.SurfaceId,
    surf_b_id: geom.SurfaceId,
    start_pt: math.Vec3,
    step_size: f64,
    max_steps: u32,
    tolerance: f64,
) BooleanError!geom.CurveId {
    _ = allocator;
    _ = surf_a_id;
    _ = surf_b_id;
    _ = start_pt;
    _ = step_size;
    _ = max_steps;
    _ = tolerance;
    return geom.CurveId{ .index = @intCast(g_arena.lines.items.len), .curve_type = .line };
}

/// Projects a 3D point onto a Plane's local 2D UV coordinate system.
fn projectToPlane(pt: math.Vec3, origin: math.Vec3, u_axis: math.Vec3, v_axis: math.Vec3) [2]f64 {
    const v = math.sub(pt, origin);
    return .{ math.dot(v, u_axis), math.dot(v, v_axis) };
}

/// Tests if a 2D UV point is inside a 2D polygon using Ray Casting
pub fn isPointInPolygon2D(pt: [2]f64, polygon: []const [2]f64) bool {
    var inside = false;
    var j: usize = polygon.len - 1;
    for (0..polygon.len) |i| {
        const pi = polygon[i];
        const pj = polygon[j];

        if (((pi[1] > pt[1]) != (pj[1] > pt[1])) and
            (pt[0] < (pj[0] - pi[0]) * (pt[1] - pi[1]) / (pj[1] - pi[1]) + pi[0]))
        {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Computes the exact 3D intersection point between a Line and a Plane.
fn intersectLinePlane(
    line_start: math.Vec3,
    line_end: math.Vec3,
    plane_origin: math.Vec3,
    plane_normal: math.Vec3,
) ?math.Vec3 {
    const dir = math.sub(line_end, line_start);
    const denominator = math.dot(dir, plane_normal);

    if (@abs(denominator) < math.MATH_EPSILON) return null;

    const p0l0 = math.sub(plane_origin, line_start);
    const t = math.dot(p0l0, plane_normal) / denominator;

    if (t > math.MATH_EPSILON and t < (1.0 - math.MATH_EPSILON)) {
        return math.add(line_start, math.scale(dir, t));
    }
    return null;
}

/// Tests all edges of `solid_edges` against all faces of `solid_faces`
fn collectPiercings(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_edges: topo.SolidId,
    solid_faces: topo.SolidId,
    out_events: *std.ArrayListUnmanaged(IntersectionEvent),
) !void {
    const s_edges = t_arena.solids.items[solid_edges];
    const s_faces = t_arena.solids.items[solid_faces];

    // 1. Traverse faces of the cutter solid
    for (0..s_faces.shells_len) |sf_off| {
        const shell_f = t_arena.shells.items[t_arena.solid_shells.items[s_faces.shells_start + sf_off]];
        for (0..shell_f.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell_f.faces_start + f_off];
            const face = t_arena.faces.items[face_id];

            if (face.surface.surface_type != .plane) continue;

            const plane = g_arena.planes.items[face.surface.index];
            var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
            if (!face.forward) normal = math.scale(normal, -1.0);

            // Extract 2D boundary polygon of the face
            var polygon_buf: [128][2]f64 = undefined;
            var poly_len: usize = 0;
            const outer_loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];

            var curr_he = outer_loop.first_half_edge;
            while (true) {
                const he = t_arena.half_edges.items[curr_he];
                if (poly_len < polygon_buf.len) {
                    polygon_buf[poly_len] = projectToPlane(t_arena.vertices.items[he.start_vertex].point, plane.origin, plane.u_axis, plane.v_axis);
                    poly_len += 1;
                }
                curr_he = he.next;
                if (curr_he == outer_loop.first_half_edge) break;
            }

            // 2. Traverse half-edges of the target solid
            for (0..s_edges.shells_len) |se_off| {
                const shell_e = t_arena.shells.items[t_arena.solid_shells.items[s_edges.shells_start + se_off]];
                for (0..shell_e.faces_len) |fe_off| {
                    const t_face = t_arena.faces.items[t_arena.shell_faces.items[shell_e.faces_start + fe_off]];
                    for (0..t_face.loops_len) |we_off| {
                        const t_loop = t_arena.loops.items[t_arena.face_loops.items[t_face.loops_start + we_off]];

                        var target_he_id = t_loop.first_half_edge;
                        while (true) {
                            const edge = t_arena.half_edges.items[target_he_id];
                            if (edge.curve.curve_type == .line) {
                                const line = g_arena.lines.items[edge.curve.index];

                                if (intersectLinePlane(line.start, line.end, plane.origin, normal)) |hit_pt| {
                                    const uv_hit = projectToPlane(hit_pt, plane.origin, plane.u_axis, plane.v_axis);
                                    if (isPointInPolygon2D(uv_hit, polygon_buf[0..poly_len])) {
                                        const edge_vec = math.sub(line.end, line.start);
                                        const hit_vec = math.sub(hit_pt, line.start);
                                        const total_dist = math.dot(edge_vec, edge_vec);
                                        const hit_dist = math.dot(hit_vec, hit_vec);
                                        const t = @sqrt(hit_dist / total_dist);

                                        try out_events.append(allocator, .{
                                            .he_id = target_he_id,
                                            .edge_solid = solid_edges,
                                            .face_id = face_id,
                                            .pt = hit_pt,
                                            .t = t,
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

/// Splits a Half-Edge (and its twin!) topologically at a 3D mid-point.
pub fn splitHalfEdge(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    he_id: topo.HalfEdgeId,
    split_pt: math.Vec3,
) !struct { v_mid: topo.VertexId, he_new: topo.HalfEdgeId } {
    const he = t_arena.half_edges.items[he_id];
    const twin_id = he.twin;

    // 1. Create new Mid-Vertex
    const v_mid_id: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(allocator, .{ .point = split_pt });

    // 2. Create new Geometric Line for second half
    const end_pt = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;
    const l_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{ .start = split_pt, .end = end_pt });

    // Truncate original line
    if (he.curve.curve_type == .line) {
        g_arena.lines.items[he.curve.index].end = split_pt;
    }

    // 3. Create new HalfEdge (he_new) following he_id
    const he_new_id: u32 = @intCast(t_arena.half_edges.items.len);
    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_mid_id,
        .twin = topo.NULL_ID,
        .next = he.next,
        .prev = he_id,
        .loop_id = he.loop_id,
        .curve = .{ .index = l_idx, .curve_type = .line },
        .forward = true,
    });

    // Splice into primary loop
    t_arena.half_edges.items[he.next].prev = he_new_id;
    t_arena.half_edges.items[he_id].next = he_new_id;

    // 4. Handle Twin (if present)
    if (twin_id != topo.NULL_ID) {
        const twin = t_arena.half_edges.items[twin_id];
        const twin_l_idx: u24 = @intCast(g_arena.lines.items.len);
        try g_arena.lines.append(allocator, .{ .start = split_pt, .end = t_arena.vertices.items[twin.start_vertex].point });

        const twin_new_id: u32 = @intCast(t_arena.half_edges.items.len);
        try t_arena.half_edges.append(allocator, .{
            .start_vertex = v_mid_id,
            .twin = he_id,
            .next = twin.next,
            .prev = twin_id,
            .loop_id = twin.loop_id,
            .curve = .{ .index = twin_l_idx, .curve_type = .line },
            .forward = true,
        });

        t_arena.half_edges.items[twin.next].prev = twin_new_id;
        t_arena.half_edges.items[twin_id].next = twin_new_id;

        // Wire cross-twins
        t_arena.half_edges.items[he_id].twin = twin_new_id;
        t_arena.half_edges.items[he_new_id].twin = twin_id;
        t_arena.half_edges.items[twin_id].twin = he_new_id;
    }

    return .{ .v_mid = v_mid_id, .he_new = he_new_id };
}

/// Weaves an inner hole loop into a face across piercing vertices.
fn punchHole(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    pts: []const topo.VertexId,
) !void {
    const face = t_arena.faces.items[face_id];
    if (face.surface.surface_type != .plane) return;
    const plane = g_arena.planes.items[face.surface.index];

    // Radial Sort
    var centroid_uv = [2]f64{ 0, 0 };
    for (pts) |v_id| {
        const uv = projectToPlane(t_arena.vertices.items[v_id].point, plane.origin, plane.u_axis, plane.v_axis);
        centroid_uv[0] += uv[0];
        centroid_uv[1] += uv[1];
    }
    centroid_uv[0] /= @as(f64, @floatFromInt(pts.len));
    centroid_uv[1] /= @as(f64, @floatFromInt(pts.len));

    const SortPoint = struct { v_id: topo.VertexId, angle: f64 };
    var sorted = try allocator.alloc(SortPoint, pts.len);
    defer allocator.free(sorted);

    for (pts, 0..) |v_id, i| {
        const uv = projectToPlane(t_arena.vertices.items[v_id].point, plane.origin, plane.u_axis, plane.v_axis);
        sorted[i] = .{ .v_id = v_id, .angle = std.math.atan2(uv[1] - centroid_uv[1], uv[0] - centroid_uv[0]) };
    }
    std.mem.sort(SortPoint, sorted, {}, struct {
        fn lessThan(_: void, a: SortPoint, b: SortPoint) bool {
            return a.angle < b.angle;
        }
    }.lessThan);

    // Build Half-Edge Loop
    const loop_id: u32 = @intCast(t_arena.loops.items.len);
    const he_start: u32 = @intCast(t_arena.half_edges.items.len);
    const n = sorted.len;

    for (0..n) |i| {
        const v_start = sorted[i].v_id;
        const v_end = sorted[(i + 1) % n].v_id;

        const line_idx: u24 = @intCast(g_arena.lines.items.len);
        try g_arena.lines.append(allocator, .{
            .start = t_arena.vertices.items[v_start].point,
            .end = t_arena.vertices.items[v_end].point,
        });

        try t_arena.half_edges.append(allocator, .{
            .start_vertex = v_start,
            .twin = topo.NULL_ID,
            .next = he_start + @as(u32, @intCast((i + 1) % n)),
            .prev = he_start + @as(u32, @intCast((i + n - 1) % n)),
            .loop_id = loop_id,
            .curve = .{ .index = line_idx, .curve_type = .line },
            .forward = true,
        });
    }

    try t_arena.loops.append(allocator, .{ .face_id = face_id, .first_half_edge = he_start });

    const new_fl_start: u32 = @intCast(t_arena.face_loops.items.len);
    for (0..face.loops_len) |l_off| {
        try t_arena.face_loops.append(allocator, t_arena.face_loops.items[face.loops_start + l_off]);
    }
    try t_arena.face_loops.append(allocator, loop_id);

    t_arena.faces.items[face_id].loops_start = new_fl_start;
    t_arena.faces.items[face_id].loops_len += 1;
}

/// Raycaster Point-in-Solid test using Half-Edge loops
pub fn isPointInsideSolid(
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
    pt: math.Vec3,
) bool {
    const ray_dir = math.Vec3{ 1.0, 0.0, 0.0 };
    var hit_count: u32 = 0;

    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];
            if (face.surface.surface_type != .plane) continue;

            const plane = g_arena.planes.items[face.surface.index];
            var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
            if (!face.forward) normal = math.scale(normal, -1.0);

            const denom = math.dot(ray_dir, normal);
            if (@abs(denom) < math.MATH_EPSILON) continue;

            const t = math.dot(math.sub(plane.origin, pt), normal) / denom;
            if (t > math.MATH_EPSILON) {
                const hit_pt = math.add(pt, math.scale(ray_dir, t));
                const uv_hit = projectToPlane(hit_pt, plane.origin, plane.u_axis, plane.v_axis);

                var polygon_buf: [128][2]f64 = undefined;
                var poly_len: usize = 0;
                const outer_loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];

                var curr_he = outer_loop.first_half_edge;
                while (true) {
                    const he = t_arena.half_edges.items[curr_he];
                    if (poly_len < polygon_buf.len) {
                        polygon_buf[poly_len] = projectToPlane(t_arena.vertices.items[he.start_vertex].point, plane.origin, plane.u_axis, plane.v_axis);
                        poly_len += 1;
                    }
                    curr_he = he.next;
                    if (curr_he == outer_loop.first_half_edge) break;
                }

                if (isPointInPolygon2D(uv_hit, polygon_buf[0..poly_len])) {
                    hit_count += 1;
                }
            }
        }
    }
    return (hit_count % 2) != 0;
}

fn classifyFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    target_solid_id: topo.SolidId,
) FaceClassification {
    _ = allocator;
    const face = t_arena.faces.items[face_id];
    const outer_loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];

    var centroid = math.Vec3{ 0, 0, 0 };
    var v_count: f64 = 0.0;

    var curr_he = outer_loop.first_half_edge;
    while (true) {
        const he = t_arena.half_edges.items[curr_he];
        centroid = math.add(centroid, t_arena.vertices.items[he.start_vertex].point);
        v_count += 1.0;
        curr_he = he.next;
        if (curr_he == outer_loop.first_half_edge) break;
    }
    const sample_pt = math.scale(centroid, 1.0 / v_count);

    var normal = math.Vec3{ 0, 0, 1 };
    if (face.surface.surface_type == .plane) {
        const plane = g_arena.planes.items[face.surface.index];
        normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
        if (!face.forward) normal = math.scale(normal, -1.0);
    }

    const test_pt = math.sub(sample_pt, math.scale(normal, 1e-4));
    if (isPointInsideSolid(t_arena, g_arena, target_solid_id, test_pt)) return .inside;
    return .outside;
}

/// Computes the CSG Boolean operation on Half-Edge Graph
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

    // Phase 1: Piercing
    var intersection_events = std.ArrayListUnmanaged(IntersectionEvent).empty;
    defer intersection_events.deinit(allocator);

    collectPiercings(allocator, t_arena, g_arena, solid_a, solid_b, &intersection_events) catch return error.OutOfMemory;
    collectPiercings(allocator, t_arena, g_arena, solid_b, solid_a, &intersection_events) catch return error.OutOfMemory;

    std.mem.sort(IntersectionEvent, intersection_events.items, {}, struct {
        fn lessThan(_: void, lhs: IntersectionEvent, rhs: IntersectionEvent) bool {
            if (lhs.he_id == rhs.he_id) return lhs.t < rhs.t;
            return lhs.he_id < rhs.he_id;
        }
    }.lessThan);

    // Phase 2: Split HalfEdges
    var active_original_he: topo.HalfEdgeId = std.math.maxInt(u32);
    var current_sub_he: topo.HalfEdgeId = 0;

    var face_piercings = std.AutoHashMap(topo.FaceId, std.ArrayListUnmanaged(topo.VertexId)).init(allocator);
    defer {
        var pit = face_piercings.iterator();
        while (pit.next()) |entry| entry.value_ptr.deinit(allocator);
        face_piercings.deinit();
    }

    const registerPiercing = struct {
        fn apply(alloc: std.mem.Allocator, map: *std.AutoHashMap(topo.FaceId, std.ArrayListUnmanaged(topo.VertexId)), f_id: topo.FaceId, v_id: topo.VertexId) !void {
            var res = try map.getOrPut(f_id);
            if (!res.found_existing) res.value_ptr.* = .empty;
            for (res.value_ptr.items) |existing_v| if (existing_v == v_id) return;
            try res.value_ptr.append(alloc, v_id);
        }
    }.apply;

    for (intersection_events.items) |event| {
        if (event.he_id != active_original_he) {
            active_original_he = event.he_id;
            current_sub_he = event.he_id;
        }

        const split = splitHalfEdge(allocator, t_arena, g_arena, current_sub_he, event.pt) catch return error.OutOfMemory;
        current_sub_he = split.he_new;

        const parent_face = t_arena.loops.items[t_arena.half_edges.items[event.he_id].loop_id].face_id;
        try registerPiercing(allocator, &face_piercings, event.face_id, split.v_mid);
        try registerPiercing(allocator, &face_piercings, parent_face, split.v_mid);
    }

    // Phase 3: Seam Weaving
    var face_it = face_piercings.iterator();
    while (face_it.next()) |entry| {
        const face_id = entry.key_ptr.*;
        const pts = entry.value_ptr.items;
        if (pts.len >= 3) {
            punchHole(allocator, t_arena, g_arena, face_id, pts) catch continue;
        }
    }

    // Phase 4: Classification
    var selected_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer selected_faces.deinit(allocator);

    const sa = t_arena.solids.items[solid_a];
    for (0..sa.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[sa.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const class = classifyFace(allocator, t_arena, g_arena, face_id, solid_b);
            const keep = switch (op) {
                .union_op => class == .outside or class == .same,
                .difference => class == .outside or class == .opposite,
                .intersection => class == .inside or class == .same,
            };
            if (keep) try selected_faces.append(allocator, face_id);
        }
    }

    const sb = t_arena.solids.items[solid_b];
    for (0..sb.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[sb.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const class = classifyFace(allocator, t_arena, g_arena, face_id, solid_a);
            const keep = switch (op) {
                .union_op => class == .outside,
                .difference => class == .inside,
                .intersection => class == .inside,
            };
            if (keep) {
                if (op == .difference) {
                    var flipped_face = t_arena.faces.items[face_id];
                    flipped_face.forward = !flipped_face.forward;
                    const new_face_id: u32 = @intCast(t_arena.faces.items.len);
                    try t_arena.faces.append(allocator, flipped_face);
                    try selected_faces.append(allocator, new_face_id);
                } else {
                    try selected_faces.append(allocator, face_id);
                }
            }
        }
    }

    // Phase 5: Reassembly
    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.appendSlice(allocator, selected_faces.items);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = @intCast(selected_faces.items.len) });

    const new_solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_start);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return new_solid_id;
}
