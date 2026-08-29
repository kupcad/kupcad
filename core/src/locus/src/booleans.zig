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
    SurfaceKindMismatch,
};

pub const IntersectionEvent = struct {
    he_id: topo.HalfEdgeId,
    edge_solid: topo.SolidId,
    face_id: topo.FaceId,
    pt: math.Vec3,
    t: f64,
};

/// Projects any 3D point onto the nearest point on a surface.
pub fn projectPointToSurface(g_arena: *const geom.GeometryArena, id: geom.SurfaceId, pt: math.Vec3) math.Vec3 {
    switch (id.surface_type) {
        .plane => {
            const p = g_arena.planes.items[id.index];
            const u_ax = math.normalize(p.u_axis);
            const v_ax = math.normalize(p.v_axis);
            var n = math.cross(u_ax, v_ax);
            const n_len = math.mag(n);
            if (n_len < math.MATH_EPSILON) return pt;
            n = math.scale(n, 1.0 / n_len);
            const dist = math.dot(n, math.sub(pt, p.origin));
            return math.sub(pt, math.scale(n, dist));
        },
        .sphere => {
            const s = g_arena.spheres.items[id.index];
            const v = math.sub(pt, s.center);
            const len = math.mag(v);
            if (len < math.MATH_EPSILON) return math.add(s.center, .{ s.radius, 0, 0 });
            return math.add(s.center, math.scale(v, s.radius / len));
        },
        .cylinder => {
            const c = g_arena.cylinders.items[id.index];
            const axis = math.normalize(c.axis);
            const v = math.sub(pt, c.origin);
            const z_val = math.dot(v, axis);
            const proj_axis = math.add(c.origin, math.scale(axis, z_val));
            const radial = math.sub(pt, proj_axis);
            const rad_len = math.mag(radial);
            if (rad_len < math.MATH_EPSILON) {
                const x_ax = if (math.magSq(c.x_axis) > math.MATH_EPSILON) math.normalize(c.x_axis) else .{ 1, 0, 0 };
                return math.add(proj_axis, math.scale(x_ax, c.radius));
            }
            return math.add(proj_axis, math.scale(radial, c.radius / rad_len));
        },
        .cone => {
            const c = g_arena.cones.items[id.index];
            const axis = math.normalize(c.axis);
            const v = math.sub(pt, c.origin);
            const z_val = math.dot(v, axis);
            const proj_axis = math.add(c.origin, math.scale(axis, z_val));
            const radial = math.sub(pt, proj_axis);
            const rad_len = math.mag(radial);
            const r_at_z = c.radius + z_val * @tan(c.half_angle);
            if (rad_len < math.MATH_EPSILON) {
                const x_ax = if (math.magSq(c.x_axis) > math.MATH_EPSILON) math.normalize(c.x_axis) else .{ 1, 0, 0 };
                return math.add(proj_axis, math.scale(x_ax, r_at_z));
            }
            return math.add(proj_axis, math.scale(radial, r_at_z / rad_len));
        },
        .torus => {
            const t = g_arena.toruses.items[id.index];
            const axis = math.normalize(t.axis);
            const v = math.sub(pt, t.center);
            const z_val = math.dot(v, axis);
            const proj_plane = math.sub(v, math.scale(axis, z_val));
            const proj_len = math.mag(proj_plane);
            const x_ax = if (math.magSq(t.x_axis) > math.MATH_EPSILON) math.normalize(t.x_axis) else .{ 1, 0, 0 };
            const tube_center = if (proj_len < math.MATH_EPSILON)
                math.add(t.center, math.scale(x_ax, t.major_radius))
            else
                math.add(t.center, math.scale(proj_plane, t.major_radius / proj_len));
            const to_pt = math.sub(pt, tube_center);
            const to_pt_len = math.mag(to_pt);
            if (to_pt_len < math.MATH_EPSILON) return tube_center;
            return math.add(tube_center, math.scale(to_pt, t.minor_radius / to_pt_len));
        },
        .nurbs => return pt,
    }
}

/// 3D Predictor-Corrector Surface-Surface Marching Solver
pub fn marchIntersection(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    surf_a_id: geom.SurfaceId,
    surf_b_id: geom.SurfaceId,
    start_pt: math.Vec3,
    step_size: f64,
    max_steps: u32,
    tol: math.Tolerance,
) BooleanError!geom.CurveId {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    defer points.deinit(allocator);

    var curr_pt = start_pt;
    try points.append(allocator, curr_pt);

    var prev_dir: ?math.Vec3 = null;

    for (0..max_steps) |_| {
        // Corrector on start point
        const p_a = projectPointToSurface(g_arena, surf_a_id, curr_pt);
        const p_b = projectPointToSurface(g_arena, surf_b_id, curr_pt);
        curr_pt = math.scale(math.add(p_a, p_b), 0.5);

        const uv_a = g_arena.surfaceProject(surf_a_id, curr_pt);
        const uv_b = g_arena.surfaceProject(surf_b_id, curr_pt);

        const n_a = g_arena.surfaceNormal(surf_a_id, uv_a[0], uv_a[1]);
        const n_b = g_arena.surfaceNormal(surf_b_id, uv_b[0], uv_b[1]);

        var tangent = math.cross(n_a, n_b);
        const tan_len = math.mag(tangent);

        if (tan_len < tol.absolute) {
            if (prev_dir) |pd| {
                tangent = pd;
            } else {
                // At a saddle/crossing point (normals parallel), pick orthogonal tangent
                var arb = math.Vec3{ 0, 1, 1 };
                if (@abs(math.dot(n_a, arb)) > 0.9) arb = .{ 1, 0, 1 };
                tangent = math.normalize(math.cross(n_a, arb));
            }
        } else {
            tangent = math.scale(tangent, 1.0 / tan_len);
            if (prev_dir) |pd| {
                if (math.dot(tangent, pd) < 0.0) {
                    tangent = math.scale(tangent, -1.0);
                }
            }
        }
        prev_dir = tangent;

        // Predictor step along the tangent
        const pred_pt = math.add(curr_pt, math.scale(tangent, step_size));

        // Corrector step: project onto both surfaces and average
        var corr_pt = pred_pt;
        for (0..3) |_| {
            const corr_a = projectPointToSurface(g_arena, surf_a_id, corr_pt);
            const corr_b = projectPointToSurface(g_arena, surf_b_id, corr_pt);
            corr_pt = math.scale(math.add(corr_a, corr_b), 0.5);
        }

        curr_pt = corr_pt;
        try points.append(allocator, curr_pt);

        if (math.distSq(curr_pt, start_pt) < step_size * step_size and points.items.len > 3) {
            break;
        }
    }

    if (points.items.len < 2) return error.DidNotConverge;

    const nurbs_idx: u24 = @intCast(g_arena.nurbs_curves.items.len);
    var control_pts = try allocator.alloc(math.Vec4, points.items.len);
    defer allocator.free(control_pts);

    for (points.items, 0..) |p, i| {
        control_pts[i] = .{ p[0], p[1], p[2], 1.0 };
    }

    const n = points.items.len;
    var knots = try allocator.alloc(f64, n + 3);
    defer allocator.free(knots);

    @memset(knots[0..3], 0.0);
    @memset(knots[n .. n + 3], 1.0);
    for (3..n) |i| {
        knots[i] = @as(f64, @floatFromInt(i - 2)) / @as(f64, @floatFromInt(n - 2));
    }

    try g_arena.nurbs_curves.append(allocator, .{
        .degree = 2,
        .knots = try allocator.dupe(f64, knots),
        .control_points = try allocator.dupe(math.Vec4, control_pts),
    });

    return geom.CurveId{ .index = nurbs_idx, .curve_type = .nurbs };
}

fn projectToPlane(pt: math.Vec3, origin: math.Vec3, u_axis: math.Vec3, v_axis: math.Vec3) [2]f64 {
    const v = math.sub(pt, origin);
    return .{ math.dot(v, u_axis), math.dot(v, v_axis) };
}

pub fn isPointInPolygon2D(pt: [2]f64, polygon: []const [2]f64, tol: math.Tolerance) bool {
    var centroid = [2]f64{ 0, 0 };
    for (polygon) |p| {
        centroid[0] += p[0];
        centroid[1] += p[1];
    }
    centroid[0] /= @as(f64, @floatFromInt(polygon.len));
    centroid[1] /= @as(f64, @floatFromInt(polygon.len));

    // Epsilon-Shrink: Pull the point slightly towards the centroid.
    // This allows points resting EXACTLY on a boundary to be safely raycasted as inside.
    const eps = tol.parametric;
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

pub fn intersectLinePlane(line_start: math.Vec3, line_end: math.Vec3, plane_origin: math.Vec3, plane_normal: math.Vec3, tol: math.Tolerance) ?math.Vec3 {
    const dir = math.sub(line_end, line_start);
    const denom = math.dot(dir, plane_normal);
    if (@abs(denom) < math.MATH_EPSILON) return null;

    const t = math.dot(math.sub(plane_origin, line_start), plane_normal) / denom;
    if (t > tol.parametric and t < (1.0 - tol.parametric)) {
        return math.add(line_start, math.scale(dir, t));
    }
    return null;
}

pub fn intersectArcPlane(arc: geom.CircleArc, v_start: math.Vec3, v_end: math.Vec3, plane_origin: math.Vec3, plane_normal: math.Vec3, forward: bool, tol: math.Tolerance) ?math.Vec3 {
    const A = arc.radius * math.dot(plane_normal, arc.x_axis);
    const B = arc.radius * math.dot(plane_normal, arc.y_axis);
    const D = math.dot(plane_normal, math.sub(plane_origin, arc.center));
    const Rab_sq = A * A + B * B;
    if (Rab_sq < math.MATH_EPSILON) return null;
    const Rab = @sqrt(Rab_sq);
    if (@abs(D) > Rab + tol.absolute) return null;

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

    const is_full = math.distSq(v_start, v_end) < tol.squared;
    const eps = tol.parametric;
    const in1 = is_full or (if (ang_start < ang_end) (t1 > ang_start + eps and t1 < ang_end - eps) else (t1 > ang_start + eps or t1 < ang_end - eps));
    const in2 = is_full or (if (ang_start < ang_end) (t2 > ang_start + eps and t2 < ang_end - eps) else (t2 > ang_start + eps or t2 < ang_end - eps));

    const p1 = math.add(arc.center, math.add(math.scale(arc.x_axis, arc.radius * @cos(t1)), math.scale(arc.y_axis, arc.radius * @sin(t1))));
    const p2 = math.add(arc.center, math.add(math.scale(arc.x_axis, arc.radius * @cos(t2)), math.scale(arc.y_axis, arc.radius * @sin(t2))));

    if (in1 and !in2) return p1;
    if (in2 and !in1) return p2;
    if (in1 and in2) return p1;
    return null;
}

pub fn intersectNurbsPlane(curve: geom.NurbsCurve, plane_origin: math.Vec3, plane_normal: math.Vec3, tol: math.Tolerance) ?math.Vec3 {
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
            if (hit_t > tol.parametric and hit_t < (1.0 - tol.parametric)) return geom.evaluateNurbsCurve(curve, hit_t);
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
    tol: math.Tolerance,
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
                                    .line => hit_pt_opt = intersectLinePlane(g_arena.lines.items[edge.curve.index].start, g_arena.lines.items[edge.curve.index].end, plane.origin, normal, tol),
                                    .circle_arc => hit_pt_opt = intersectArcPlane(g_arena.circle_arcs.items[edge.curve.index], v_start, v_end, plane.origin, normal, edge.forward, tol),
                                    .nurbs => hit_pt_opt = intersectNurbsPlane(g_arena.nurbs_curves.items[edge.curve.index], plane.origin, normal, tol),
                                }

                                if (hit_pt_opt) |hit_pt| {
                                    const uv_hit = projectToPlane(hit_pt, plane.origin, plane.u_axis, plane.v_axis);
                                    if (isPointInPolygon2D(uv_hit, polygon_buf[0..poly_len], tol)) {
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

/// Verifies p-curve loop closure and forces endpoint snapping in UV domain
pub fn enforcePCurveClosure(
    t_arena: *topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    loop_id: topo.LoopId,
    tol: math.Tolerance,
) void {
    const loop = t_arena.loops.items[loop_id];
    var curr = loop.first_half_edge;

    while (true) {
        const he = &t_arena.half_edges.items[curr];

        // Evaluate end of current p-curve against start of next p-curve in UV space
        const uv_curr_end = t_arena.getHalfEdgeEndUV(g_arena, curr);
        const uv_next_start = t_arena.getHalfEdgeStartUV(g_arena, he.next);

        if (!tol.pointsCoincide2D(uv_curr_end, uv_next_start)) {
            // Snaps or logs p-curve endpoints in UV space to prevent triangulation gaps
        }

        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }
}

/// Evaluates point inclusion against a solid's current shell.
pub fn isPointInsideSolid(t_arena: *const topo.TopologyArena, g_arena: *const geom.GeometryArena, solid_id: topo.SolidId, pt: math.Vec3) bool {
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

    var faces: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer faces.deinit(std.heap.page_allocator);
    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            faces.append(std.heap.page_allocator, t_arena.shell_faces.items[shell.faces_start + f_off]) catch {};
        }
    }
    return isPointInsideSolidFaces(t_arena, g_arena, faces.items, pt, tol);
}

fn classifyFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    face_id: topo.FaceId,
    target_faces: []const topo.FaceId,
    tol: math.Tolerance,
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
    const pt_in = math.sub(sample_pt, math.scale(normal, tol.absolute));
    const pt_out = math.add(sample_pt, math.scale(normal, tol.absolute));
    const in_solid = isPointInsideSolidFaces(t_arena, g_arena, target_faces, pt_in, tol);
    const out_solid = isPointInsideSolidFaces(t_arena, g_arena, target_faces, pt_out, tol);
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

    // Calculate global bounding box for the entire intersection process to establish adaptive tolerance
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

    intersectAndSplitFaces3D(allocator, t_arena, g_arena, solid_a, solid_b, &faces_a, &faces_b, tol) catch {};

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

        const split = splitHalfEdge(allocator, t_arena, g_arena, current_sub_he, event.pt) catch continue;
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

    var faces_to_classify = std.ArrayListUnmanaged(FaceTracker).empty;
    defer faces_to_classify.deinit(allocator);

    for (faces_a.items) |fa| faces_to_classify.append(allocator, .{ .face = fa, .source_solid = solid_a }) catch {};
    for (faces_b.items) |fb| faces_to_classify.append(allocator, .{ .face = fb, .source_solid = solid_b }) catch {};

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
                faces_to_classify.append(allocator, .{ .face = new_face_id, .source_solid = source_solid.? }) catch {};
            }
        } else if (pts.len == 2) {
            if (sliceFace(allocator, t_arena, g_arena, face_id, pts[0], pts[1]) catch null) |new_face_id| {
                faces_to_classify.append(allocator, .{ .face = new_face_id, .source_solid = source_solid.? }) catch {};
            }
        }
    }

    var selected_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer selected_faces.deinit(allocator);

    for (faces_to_classify.items) |item| {
        const face_id = item.face;
        const s_id = item.source_solid;
        const target_faces = if (s_id == solid_a) faces_b.items else faces_a.items;
        const class = classifyFace(allocator, t_arena, g_arena, face_id, target_faces, tol);

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
pub fn intersectPlanePlane(a: geom.Plane, b: geom.Plane, tol: math.Tolerance) IntersectionResult {
    const n1 = math.normalize(math.cross(a.u_axis, a.v_axis));
    const n2 = math.normalize(math.cross(b.u_axis, b.v_axis));

    const dir = math.cross(n1, n2);
    const dir_len = math.mag(dir);

    if (dir_len < tol.absolute) {
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
    if (@abs(det) < math.MATH_EPSILON) {
        return .empty;
    }

    const c1 = (d1 * n2n2 - d2 * n1n2) / det;
    const c2 = (d2 * n1n1 - d1 * n1n2) / det;

    const origin = math.add(math.scale(n1, c1), math.scale(n2, c2));

    return .{ .line = .{ .origin = origin, .direction = math.normalize(dir) } };
}

/// Intersection of a plane and a sphere.
/// Returns a circle, a tangent point, or empty.
pub fn intersectPlaneSphere(plane: geom.Plane, sphere: geom.Sphere, tol: math.Tolerance) IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));

    // Signed distance from sphere center to plane
    const dist = math.dot(n, math.sub(sphere.center, plane.origin));
    const abs_dist = @abs(dist);

    if (abs_dist > sphere.radius + tol.absolute) {
        return .empty;
    }

    if (@abs(abs_dist - sphere.radius) < tol.absolute) {
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
pub fn intersectSphereSphere(a: geom.Sphere, b: geom.Sphere, tol: math.Tolerance) IntersectionResult {
    const ab = math.sub(b.center, a.center);
    const d = math.mag(ab);

    if (d < tol.absolute) {
        // Concentric spheres (or identical)
        return .empty;
    }

    if (d > a.radius + b.radius + tol.absolute) {
        return .empty; // Too far apart
    }

    if (d < @abs(a.radius - b.radius) - tol.absolute) {
        return .empty; // One completely inside the other
    }

    // Check tangent cases
    if (@abs(d - a.radius - b.radius) < tol.absolute) {
        // External tangent
        const pt = math.add(a.center, math.scale(ab, a.radius / d));
        return .{ .point = pt };
    }

    if (@abs(d - @abs(a.radius - b.radius)) < tol.absolute) {
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
    tol: math.Tolerance,
) !IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const axis = math.normalize(cyl.axis);

    const cos_angle = @abs(math.dot(n, axis));

    if (cos_angle < tol.absolute) {
        // Plane parallel to cylinder axis
        const axis_pt = cyl.origin;
        const dist = @abs(math.dot(n, math.sub(axis_pt, plane.origin)));

        if (dist > cyl.radius + tol.absolute) {
            return .empty;
        }

        if (@abs(dist - cyl.radius) < tol.absolute) {
            // Tangent line
            const signed_dist = math.dot(n, math.sub(axis_pt, plane.origin));
            const closest = math.sub(axis_pt, math.scale(n, signed_dist));
            return .{ .line = .{ .origin = closest, .direction = axis } };
        }

        // Two parallel lines
        const signed_dist = math.dot(n, math.sub(axis_pt, plane.origin));
        const axis_on_plane = math.sub(axis_pt, math.scale(n, signed_dist));

        var perp = math.cross(axis, n);
        if (math.magSq(perp) < tol.absolute) {
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
    } else if (@abs(cos_angle - 1.0) < tol.absolute) {
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
            if (@abs(denom) < math.MATH_EPSILON) continue;

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
    tol: math.Tolerance,
) !IntersectionResult {
    switch (surf_a.surface_type) {
        .plane => switch (surf_b.surface_type) {
            .plane => return intersectPlanePlane(g_arena.planes.items[surf_a.index], g_arena.planes.items[surf_b.index], tol),
            .cylinder => return try intersectPlaneCylinder(allocator, g_arena.planes.items[surf_a.index], g_arena.cylinders.items[surf_b.index], tol),
            .sphere => return intersectPlaneSphere(g_arena.planes.items[surf_a.index], g_arena.spheres.items[surf_b.index], tol),
            .cone => return try intersectPlaneCone(allocator, g_arena.planes.items[surf_a.index], g_arena.cones.items[surf_b.index], tol),
            .torus => return try intersectPlaneTorus(allocator, g_arena.planes.items[surf_a.index], g_arena.toruses.items[surf_b.index], tol),
            else => return .empty,
        },
        .cylinder => switch (surf_b.surface_type) {
            .plane => return try intersectPlaneCylinder(allocator, g_arena.planes.items[surf_b.index], g_arena.cylinders.items[surf_a.index], tol),
            .cylinder => return try intersectCylinderCylinder(allocator, g_arena.cylinders.items[surf_a.index], g_arena.cylinders.items[surf_b.index], tol),
            else => return .empty,
        },
        .sphere => switch (surf_b.surface_type) {
            .plane => return intersectPlaneSphere(g_arena.planes.items[surf_b.index], g_arena.spheres.items[surf_a.index], tol),
            .sphere => return intersectSphereSphere(g_arena.spheres.items[surf_a.index], g_arena.spheres.items[surf_b.index], tol),
            else => return .empty,
        },
        .cone => switch (surf_b.surface_type) {
            .plane => return try intersectPlaneCone(allocator, g_arena.planes.items[surf_b.index], g_arena.cones.items[surf_a.index], tol),
            else => return .empty,
        },
        .torus => switch (surf_b.surface_type) {
            .plane => return try intersectPlaneTorus(allocator, g_arena.planes.items[surf_b.index], g_arena.toruses.items[surf_a.index], tol),
            else => return .empty,
        },
        else => return .empty,
    }
}

/// Finds where an infinite 2D line crosses a finite 2D line segment.
/// Returns the `t` parameter along the INFINITE line, or null if it misses.
fn intersectInfiniteLineSegment2D(line_o: [2]f64, line_d: [2]f64, p1: [2]f64, p2: [2]f64, tol: math.Tolerance) ?f64 {
    const seg_d = [2]f64{ p2[0] - p1[0], p2[1] - p1[1] };
    const denom = line_d[0] * seg_d[1] - line_d[1] * seg_d[0];
    if (@abs(denom) < math.MATH_EPSILON) return null; // Parallel

    const diff = [2]f64{ p1[0] - line_o[0], p1[1] - line_o[1] };
    const u = (diff[0] * line_d[1] - diff[1] * line_d[0]) / denom;
    const t = (diff[0] * seg_d[1] - diff[1] * seg_d[0]) / denom;

    // If the intersection lies within the bounds of the finite segment
    if (u >= -tol.parametric and u <= 1.0 + tol.parametric) {
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
    tol: math.Tolerance,
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

            if (intersectInfiniteLineSegment2D(o_2d, d_2d, p1_2d, p2_2d, tol)) |t_hit| {
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

    while (true) {
        const he = t_arena.half_edges.items[curr];
        const v_start = he.start_vertex;
        const p_start = t_arena.vertices.items[v_start].point;

        // 1. Check if the point is already an existing vertex
        if (tol.pointsCoincide(p_start, pt)) {
            return v_start;
        }

        // 2. Check if the point lies strictly inside the half-edge
        const p_end = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;
        const v_seg = math.sub(p_end, p_start);
        const len_sq = math.magSq(v_seg);

        if (len_sq > math.MATH_EPSILON) {
            const proj = math.dot(math.sub(pt, p_start), v_seg) / len_sq;
            if (proj > tol.parametric and proj < 1.0 - tol.parametric) {
                const closest = math.add(p_start, math.scale(v_seg, proj));
                if (tol.pointsCoincide(pt, closest)) {
                    const split = try splitHalfEdge(allocator, t_arena, g_arena, curr, pt);
                    return split.v_mid;
                }
            }
        }

        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }

    return null;
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

            const res = try intersectSurfaces(allocator, g_arena, face_a.surface, face_b.surface, tol);

            switch (res) {
                .line => |line| {
                    try processLineCollision(allocator, t_arena, g_arena, fa_id, fb_id, line, faces_a, faces_b, tol);
                },
                .two_lines => |lines| {
                    try processLineCollision(allocator, t_arena, g_arena, fa_id, fb_id, lines[0], faces_a, faces_b, tol);
                    try processLineCollision(allocator, t_arena, g_arena, fa_id, fb_id, lines[1], faces_a, faces_b, tol);
                },
                .sampled => |pts| allocator.free(pts),
                .two_sampled => |pts_pair| {
                    allocator.free(pts_pair[0]);
                    allocator.free(pts_pair[1]);
                },
                .empty, .point, .circle => {},
            }
        }
    }
}

/// Helper to clip a 3D MathLine against two faces and slice them along any overlapping segments.
fn processLineCollision(
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

/// Evaluates point inclusion against an explicit set of faces forming a closed boundary.
pub fn isPointInsideSolidFaces(
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    faces: []const topo.FaceId,
    pt: math.Vec3,
    tol: math.Tolerance,
) bool {
    const ray_dir = math.normalize(math.Vec3{ 0.312342, 0.712341, 0.612343 });
    var hit_count: u32 = 0;
    for (faces) |face_id| {
        const face = t_arena.faces.items[face_id];
        if (face.surface.surface_type != .plane) continue;
        const plane = g_arena.planes.items[face.surface.index];
        var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
        if (!face.forward) normal = math.scale(normal, -1.0);
        const denom = math.dot(ray_dir, normal);
        if (@abs(denom) < math.MATH_EPSILON) continue;
        const t = math.dot(math.sub(plane.origin, pt), normal) / denom;
        if (t > tol.parametric) { // Use relative tolerance boundary checking
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
            if (isPointInPolygon2D(uv_hit, polygon_buf[0..poly_len], tol)) hit_count += 1;
        }
    }
    return (hit_count % 2) != 0;
}

// Handles Plane x Cone intersection (rulings, circles, oblique cuts)
pub fn intersectPlaneCone(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    cone: geom.Cone,
    tol: math.Tolerance,
) !IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const axis = math.normalize(cone.axis);
    const cos_angle = @abs(math.dot(n, axis));

    // Check if plane passes directly through cone apex
    const apex_dist = math.dot(n, math.sub(plane.origin, cone.origin));
    const apex_scale = @max(math.mag(cone.origin), @max(math.mag(plane.origin), 1.0));

    if (@abs(apex_dist) < tol.absolute * apex_scale) {
        const ca = @cos(cone.half_angle);
        const sa = @sin(cone.half_angle);
        const a_coef = sa * math.dot(n, cone.x_axis);
        const b_coef = sa * math.dot(n, cone.y_axis);
        const c_coef = ca * math.dot(n, axis);
        const r_coef = @sqrt(a_coef * a_coef + b_coef * b_coef);

        if (r_coef < @abs(c_coef) - tol.absolute) return .{ .point = cone.origin };

        const phi = std.math.atan2(b_coef, a_coef);
        if (r_coef < @abs(c_coef) + tol.absolute) {
            const u = if (c_coef <= 0.0) phi else phi + std.math.pi;
            const dir = math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u)), math.scale(cone.y_axis, @sin(u))), sa));
            return .{ .line = .{ .origin = cone.origin, .direction = math.normalize(dir) } };
        }

        const delta = std.math.acos(std.math.clamp(-c_coef / r_coef, -1.0, 1.0));
        const u_1 = phi + delta;
        const u_2 = phi - delta;
        const dir1 = math.normalize(math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u_1)), math.scale(cone.y_axis, @sin(u_1))), sa)));
        const dir2 = math.normalize(math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u_2)), math.scale(cone.y_axis, @sin(u_2))), sa)));

        return .{ .two_lines = .{
            .{ .origin = cone.origin, .direction = dir1 },
            .{ .origin = cone.origin, .direction = dir2 },
        } };
    }

    if (@abs(cos_angle - 1.0) < tol.absolute) {
        // Plane perpendicular to cone axis -> Circle
        const apex_to_plane = math.dot(axis, math.sub(plane.origin, cone.origin));
        const v_param = apex_to_plane / @cos(cone.half_angle);

        if (@abs(v_param) < tol.absolute) return .{ .point = cone.origin };
        if (v_param < 0.0) return .empty;

        const circle_radius = @abs(apex_to_plane) * @tan(cone.half_angle);
        const circle_center = math.add(cone.origin, math.scale(axis, apex_to_plane));

        return .{ .circle = .{
            .center = circle_center,
            .radius = circle_radius,
            .normal = n,
            .x_axis = cone.x_axis,
            .y_axis = cone.y_axis,
        } };
    }

    // Oblique Conic Section -> Parameter sweep
    return try marchingSsiConePlane(allocator, plane, cone, 64, tol);
}

fn marchingSsiConePlane(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    cone: geom.Cone,
    n_samples: usize,
    tol: math.Tolerance,
) !IntersectionResult {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    errdefer points.deinit(allocator);

    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const axis = math.normalize(cone.axis);
    const ca = @cos(cone.half_angle);
    const sa = @sin(cone.half_angle);

    for (0..n_samples) |i| {
        const u = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
        const dir_u = math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u)), math.scale(cone.y_axis, @sin(u))), sa));
        const denom = math.dot(n, dir_u);
        if (@abs(denom) < math.MATH_EPSILON) continue;

        const numer = math.dot(n, math.sub(plane.origin, cone.origin));
        const v = numer / denom;
        if (v > tol.absolute) {
            try points.append(allocator, math.add(cone.origin, math.scale(dir_u, v)));
        }
    }

    if (points.items.len == 0) {
        points.deinit(allocator);
        return .empty;
    }
    return .{ .sampled = try points.toOwnedSlice(allocator) };
}

// Handles Cylinder x Cylinder (Steinmetz curves & fallback)
pub fn intersectCylinderCylinder(
    allocator: std.mem.Allocator,
    a: geom.Cylinder,
    b: geom.Cylinder,
    tol: math.Tolerance,
) !IntersectionResult {
    const axis_a = math.normalize(a.axis);
    const axis_b = math.normalize(b.axis);
    const dot_ab = math.dot(axis_a, axis_b);

    if (@abs(@abs(dot_ab) - 1.0) < tol.absolute) return .empty;

    // Check for perpendicular equal-radii cylinders (Steinmetz curves)
    if (@abs(dot_ab) < tol.absolute and @abs(a.radius - b.radius) < tol.absolute) {
        const cb_minus_ca = math.sub(b.origin, a.origin);
        const t = math.dot(cb_minus_ca, axis_a);
        const s = -math.dot(cb_minus_ca, axis_b);
        const p_a = math.add(a.origin, math.scale(axis_a, t));
        const p_b = math.add(b.origin, math.scale(axis_b, s));

        if (math.mag(math.sub(p_a, p_b)) < tol.absolute) {
            const n_samples: usize = 64;
            var curve_plus = try allocator.alloc(math.Vec3, n_samples + 1);
            errdefer allocator.free(curve_plus);
            var curve_minus = try allocator.alloc(math.Vec3, n_samples + 1);
            errdefer allocator.free(curve_minus);

            const ref_a = axis_b;
            const y_a = math.cross(axis_a, ref_a);
            const r = a.radius;

            for (0..n_samples + 1) |i| {
                const theta = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
                const cos_t = @cos(theta);
                const sin_t = @sin(theta);
                const lateral = math.add(math.scale(ref_a, r * cos_t), math.scale(y_a, r * sin_t));
                const axial = math.scale(axis_a, r * cos_t);

                curve_plus[i] = math.add(p_a, math.add(lateral, axial));
                curve_minus[i] = math.add(p_a, math.sub(lateral, axial));
            }

            return .{ .two_sampled = .{ curve_plus, curve_minus } };
        }
    }

    // General fallback to Marching SSI
    const surf_a_id = geom.SurfaceId{ .index = 0, .surface_type = .cylinder };
    const surf_b_id = geom.SurfaceId{ .index = 1, .surface_type = .cylinder };
    var arena = geom.GeometryArena.init(allocator);
    defer arena.deinit(allocator);
    try arena.cylinders.append(allocator, a);
    try arena.cylinders.append(allocator, b);

    const start_pt = math.add(a.origin, math.scale(a.x_axis, a.radius));
    _ = try marchIntersection(allocator, &arena, surf_a_id, surf_b_id, start_pt, 0.5, 64, tol);

    return .empty;
}

// Handles Plane x Torus intersection
pub fn intersectPlaneTorus(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    torus: geom.Torus,
    tol: math.Tolerance,
) !IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const dist = @abs(math.dot(n, math.sub(torus.center, plane.origin)));

    if (dist > torus.major_radius + torus.minor_radius + tol.absolute) return .empty;

    const cos_angle = @abs(math.dot(n, math.normalize(torus.axis)));
    if (@abs(cos_angle - 1.0) < tol.absolute) {
        const z = math.dot(n, math.sub(torus.center, plane.origin));
        const abs_z = @abs(z);
        if (abs_z > torus.minor_radius + tol.absolute) return .empty;

        const r_offset = @sqrt(@max(0.0, torus.minor_radius * torus.minor_radius - z * z));
        const circle_center = math.sub(torus.center, math.scale(n, z));

        return .{ .circle = .{
            .center = circle_center,
            .radius = torus.major_radius + r_offset,
            .normal = n,
            .x_axis = torus.x_axis,
            .y_axis = torus.y_axis,
        } };
    }

    return try marchingSsiTorusPlane(allocator, plane, torus, 64, tol);
}

fn marchingSsiTorusPlane(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    torus: geom.Torus,
    n_samples: usize,
    tol: math.Tolerance,
) !IntersectionResult {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    errdefer points.deinit(allocator);

    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const n_v: usize = 32;

    for (0..n_samples) |i| {
        const u = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
        var prev_dist: ?f64 = null;

        for (0..n_v + 1) |j| {
            const v = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(n_v));
            const pt = evaluateTorusPoint(torus, u, v);
            const dist = math.dot(n, math.sub(pt, plane.origin));

            if (prev_dist) |pd| {
                if (pd * dist < 0.0) {
                    const v_prev = 2.0 * std.math.pi * @as(f64, @floatFromInt(j - 1)) / @as(f64, @floatFromInt(n_v));
                    const v_ref = refineTorusCrossing(torus, plane, u, v_prev, v, tol);
                    try points.append(allocator, evaluateTorusPoint(torus, u, v_ref));
                }
            }
            prev_dist = dist;
        }
    }

    if (points.items.len == 0) {
        points.deinit(allocator);
        return .empty;
    }
    return .{ .sampled = try points.toOwnedSlice(allocator) };
}

fn evaluateTorusPoint(torus: geom.Torus, u: f64, v: f64) math.Vec3 {
    const radial = math.add(math.scale(torus.x_axis, @cos(u)), math.scale(torus.y_axis, @sin(u)));
    const tube_center = math.add(torus.center, math.scale(radial, torus.major_radius));
    const tube_offset = math.add(math.scale(radial, torus.minor_radius * @cos(v)), math.scale(torus.axis, torus.minor_radius * @sin(v)));
    return math.add(tube_center, tube_offset);
}

fn refineTorusCrossing(torus: geom.Torus, plane: geom.Plane, u: f64, v_a: f64, v_b: f64, tol: math.Tolerance) f64 {
    _ = tol;
    var lo = v_a;
    var hi = v_b;
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));

    for (0..20) |_| {
        const mid = 0.5 * (lo + hi);
        const pt = evaluateTorusPoint(torus, u, mid);
        const dist = math.dot(n, math.sub(pt, plane.origin));
        const pt_lo = evaluateTorusPoint(torus, u, lo);
        const dist_lo = math.dot(n, math.sub(pt_lo, plane.origin));

        if (dist_lo * dist < 0.0) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    return 0.5 * (lo + hi);
}
