const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

// --- Mathematical Curve Definitions for Exact SSI ---

pub const MathLine = struct {
    origin: math.Vec3,
    direction: math.Vec3,
};

pub const MathCircle = struct {
    center: math.Vec3,
    radius: f64,
    normal: math.Vec3,
    x_axis: math.Vec3,
    y_axis: math.Vec3,
};

pub const IntersectionResult = union(enum) {
    empty,
    point: math.Vec3,
    line: MathLine,
    two_lines: [2]MathLine,
    circle: MathCircle,
    sampled: []math.Vec3,
    two_sampled: [2][]math.Vec3,
};

pub const Segment3D = struct {
    start: math.Vec3,
    end: math.Vec3,
};

pub const BooleanOp = enum { union_op, difference, intersection };
pub const FaceClassification = enum { inside, outside, same, opposite };

pub const BooleanError = error{
    OutOfMemory,
    DidNotConverge,
};

pub const IntersectionEvent = struct {
    he_id: topo.HalfEdgeId,
    edge_solid: topo.SolidId,
    face_id: topo.FaceId,
    pt: math.Vec3,
    t: f64,
};

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

fn projectToPlane(pt: math.Vec3, origin: math.Vec3, u_axis: math.Vec3, v_axis: math.Vec3) [2]f64 {
    const v = math.sub(pt, origin);
    return .{ math.dot(v, u_axis), math.dot(v, v_axis) };
}

pub fn isPointInPolygon2D(pt: [2]f64, polygon: []const [2]f64) bool {
    var centroid = [2]f64{ 0, 0 };
    for (polygon) |p| {
        centroid[0] += p[0];
        centroid[1] += p[1];
    }
    centroid[0] /= @as(f64, @floatFromInt(polygon.len));
    centroid[1] /= @as(f64, @floatFromInt(polygon.len));

    // Epsilon-Shrink: Pull the point slightly towards the centroid.
    // This allows points resting EXACTLY on a boundary to be safely raycasted as inside.
    const eps = 1e-4;
    const test_pt = [2]f64{
        pt[0] * (1.0 - eps) + centroid[0] * eps,
        pt[1] * (1.0 - eps) + centroid[1] * eps,
    };

    var inside = false;
    var j: usize = polygon.len - 1;
    for (0..polygon.len) |i| {
        const pi = polygon[i];
        const pj = polygon[j];

        if (((pi[1] > test_pt[1]) != (pj[1] > test_pt[1])) and
            (test_pt[0] < (pj[0] - pi[0]) * (test_pt[1] - pi[1]) / (pj[1] - pi[1]) + pi[0]))
        {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

pub fn intersectLinePlane(line_start: math.Vec3, line_end: math.Vec3, plane_origin: math.Vec3, plane_normal: math.Vec3) ?math.Vec3 {
    const dir = math.sub(line_end, line_start);
    const denom = math.dot(dir, plane_normal);
    if (@abs(denom) < math.MATH_EPSILON) return null;

    const t = math.dot(math.sub(plane_origin, line_start), plane_normal) / denom;
    if (t > 1e-6 and t < (1.0 - 1e-6)) {
        return math.add(line_start, math.scale(dir, t));
    }
    return null;
}

pub fn intersectArcPlane(arc: geom.CircleArc, v_start: math.Vec3, v_end: math.Vec3, plane_origin: math.Vec3, plane_normal: math.Vec3, forward: bool) ?math.Vec3 {
    const A = arc.radius * math.dot(plane_normal, arc.x_axis);
    const B = arc.radius * math.dot(plane_normal, arc.y_axis);
    const D = math.dot(plane_normal, math.sub(plane_origin, arc.center));
    const Rab_sq = A * A + B * B;
    if (Rab_sq < 1e-12) return null;
    const Rab = @sqrt(Rab_sq);
    if (@abs(D) > Rab + 1e-9) return null;

    const D_clamped = std.math.clamp(D / Rab, -1.0, 1.0);
    const phi = std.math.atan2(A, B);
    var t1 = std.math.asin(D_clamped) - phi;
    var t2 = std.math.pi - std.math.asin(D_clamped) - phi;
    t1 = @mod(t1, 2.0 * std.math.pi);
    if (t1 < 0) t1 += 2.0 * std.math.pi;
    t2 = @mod(t2, 2.0 * std.math.pi);
    if (t2 < 0) t2 += 2.0 * std.math.pi;

    const u_start = math.normalize(math.sub(v_start, arc.center));
    const u_end = math.normalize(math.sub(v_end, arc.center));
    var ang_start = std.math.atan2(math.dot(u_start, arc.y_axis), math.dot(u_start, arc.x_axis));
    var ang_end = std.math.atan2(math.dot(u_end, arc.y_axis), math.dot(u_end, arc.x_axis));
    if (ang_start < 0) ang_start += 2.0 * std.math.pi;
    if (ang_end < 0) ang_end += 2.0 * std.math.pi;
    if (!forward) std.mem.swap(f64, &ang_start, &ang_end);

    const is_full = math.distSq(v_start, v_end) < 1e-9;
    const eps = 1e-6;
    const in1 = is_full or (if (ang_start < ang_end) (t1 > ang_start + eps and t1 < ang_end - eps) else (t1 > ang_start + eps or t1 < ang_end - eps));
    const in2 = is_full or (if (ang_start < ang_end) (t2 > ang_start + eps and t2 < ang_end - eps) else (t2 > ang_start + eps or t2 < ang_end - eps));

    const p1 = math.add(arc.center, math.add(math.scale(arc.x_axis, arc.radius * @cos(t1)), math.scale(arc.y_axis, arc.radius * @sin(t1))));
    const p2 = math.add(arc.center, math.add(math.scale(arc.x_axis, arc.radius * @cos(t2)), math.scale(arc.y_axis, arc.radius * @sin(t2))));

    if (in1 and !in2) return p1;
    if (in2 and !in1) return p2;
    if (in1 and in2) return p1;
    return null;
}

pub fn intersectNurbsPlane(curve: geom.NurbsCurve, plane_origin: math.Vec3, plane_normal: math.Vec3) ?math.Vec3 {
    const segments = 20;
    var prev_pt = geom.evaluateNurbsCurve(curve, 0.0);
    var prev_dist = math.dot(plane_normal, math.sub(prev_pt, plane_origin));
    for (1..segments + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segments));
        const curr_pt = geom.evaluateNurbsCurve(curve, t);
        const curr_dist = math.dot(plane_normal, math.sub(curr_pt, plane_origin));
        if (prev_dist * curr_dist < 0.0) {
            var t_low = t - (1.0 / @as(f64, @floatFromInt(segments)));
            var t_high = t;
            for (0..15) |_| {
                const t_mid = (t_low + t_high) / 2.0;
                const mid_pt = geom.evaluateNurbsCurve(curve, t_mid);
                const mid_dist = math.dot(plane_normal, math.sub(mid_pt, plane_origin));
                if (mid_dist * prev_dist > 0.0) t_low = t_mid else t_high = t_mid;
            }
            const hit_t = (t_low + t_high) / 2.0;
            if (hit_t > 0.001 and hit_t < 0.999) return geom.evaluateNurbsCurve(curve, hit_t);
        }
        prev_pt = curr_pt;
        prev_dist = curr_dist;
    }
    return null;
}

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

    for (0..s_faces.shells_len) |sf_off| {
        const shell_f = t_arena.shells.items[t_arena.solid_shells.items[s_faces.shells_start + sf_off]];
        for (0..shell_f.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell_f.faces_start + f_off];
            const face = t_arena.faces.items[face_id];
            if (face.surface.surface_type != .plane) continue;

            const plane = g_arena.planes.items[face.surface.index];
            var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
            if (!face.forward) normal = math.scale(normal, -1.0);

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

                                var hit_pt_opt: ?math.Vec3 = null;
                                switch (edge.curve.curve_type) {
                                    .line => hit_pt_opt = intersectLinePlane(g_arena.lines.items[edge.curve.index].start, g_arena.lines.items[edge.curve.index].end, plane.origin, normal),
                                    .circle_arc => hit_pt_opt = intersectArcPlane(g_arena.circle_arcs.items[edge.curve.index], v_start, v_end, plane.origin, normal, edge.forward),
                                    .nurbs => hit_pt_opt = intersectNurbsPlane(g_arena.nurbs_curves.items[edge.curve.index], plane.origin, normal),
                                }

                                if (hit_pt_opt) |hit_pt| {
                                    const uv_hit = projectToPlane(hit_pt, plane.origin, plane.u_axis, plane.v_axis);
                                    if (isPointInPolygon2D(uv_hit, polygon_buf[0..poly_len])) {
                                        const hit_vec = math.sub(hit_pt, v_start);
                                        try out_events.append(allocator, .{
                                            .he_id = target_he_id,
                                            .edge_solid = solid_edges,
                                            .face_id = face_id,
                                            .pt = hit_pt,
                                            .t = math.magSq(hit_vec),
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

pub fn splitHalfEdge(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    he_id: topo.HalfEdgeId,
    split_pt: math.Vec3,
) !struct { v_mid: topo.VertexId, he_new: topo.HalfEdgeId } {
    const he = t_arena.half_edges.items[he_id];
    const twin_id = he.twin;

    const v_mid_id: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.append(allocator, .{ .point = split_pt });

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

fn sliceFace(
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

    var curr = loop.first_half_edge;
    while (true) {
        const he = t_arena.half_edges.items[curr];
        if (he.start_vertex == v_a) he_a = curr;
        if (he.start_vertex == v_b) he_b = curr;
        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }

    if (he_a == null or he_b == null) return null;

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

fn punchHole(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    pts: []const topo.VertexId,
) !?topo.FaceId {
    const face = t_arena.faces.items[face_id];
    if (face.surface.surface_type != .plane) return null;
    const plane = g_arena.planes.items[face.surface.index];

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

    const loop_id: u32 = @intCast(t_arena.loops.items.len);
    const he_start: u32 = @intCast(t_arena.half_edges.items.len);
    const n = sorted.len;

    for (0..n) |i| {
        const v_start = sorted[i].v_id;
        const v_end = sorted[(i + 1) % n].v_id;

        const line_idx: u24 = @intCast(g_arena.lines.items.len);
        try g_arena.lines.append(allocator, .{ .start = t_arena.vertices.items[v_start].point, .end = t_arena.vertices.items[v_end].point });

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

    const new_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.loops.append(allocator, .{ .face_id = new_face_id, .first_half_edge = he_start });
    const new_fl_start: u32 = @intCast(t_arena.face_loops.items.len);
    try t_arena.face_loops.append(allocator, loop_id);
    try t_arena.faces.append(allocator, .{
        .surface = face.surface,
        .forward = face.forward,
        .loops_start = new_fl_start,
        .loops_len = 1,
    });
    return new_face_id;
}

pub fn isPointInsideSolid(t_arena: *const topo.TopologyArena, g_arena: *const geom.GeometryArena, solid_id: topo.SolidId, pt: math.Vec3) bool {
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
                if (isPointInPolygon2D(uv_hit, polygon_buf[0..poly_len])) hit_count += 1;
            }
        }
    }
    return (hit_count % 2) != 0;
}

fn classifyFace(allocator: std.mem.Allocator, t_arena: *topo.TopologyArena, g_arena: *geom.GeometryArena, face_id: topo.FaceId, target_solid_id: topo.SolidId) FaceClassification {
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

    // Coplanar Classification Fix: By testing both sides, we perfectly detect coplanar overlap faces.
    const pt_in = math.sub(sample_pt, math.scale(normal, 1e-4));
    const pt_out = math.add(sample_pt, math.scale(normal, 1e-4));

    const in_solid = isPointInsideSolid(t_arena, g_arena, target_solid_id, pt_in);
    const out_solid = isPointInsideSolid(t_arena, g_arena, target_solid_id, pt_out);

    if (in_solid and out_solid) return .inside;
    if (!in_solid and !out_solid) return .outside;
    if (in_solid and !out_solid) return .same;
    return .opposite;
}

const FaceTracker = struct {
    face: topo.FaceId,
    source_solid: topo.SolidId,
};

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

    var intersection_events = std.ArrayListUnmanaged(IntersectionEvent).empty;
    defer intersection_events.deinit(allocator);

    try collectPiercings(allocator, t_arena, g_arena, solid_a, solid_b, &intersection_events);
    try collectPiercings(allocator, t_arena, g_arena, solid_b, solid_a, &intersection_events);

    std.mem.sort(IntersectionEvent, intersection_events.items, {}, struct {
        fn lessThan(_: void, lhs: IntersectionEvent, rhs: IntersectionEvent) bool {
            if (lhs.he_id == rhs.he_id) return lhs.t < rhs.t;
            return lhs.he_id < rhs.he_id;
        }
    }.lessThan);

    var active_original_he: topo.HalfEdgeId = std.math.maxInt(u32);
    var current_sub_he: topo.HalfEdgeId = 0;

    var face_piercings = std.AutoHashMap(topo.FaceId, std.ArrayListUnmanaged(topo.VertexId)).init(allocator);
    defer {
        var pit = face_piercings.iterator();
        while (pit.next()) |entry| entry.value_ptr.deinit(allocator);
        face_piercings.deinit();
    }

    for (intersection_events.items) |event| {
        if (event.he_id != active_original_he) {
            active_original_he = event.he_id;
            current_sub_he = event.he_id;
        }

        const parent_face = t_arena.loops.items[t_arena.half_edges.items[current_sub_he].loop_id].face_id;
        const twin_id = t_arena.half_edges.items[current_sub_he].twin;
        const twin_face = if (twin_id != topo.NULL_ID) t_arena.loops.items[t_arena.half_edges.items[twin_id].loop_id].face_id else null;

        const split = try splitHalfEdge(allocator, t_arena, g_arena, current_sub_he, event.pt);
        current_sub_he = split.he_new;

        var res1 = try face_piercings.getOrPut(event.face_id);
        if (!res1.found_existing) res1.value_ptr.* = .empty;
        try res1.value_ptr.append(allocator, split.v_mid);

        var res2 = try face_piercings.getOrPut(parent_face);
        if (!res2.found_existing) res2.value_ptr.* = .empty;
        try res2.value_ptr.append(allocator, split.v_mid);

        if (twin_face) |tf| {
            var res3 = try face_piercings.getOrPut(tf);
            if (!res3.found_existing) res3.value_ptr.* = .empty;
            try res3.value_ptr.append(allocator, split.v_mid);
        }
    }

    var faces_to_classify = std.ArrayListUnmanaged(FaceTracker).empty;
    defer faces_to_classify.deinit(allocator);

    for ([_]topo.SolidId{ solid_a, solid_b }) |s_id| {
        const s = t_arena.solids.items[s_id];
        for (0..s.shells_len) |s_off| {
            const shell = t_arena.shells.items[t_arena.solid_shells.items[s.shells_start + s_off]];
            for (0..shell.faces_len) |f_off| {
                const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
                try faces_to_classify.append(allocator, .{ .face = face_id, .source_solid = s_id });
            }
        }
    }

    var face_it = face_piercings.iterator();
    while (face_it.next()) |entry| {
        const face_id = entry.key_ptr.*;
        const pts = entry.value_ptr.items;

        var source_solid: ?topo.SolidId = null;
        for (faces_to_classify.items) |item| {
            if (item.face == face_id) {
                source_solid = item.source_solid;
                break;
            }
        }
        if (source_solid == null) continue;

        if (pts.len >= 3) {
            if (punchHole(allocator, t_arena, g_arena, face_id, pts) catch null) |new_face_id| {
                try faces_to_classify.append(allocator, .{ .face = new_face_id, .source_solid = source_solid.? });
            }
        } else if (pts.len == 2) {
            if (sliceFace(allocator, t_arena, g_arena, face_id, pts[0], pts[1]) catch null) |new_face_id| {
                try faces_to_classify.append(allocator, .{ .face = new_face_id, .source_solid = source_solid.? });
            }
        }
    }

    var selected_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer selected_faces.deinit(allocator);

    for (faces_to_classify.items) |item| {
        const face_id = item.face;
        const s_id = item.source_solid;
        const target = if (s_id == solid_a) solid_b else solid_a;

        const class = classifyFace(allocator, t_arena, g_arena, face_id, target);

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
            if (s_id == solid_b and op == .difference) {
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

/// Intersection of two planes.
/// Returns an exact line, or empty if parallel/coincident.
pub fn intersectPlanePlane(a: geom.Plane, b: geom.Plane) IntersectionResult {
    const n1 = math.normalize(math.cross(a.u_axis, a.v_axis));
    const n2 = math.normalize(math.cross(b.u_axis, b.v_axis));

    const dir = math.cross(n1, n2);
    const dir_len = math.mag(dir);

    if (dir_len < 1e-12) {
        // Parallel or coincident. For boolean boundaries, coincident faces
        // are resolved via face classification, so we return empty.
        return .empty;
    }

    const d1 = math.dot(n1, a.origin);
    const d2 = math.dot(n2, b.origin);

    const n1n1 = math.dot(n1, n1);
    const n1n2 = math.dot(n1, n2);
    const n2n2 = math.dot(n2, n2);

    const det = n1n1 * n2n2 - n1n2 * n1n2;
    if (@abs(det) < 1e-15) {
        return .empty;
    }

    const c1 = (d1 * n2n2 - d2 * n1n2) / det;
    const c2 = (d2 * n1n1 - d1 * n1n2) / det;

    const origin = math.add(math.scale(n1, c1), math.scale(n2, c2));

    return .{ .line = .{ .origin = origin, .direction = math.normalize(dir) } };
}

/// Intersection of a plane and a sphere.
/// Returns a circle, a tangent point, or empty.
pub fn intersectPlaneSphere(plane: geom.Plane, sphere: geom.Sphere) IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));

    // Signed distance from sphere center to plane
    const dist = math.dot(n, math.sub(sphere.center, plane.origin));
    const abs_dist = @abs(dist);

    if (abs_dist > sphere.radius + 1e-9) {
        return .empty;
    }

    if (@abs(abs_dist - sphere.radius) < 1e-9) {
        // Tangent - single point
        const pt = math.sub(sphere.center, math.scale(n, dist));
        return .{ .point = pt };
    }

    // Circle
    const circle_radius = @sqrt(sphere.radius * sphere.radius - dist * dist);
    const circle_center = math.sub(sphere.center, math.scale(n, dist));

    // Construct an arbitrary orthonormal basis for the circle on the plane
    var x_axis = math.Vec3{ 1, 0, 0 };
    if (@abs(n[0]) > 0.99) {
        x_axis = math.normalize(math.cross(n, .{ 0, 1, 0 }));
    } else {
        x_axis = math.normalize(math.cross(n, .{ 1, 0, 0 }));
    }
    const y_axis = math.normalize(math.cross(n, x_axis));

    return .{ .circle = .{
        .center = circle_center,
        .radius = circle_radius,
        .normal = n,
        .x_axis = x_axis,
        .y_axis = y_axis,
    } };
}

/// Intersection of two spheres.
/// Returns a circle, a tangent point, or empty.
pub fn intersectSphereSphere(a: geom.Sphere, b: geom.Sphere) IntersectionResult {
    const ab = math.sub(b.center, a.center);
    const d = math.mag(ab);

    if (d < 1e-12) {
        // Concentric spheres (or identical)
        return .empty;
    }

    if (d > a.radius + b.radius + 1e-9) {
        return .empty; // Too far apart
    }

    if (d < @abs(a.radius - b.radius) - 1e-9) {
        return .empty; // One completely inside the other
    }

    // Check tangent cases
    if (@abs(d - a.radius - b.radius) < 1e-9) {
        // External tangent
        const pt = math.add(a.center, math.scale(ab, a.radius / d));
        return .{ .point = pt };
    }

    if (@abs(d - @abs(a.radius - b.radius)) < 1e-9) {
        // Internal tangent
        const sign: f64 = if (a.radius > b.radius) 1.0 else -1.0;
        const pt = math.add(a.center, math.scale(ab, sign * (a.radius / d)));
        return .{ .point = pt };
    }

    // General case - Circle
    // Distance from center A to the plane containing the intersection circle
    const h = (d * d + a.radius * a.radius - b.radius * b.radius) / (2.0 * d);
    const circle_center = math.add(a.center, math.scale(ab, h / d));

    // Clamp to 0 to prevent NaN from tiny floating point inaccuracies
    const radius_sq = @max(0.0, a.radius * a.radius - h * h);
    const circle_radius = @sqrt(radius_sq);
    const normal = math.normalize(ab);

    var x_axis = math.Vec3{ 1, 0, 0 };
    if (@abs(normal[0]) > 0.99) {
        x_axis = math.normalize(math.cross(normal, .{ 0, 1, 0 }));
    } else {
        x_axis = math.normalize(math.cross(normal, .{ 1, 0, 0 }));
    }
    const y_axis = math.normalize(math.cross(normal, x_axis));

    return .{ .circle = .{
        .center = circle_center,
        .radius = circle_radius,
        .normal = normal,
        .x_axis = x_axis,
        .y_axis = y_axis,
    } };
}

/// Calculate chordal sag samples for a cylinder of radius r
fn ellipseSamples(r: f64) usize {
    const sag = 1e-3;
    if (r > sag) {
        const arg = std.math.clamp(1.0 - sag / r, -1.0, 1.0);
        const n = @ceil(std.math.pi / std.math.acos(arg));
        return @intFromFloat(std.math.clamp(n, 64.0, 512.0));
    }
    return 64;
}

/// Intersection of a plane and a cylinder.
/// Returns exact Circle/Lines for perpendicular/parallel axes, or a sampled polyline for oblique planes.
pub fn intersectPlaneCylinder(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    cyl: geom.Cylinder,
) !IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const axis = math.normalize(cyl.axis);

    const cos_angle = @abs(math.dot(n, axis));

    if (cos_angle < 1e-12) {
        // Plane parallel to cylinder axis
        const axis_pt = cyl.origin;
        const dist = @abs(math.dot(n, math.sub(axis_pt, plane.origin)));

        if (dist > cyl.radius + 1e-9) {
            return .empty;
        }

        if (@abs(dist - cyl.radius) < 1e-9) {
            // Tangent line
            const signed_dist = math.dot(n, math.sub(axis_pt, plane.origin));
            const closest = math.sub(axis_pt, math.scale(n, signed_dist));
            return .{ .line = .{ .origin = closest, .direction = axis } };
        }

        // Two parallel lines
        const signed_dist = math.dot(n, math.sub(axis_pt, plane.origin));
        const axis_on_plane = math.sub(axis_pt, math.scale(n, signed_dist));

        var perp = math.cross(axis, n);
        if (math.magSq(perp) < 1e-12) {
            return .empty;
        }
        perp = math.normalize(perp);

        const lateral = @sqrt(cyl.radius * cyl.radius - dist * dist);
        const p1 = math.add(axis_on_plane, math.scale(perp, lateral));
        const p2 = math.sub(axis_on_plane, math.scale(perp, lateral));

        return .{ .two_lines = .{
            .{ .origin = p1, .direction = axis },
            .{ .origin = p2, .direction = axis },
        } };
    } else if (@abs(cos_angle - 1.0) < 1e-12) {
        // Plane perpendicular to cylinder axis -> Exact Circle
        const dist_along_axis = math.dot(math.sub(plane.origin, cyl.origin), axis);
        const circle_center = math.add(cyl.origin, math.scale(axis, dist_along_axis));

        return .{ .circle = .{
            .center = circle_center,
            .radius = cyl.radius,
            .normal = n,
            .x_axis = cyl.x_axis,
            .y_axis = cyl.y_axis,
        } };
    } else {
        // General oblique case -> Ellipse sampled as a polyline
        const n_samples = ellipseSamples(cyl.radius);
        var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
        errdefer points.deinit(allocator);

        const tau = 2.0 * std.math.pi;
        for (0..n_samples) |i| {
            const angle = tau * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);

            const radial = math.add(
                math.scale(cyl.x_axis, cyl.radius * cos_a),
                math.scale(cyl.y_axis, cyl.radius * sin_a),
            );
            const p_on_cyl_base = math.add(cyl.origin, radial);

            const denom = math.dot(n, axis);
            if (@abs(denom) < 1e-15) continue;

            const t = math.dot(n, math.sub(plane.origin, p_on_cyl_base)) / denom;
            const pt = math.add(p_on_cyl_base, math.scale(axis, t));
            try points.append(allocator, pt);
        }

        if (points.items.len == 0) {
            points.deinit(allocator);
            return .empty;
        }

        // Close the sampled loop
        try points.append(allocator, points.items[0]);
        return .{ .sampled = try points.toOwnedSlice(allocator) };
    }
}

/// Routes two Surface IDs to their corresponding exact algebraic solver.
pub fn intersectSurfaces(
    allocator: std.mem.Allocator,
    g_arena: *const geom.GeometryArena,
    surf_a: geom.SurfaceId,
    surf_b: geom.SurfaceId,
) !IntersectionResult {
    switch (surf_a.surface_type) {
        .plane => switch (surf_b.surface_type) {
            .plane => return intersectPlanePlane(g_arena.planes.items[surf_a.index], g_arena.planes.items[surf_b.index]),
            .cylinder => return try intersectPlaneCylinder(allocator, g_arena.planes.items[surf_a.index], g_arena.cylinders.items[surf_b.index]),
            .sphere => return intersectPlaneSphere(g_arena.planes.items[surf_a.index], g_arena.spheres.items[surf_b.index]),
            else => return .empty,
        },
        .cylinder => switch (surf_b.surface_type) {
            .plane => return try intersectPlaneCylinder(allocator, g_arena.planes.items[surf_b.index], g_arena.cylinders.items[surf_a.index]),
            else => return .empty,
        },
        .sphere => switch (surf_b.surface_type) {
            .plane => return intersectPlaneSphere(g_arena.planes.items[surf_b.index], g_arena.spheres.items[surf_a.index]),
            .sphere => return intersectSphereSphere(g_arena.spheres.items[surf_a.index], g_arena.spheres.items[surf_b.index]),
            else => return .empty,
        },
        else => return .empty,
    }
}

/// Finds where an infinite 2D line crosses a finite 2D line segment.
/// Returns the `t` parameter along the INFINITE line, or null if it misses.
fn intersectInfiniteLineSegment2D(line_o: [2]f64, line_d: [2]f64, p1: [2]f64, p2: [2]f64) ?f64 {
    const seg_d = [2]f64{ p2[0] - p1[0], p2[1] - p1[1] };
    const denom = line_d[0] * seg_d[1] - line_d[1] * seg_d[0];
    if (@abs(denom) < 1e-9) return null; // Parallel

    const diff = [2]f64{ p1[0] - line_o[0], p1[1] - line_o[1] };
    const u = (diff[0] * line_d[1] - diff[1] * line_d[0]) / denom;
    const t = (diff[0] * seg_d[1] - diff[1] * seg_d[0]) / denom;

    // If the intersection lies within the bounds of the finite segment
    if (u >= -1e-5 and u <= 1.0 + 1e-5) {
        return t;
    }
    return null;
}

/// Projects an infinite 3D line into the 2D surface of a Face and clips it against the boundary loops.
/// Returns a list of finite 3D segments that represent exactly where the line sits inside the face.
pub fn clipMathLineToFace(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    face_id: topo.FaceId,
    line: MathLine,
) ![]Segment3D {
    const face = t_arena.faces.items[face_id];

    // Fallback: we only clip planar faces for now.
    if (face.surface.surface_type != .plane) return &[_]Segment3D{};

    const plane = g_arena.planes.items[face.surface.index];

    // Project infinite 3D line down to a 2D line on the plane
    const o_2d = projectToPlane(line.origin, plane.origin, plane.u_axis, plane.v_axis);
    const pt2_2d = projectToPlane(math.add(line.origin, line.direction), plane.origin, plane.u_axis, plane.v_axis);
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

            const p1_2d = projectToPlane(p1, plane.origin, plane.u_axis, plane.v_axis);
            const p2_2d = projectToPlane(p2, plane.origin, plane.u_axis, plane.v_axis);

            if (intersectInfiniteLineSegment2D(o_2d, d_2d, p1_2d, p2_2d)) |t_hit| {
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
        if (deduped.items.len == 0 or @abs(deduped.items[deduped.items.len - 1] - t) > 1e-5) {
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


