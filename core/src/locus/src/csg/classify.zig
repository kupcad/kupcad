const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const intersections = @import("intersections.zig");
const types = @import("types.zig");

const FaceAABB = types.FaceAABB;
const FaceClassification = types.FaceClassification;

pub fn orient2D(pa: [2]f64, pb: [2]f64, pc: [2]f64) f64 {
    return (pa[0] - pc[0]) * (pb[1] - pc[1]) - (pa[1] - pc[1]) * (pb[0] - pc[0]);
}

pub fn projectToPlane(pt: math.Vec3, origin: math.Vec3, u_axis: math.Vec3, v_axis: math.Vec3) [2]f64 {
    const v = math.sub(pt, origin);
    return .{ math.dot(v, u_axis), math.dot(v, v_axis) };
}

pub fn calculateFaceArea(t_arena: *const topo.TopologyArena, face_id: topo.FaceId) f64 {
    const face = t_arena.faces.items[face_id];
    var total_area: f64 = 0.0;

    for (0..face.loops_len) |l_off| {
        const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
        const loop = t_arena.loops.items[loop_id];

        var curr_he = loop.first_half_edge;
        var cross_sum = math.Vec3{ 0, 0, 0 };
        var safety: usize = 0;

        while (true) : (safety += 1) {
            if (safety > 10_000) break;
            const he = t_arena.half_edges.items[curr_he];
            const v1 = t_arena.vertices.items[he.start_vertex].point;
            const v2 = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;

            cross_sum = math.add(cross_sum, math.cross(v1, v2));
            curr_he = he.next;
            if (curr_he == loop.first_half_edge) break;
        }
        total_area += 0.5 * math.mag(cross_sum);
    }
    return total_area;
}

pub fn computeFaceAABB(t_arena: *const topo.TopologyArena, face_id: topo.FaceId) FaceAABB {
    var min_b = math.Vec3{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var max_b = math.Vec3{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };

    const face = t_arena.faces.items[face_id];
    for (0..face.loops_len) |l_off| {
        const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
        const loop = t_arena.loops.items[loop_id];
        var curr_he = loop.first_half_edge;
        var safety: usize = 0;
        while (curr_he != topo.NULL_ID and safety < 10000) : (safety += 1) {
            const pt = t_arena.vertices.items[t_arena.half_edges.items[curr_he].start_vertex].point;
            for (0..3) |dim| {
                if (pt[dim] < min_b[dim]) min_b[dim] = pt[dim];
                if (pt[dim] > max_b[dim]) max_b[dim] = pt[dim];
            }
            curr_he = t_arena.half_edges.items[curr_he].next;
            if (curr_he == loop.first_half_edge) break;
        }
    }
    return .{ .face_id = face_id, .min = min_b, .max = max_b };
}

pub fn classifyFace(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    face_id: topo.FaceId,
    target_aabbs: []const FaceAABB,
    tol: math.Tolerance,
) FaceClassification {
    const face = t_arena.faces.items[face_id];
    const outer_loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];

    var normal = math.Vec3{ 0, 0, 1 };
    if (face.surface.surface_type == .plane) {
        const plane = g_arena.planes.items[face.surface.index];
        normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
        if (!face.forward) normal = math.scale(normal, -1.0);
    } else if (face.surface.surface_type == .cylinder) {
        const cyl = g_arena.cylinders.items[face.surface.index];
        const pt_start = t_arena.vertices.items[t_arena.half_edges.items[outer_loop.first_half_edge].start_vertex].point;
        const axis = math.normalize(cyl.axis);
        const v = math.sub(pt_start, cyl.origin);
        const v_proj = math.sub(v, math.scale(axis, math.dot(v, axis)));
        const len = math.mag(v_proj);
        if (len > math.MATH_EPSILON) normal = math.scale(v_proj, 1.0 / len);
        if (!face.forward) normal = math.scale(normal, -1.0);
    } else if (face.surface.surface_type == .nurbs) {
        const surf = &g_arena.nurbs_surfaces.items[face.surface.index];
        const uv = t_arena.getHalfEdgeStartUV(g_arena, outer_loop.first_half_edge);
        const eps = 1e-5;
        const p_u1 = surf.evaluate(uv[0] + eps, uv[1]);
        const p_u0 = surf.evaluate(uv[0] - eps, uv[1]);
        const p_v1 = surf.evaluate(uv[0], uv[1] + eps);
        const p_v0 = surf.evaluate(uv[0], uv[1] - eps);
        const du = math.sub(p_u1, p_u0);
        const dv = math.sub(p_v1, p_v0);
        const n = math.cross(du, dv);
        const n_mag = math.mag(n);
        if (n_mag > 1e-12) normal = math.scale(n, 1.0 / n_mag);
        if (!face.forward) normal = math.scale(normal, -1.0);
    }

    var sample_pt: ?math.Vec3 = null;
    var curr_he = outer_loop.first_half_edge;
    while (true) {
        const he = t_arena.half_edges.items[curr_he];
        const p1 = t_arena.vertices.items[he.start_vertex].point;
        const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;

        const mid = math.scale(math.add(p1, p2), 0.5);
        const tangent = math.normalize(math.sub(p2, p1));

        const inward = math.normalize(math.cross(normal, tangent));

        const nudge_dist = @max(tol.absolute * 10.0, 1e-3);
        const test_3d = math.add(mid, math.scale(inward, nudge_dist));

        const test_uv = g_arena.surfaceProject(face.surface, test_3d);
        if (isPointInFaceUV(allocator, t_arena, g_arena, face_id, test_uv, tol) catch false) {
            sample_pt = test_3d;
            break;
        }
        curr_he = he.next;
        if (curr_he == outer_loop.first_half_edge) break;
    }

    const final_sample = sample_pt orelse blk: {
        var centroid = math.Vec3{ 0, 0, 0 };
        var v_count: f64 = 0.0;
        var c_he = outer_loop.first_half_edge;
        while (true) {
            const he = t_arena.half_edges.items[c_he];
            centroid = math.add(centroid, t_arena.vertices.items[he.start_vertex].point);
            v_count += 1.0;
            c_he = he.next;
            if (c_he == outer_loop.first_half_edge) break;
        }
        break :blk math.scale(centroid, 1.0 / v_count);
    };

    const offset_dist = @max(tol.absolute * 2.0, 1e-5);
    const pt_in = math.sub(final_sample, math.scale(normal, offset_dist));
    const pt_out = math.add(final_sample, math.scale(normal, offset_dist));

    const in_solid = isPointInsideSolidFaces(allocator, t_arena, g_arena, target_aabbs, pt_in, tol) catch false;
    const out_solid = isPointInsideSolidFaces(allocator, t_arena, g_arena, target_aabbs, pt_out, tol) catch false;

    if (in_solid and out_solid) return .inside;
    if (!in_solid and !out_solid) return .outside;
    if (in_solid and !out_solid) return .same;
    return .opposite;
}

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
        .nurbs => {
            if (id.index >= g_arena.nurbs_surfaces.items.len) return pt;
            const surf = &g_arena.nurbs_surfaces.items[id.index];

            var best_uv = math.Vec2{ 0.5, 0.5 };
            var min_d2: f64 = std.math.inf(f64);
            const steps: usize = 8;
            const u_min = surf.knots_u[0];
            const u_max = surf.knots_u[surf.knots_u.len - 1];
            const v_min = surf.knots_v[0];
            const v_max = surf.knots_v[surf.knots_v.len - 1];
            const du = (u_max - u_min) / @as(f64, @floatFromInt(steps));
            const dv = (v_max - v_min) / @as(f64, @floatFromInt(steps));

            for (0..steps + 1) |i| {
                const u = u_min + @as(f64, @floatFromInt(i)) * du;
                for (0..steps + 1) |j| {
                    const v = v_min + @as(f64, @floatFromInt(j)) * dv;
                    const eval_pt = surf.evaluate(u, v);
                    const d2 = math.distSq(pt, eval_pt);
                    if (d2 < min_d2) {
                        min_d2 = d2;
                        best_uv = .{ u, v };
                    }
                }
            }
            return surf.evaluate(best_uv[0], best_uv[1]);
        },
    }
}

pub fn isPointInsideSolid(t_arena: *const topo.TopologyArena, g_arena: *const geom.GeometryArena, solid_id: topo.SolidId, pt: math.Vec3) bool {
    var temp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer temp_arena.deinit();
    const alloc = temp_arena.allocator();

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
    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            faces.append(alloc, t_arena.shell_faces.items[shell.faces_start + f_off]) catch {};
        }
    }

    var aabbs = alloc.alloc(FaceAABB, faces.items.len) catch return false;
    for (faces.items, 0..) |f_id, i| aabbs[i] = computeFaceAABB(t_arena, f_id);

    return isPointInsideSolidFaces(alloc, t_arena, g_arena, aabbs, pt, tol) catch false;
}

pub fn isPointInsideSolidFaces(
    temp_alloc: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    aabbs: []const FaceAABB, // Uses cached AABBs exclusively
    pt: math.Vec3,
    tol: math.Tolerance,
) !bool {
    const rays = [_]math.Vec3{
        math.normalize(.{ 0.31234201, 0.71234103, 0.61234307 }),
        math.normalize(.{ -0.81234105, 0.21234309, 0.54321101 }),
        math.normalize(.{ 0.12345603, -0.91234507, 0.38765401 }),
        math.normalize(.{ -0.45678901, -0.65432103, 0.60123405 }),
        math.normalize(.{ 0.78912307, 0.34567801, -0.51234509 }),
    };

    var inside_votes: u8 = 0;
    var valid_rays: u8 = 0;

    for (rays) |ray_dir| {
        var min_t: f64 = std.math.inf(f64);
        var min_hit_normal: ?math.Vec3 = null;
        var hit_count: u32 = 0;

        for (aabbs) |aabb| {
            var tmin: f64 = 0.0;
            var tmax: f64 = std.math.inf(f64);
            var hit_aabb = true;

            for (0..3) |dim| {
                if (@abs(ray_dir[dim]) < 1e-8) {
                    if (pt[dim] < aabb.min[dim] or pt[dim] > aabb.max[dim]) hit_aabb = false;
                } else {
                    const inv_d = 1.0 / ray_dir[dim];
                    var t0 = (aabb.min[dim] - pt[dim]) * inv_d;
                    var t1 = (aabb.max[dim] - pt[dim]) * inv_d;
                    if (t0 > t1) std.mem.swap(f64, &t0, &t1);
                    if (t0 > tmin) tmin = t0;
                    if (t1 < tmax) tmax = t1;
                    if (tmin > tmax) hit_aabb = false;
                }
            }
            if (!hit_aabb) continue;

            const face = t_arena.faces.items[aabb.face_id];
            switch (face.surface.surface_type) {
                .plane => {
                    const plane = g_arena.planes.items[face.surface.index];
                    var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
                    if (!face.forward) normal = math.scale(normal, -1.0);

                    const denom = math.dot(ray_dir, normal);
                    if (@abs(denom) < math.MATH_EPSILON) continue;

                    const t = math.dot(math.sub(plane.origin, pt), normal) / denom;
                    if (t > tol.absolute) {
                        const hit_pt = math.add(pt, math.scale(ray_dir, t));
                        const uv_hit = projectToPlane(hit_pt, plane.origin, plane.u_axis, plane.v_axis);

                        if (isPointInFaceUV(temp_alloc, t_arena, g_arena, aabb.face_id, uv_hit, tol) catch false) {
                            hit_count += 1;
                            if (t < min_t) {
                                min_t = t;
                                min_hit_normal = normal;
                            }
                        }
                    }
                },
                .cylinder => {
                    const cyl = g_arena.cylinders.items[face.surface.index];
                    const t_hits = intersections.intersectRayCylinder(pt, ray_dir, cyl);

                    for (t_hits) |t_opt| {
                        if (t_opt) |t| {
                            if (t > tol.absolute) {
                                const hit_pt = math.add(pt, math.scale(ray_dir, t));
                                const uv_hit = g_arena.surfaceProject(face.surface, hit_pt);

                                if (isPointInFaceUV(temp_alloc, t_arena, g_arena, aabb.face_id, uv_hit, tol) catch false) {
                                    hit_count += 1;
                                    if (t < min_t) {
                                        min_t = t;
                                        const axis = math.normalize(cyl.axis);
                                        const v = math.sub(hit_pt, cyl.origin);
                                        const v_proj = math.sub(v, math.scale(axis, math.dot(v, axis)));
                                        const len = math.mag(v_proj);

                                        var cyl_normal = if (len > math.MATH_EPSILON) math.scale(v_proj, 1.0 / len) else cyl.x_axis;
                                        if (!face.forward) cyl_normal = math.scale(cyl_normal, -1.0);
                                        min_hit_normal = cyl_normal;
                                    }
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        if (min_hit_normal) |norm| {
            valid_rays += 1;
            const dot_p = math.dot(ray_dir, norm);

            if (dot_p > 1e-4) {
                inside_votes += 1;
            } else if (@abs(dot_p) <= 1e-4) {
                if ((hit_count % 2) != 0) inside_votes += 1;
            }
        } else {
            valid_rays += 1;
        }
    }

    if (valid_rays == 0) return false;
    return (inside_votes * 2) >= valid_rays;
}

pub fn isPointInPolygon2D(pt: [2]f64, polygon: []const [2]f64, tol: math.Tolerance) bool {
    if (polygon.len < 3) return false;

    var centroid = [2]f64{ 0, 0 };
    for (polygon) |p| {
        centroid[0] += p[0];
        centroid[1] += p[1];
    }
    const len_f = @as(f64, @floatFromInt(polygon.len));
    centroid[0] /= len_f;
    centroid[1] /= len_f;

    const eps = tol.parametric;
    const test_pt = [2]f64{
        pt[0] * (1.0 - eps) + centroid[0] * eps,
        pt[1] * (1.0 - eps) + centroid[1] * eps,
    };

    var winding: i32 = 0;
    var j: usize = polygon.len - 1;

    for (0..polygon.len) |i| {
        const pi = polygon[i];
        const pj = polygon[j];

        if (pj[1] <= test_pt[1]) {
            if (pi[1] > test_pt[1]) {
                if (orient2D(pj, pi, test_pt) > 0.0) winding += 1;
            }
        } else {
            if (pi[1] <= test_pt[1]) {
                if (orient2D(pj, pi, test_pt) < 0.0) winding -= 1;
            }
        }
        j = i;
    }
    return winding != 0;
}

pub fn isPointInFaceUV(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    face_id: topo.FaceId,
    pt_uv: [2]f64,
    tol: math.Tolerance,
) !bool {
    const face = t_arena.faces.items[face_id];
    var total_winding: i32 = 0;

    var centroid = [2]f64{ 0, 0 };
    var total_verts: f64 = 0;

    for (0..face.loops_len) |l_off| {
        const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start + l_off]];
        var curr_he = loop.first_half_edge;
        while (true) {
            const he = t_arena.half_edges.items[curr_he];
            const pt3d = t_arena.vertices.items[he.start_vertex].point;
            const uv = g_arena.surfaceProject(face.surface, pt3d);
            centroid[0] += uv[0];
            centroid[1] += uv[1];
            total_verts += 1.0;
            curr_he = he.next;
            if (curr_he == loop.first_half_edge) break;
        }
    }

    if (total_verts > 0) {
        centroid[0] /= total_verts;
        centroid[1] /= total_verts;
    }

    const eps = tol.parametric;
    const test_pt = [2]f64{
        pt_uv[0] * (1.0 - eps) + centroid[0] * eps,
        pt_uv[1] * (1.0 - eps) + centroid[1] * eps,
    };

    for (0..face.loops_len) |l_off| {
        const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
        const loop = t_arena.loops.items[loop_id];

        var poly = std.ArrayListUnmanaged([2]f64).empty;
        defer poly.deinit(allocator);

        var curr_he = loop.first_half_edge;
        while (true) {
            const he = t_arena.half_edges.items[curr_he];
            const pt3d = t_arena.vertices.items[he.start_vertex].point;

            if (he.curve.curve_type == .circle_arc) {
                const arc = g_arena.circle_arcs.items[he.curve.index];
                const p1 = pt3d;
                const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;

                const u_start = math.normalize(math.sub(p1, arc.center));
                const u_end = math.normalize(math.sub(p2, arc.center));
                var ang_start = std.math.atan2(math.dot(u_start, arc.y_axis), math.dot(u_start, arc.x_axis));
                var ang_end = std.math.atan2(math.dot(u_end, arc.y_axis), math.dot(u_end, arc.x_axis));
                if (ang_start < 0) ang_start += 2.0 * std.math.pi;
                if (ang_end < 0) ang_end += 2.0 * std.math.pi;

                var sweep = ang_end - ang_start;
                if (@abs(sweep) < 1e-5) {
                    sweep = if (he.forward) 2.0 * std.math.pi else -2.0 * std.math.pi;
                } else if (he.forward) {
                    if (sweep < 0) sweep += 2.0 * std.math.pi;
                } else {
                    if (sweep > 0) sweep -= 2.0 * std.math.pi;
                }

                const segments: usize = 16;
                for (0..segments) |step| {
                    const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(segments));
                    const ang = ang_start + sweep * t;
                    const radial = math.add(
                        math.scale(arc.x_axis, arc.radius * @cos(ang)),
                        math.scale(arc.y_axis, arc.radius * @sin(ang)),
                    );
                    const sampled_pt = math.add(arc.center, radial);
                    const uv = g_arena.surfaceProject(face.surface, sampled_pt);
                    try poly.append(allocator, .{ uv[0], uv[1] });
                }
            } else {
                const uv = g_arena.surfaceProject(face.surface, pt3d);
                try poly.append(allocator, .{ uv[0], uv[1] });
            }

            curr_he = he.next;
            if (curr_he == loop.first_half_edge) break;
        }

        if (poly.items.len < 3) continue;

        var j: usize = poly.items.len - 1;
        for (0..poly.items.len) |i| {
            const pi = poly.items[i];
            const pj = poly.items[j];

            if (pj[1] <= test_pt[1]) {
                if (pi[1] > test_pt[1]) {
                    if (orient2D(pj, pi, test_pt) > 0.0) total_winding += 1;
                }
            } else {
                if (pi[1] <= test_pt[1]) {
                    if (orient2D(pj, pi, test_pt) < 0.0) total_winding -= 1;
                }
            }
            j = i;
        }
    }

    return @rem(total_winding, 2) != 0;
}
