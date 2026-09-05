const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const sweeps = @import("../sweeps.zig");
const modifiers = @import("modifiers.zig");
const types = @import("types.zig");

pub const BlendOptions = struct {
    setback_start: f64 = 0.0,
    setback_end: f64 = 0.0,
    skip_trim_start: bool = false,
    skip_trim_end: bool = false,
};

pub const BlendResult = struct {
    fillet_face: topo.FaceId,
    new_solid: topo.SolidId,
};

pub const BlendError = error{
    OutOfMemory,
    NonPlanarAdjacentFaces,
    DegenerateEdge,
    TopologyCorrupted,
};

fn getFaceContainingHalfEdge(t_arena: *const topo.TopologyArena, he_id: topo.HalfEdgeId) topo.FaceId {
    return t_arena.loops.items[t_arena.half_edges.items[he_id].loop_id].face_id;
}

fn containsVertex(t_arena: *const topo.TopologyArena, face_id: topo.FaceId, v_id: topo.VertexId) bool {
    const face = t_arena.faces.items[face_id];
    for (0..face.loops_len) |l_off| {
        const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start + l_off]];
        var curr = loop.first_half_edge;
        var safety: usize = 0;
        while (true) : (safety += 1) {
            if (safety > 10_000) return false;
            if (t_arena.half_edges.items[curr].start_vertex == v_id) return true;
            curr = t_arena.half_edges.items[curr].next;
            if (curr == loop.first_half_edge) break;
        }
    }
    return false;
}

fn replaceShellFaces(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    solid_id: topo.SolidId,
    remove_faces: []const topo.FaceId,
    add_faces: []const topo.FaceId,
) !void {
    const solid = t_arena.solids.items[solid_id];
    const shell_id = t_arena.solid_shells.items[solid.shells_start];
    var shell = &t_arena.shells.items[shell_id];

    var updated_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer updated_faces.deinit(allocator);

    for (0..shell.faces_len) |f_off| {
        const f_id = t_arena.shell_faces.items[shell.faces_start + f_off];
        var keep = true;
        for (remove_faces) |r_id| {
            if (f_id == r_id) {
                keep = false;
                break;
            }
        }
        if (keep) try updated_faces.append(allocator, f_id);
    }

    try updated_faces.appendSlice(allocator, add_faces);

    const new_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.appendSlice(allocator, updated_faces.items);

    shell.faces_start = new_start;
    shell.faces_len = @intCast(updated_faces.items.len);
}

pub fn createConstantFilletSurface(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    he_id: topo.HalfEdgeId,
    radius: f64,
) BlendError!u32 {
    const he = t_arena.half_edges.items[he_id];
    if (he.twin == topo.NULL_ID) return error.DegenerateEdge;

    const twin = t_arena.half_edges.items[he.twin];

    const face_a = t_arena.faces.items[t_arena.loops.items[he.loop_id].face_id];
    const face_b = t_arena.faces.items[t_arena.loops.items[twin.loop_id].face_id];

    if (face_a.surface.surface_type != .plane or face_b.surface.surface_type != .plane) {
        return error.NonPlanarAdjacentFaces;
    }

    const plane_a = g_arena.planes.items[face_a.surface.index];
    var n_a = math.normalize(math.cross(plane_a.u_axis, plane_a.v_axis));
    if (!face_a.forward) n_a = math.scale(n_a, -1.0);

    const plane_b = g_arena.planes.items[face_b.surface.index];
    var n_b = math.normalize(math.cross(plane_b.u_axis, plane_b.v_axis));
    if (!face_b.forward) n_b = math.scale(n_b, -1.0);

    const p_start = t_arena.vertices.items[he.start_vertex].point;
    const p_end = t_arena.vertices.items[twin.start_vertex].point;
    const tangent = math.normalize(math.sub(p_end, p_start));

    const v_a = math.normalize(math.cross(n_a, tangent));
    const v_b = math.normalize(math.cross(tangent, n_b));

    const cos_theta = std.math.clamp(math.dot(n_a, n_b), -1.0, 1.0);
    const theta = std.math.acos(cos_theta);
    const d = radius * @tan(theta / 2.0);

    const pt_a = math.add(p_start, math.scale(v_a, d));
    const pt_b = math.add(p_start, math.scale(v_b, d));

    const frames = try sweeps.generateRMF(allocator, g_arena, he.curve, 2);
    defer allocator.free(frames);
    const f0 = frames[0];

    const local_a = math.Vec2{ math.dot(math.sub(pt_a, f0.origin), f0.normal), math.dot(math.sub(pt_a, f0.origin), f0.binormal) };
    const local_corner = math.Vec2{ 0.0, 0.0 };
    const local_b = math.Vec2{ math.dot(math.sub(pt_b, f0.origin), f0.normal), math.dot(math.sub(pt_b, f0.origin), f0.binormal) };

    const weight_mid = @cos(theta / 2.0);
    var arc_cps = [_]math.Vec4{
        .{ local_a[0], local_a[1], 0.0, 1.0 },
        .{ local_corner[0] * weight_mid, local_corner[1] * weight_mid, 0.0, weight_mid },
        .{ local_b[0], local_b[1], 0.0, 1.0 },
    };
    var arc_knots = [_]f64{ 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 };

    const arc_profile = geom.NurbsCurve{
        .degree = 2,
        .knots = &arc_knots,
        .control_points = &arc_cps,
    };

    const samples = 16;
    return sweeps.sweepProfileAlongCurve(allocator, g_arena, arc_profile, he.curve, samples);
}

pub fn findSharedHalfEdge(
    t_arena: *const topo.TopologyArena,
    face_a: topo.FaceId,
    face_b: topo.FaceId,
) ?topo.HalfEdgeId {
    const f_a = t_arena.faces.items[face_a];
    var best_he: ?topo.HalfEdgeId = null;
    var max_len_sq: f64 = -1.0;

    for (0..f_a.loops_len) |l_off| {
        const loop = t_arena.loops.items[t_arena.face_loops.items[f_a.loops_start + l_off]];
        var curr = loop.first_half_edge;

        var safety: usize = 0;
        while (true) : (safety += 1) {
            if (safety > 10_000) return null;

            const he = t_arena.half_edges.items[curr];
            if (he.twin != topo.NULL_ID) {
                const twin_he = t_arena.half_edges.items[he.twin];
                const twin_face = t_arena.loops.items[twin_he.loop_id].face_id;
                if (twin_face == face_b) {
                    const p1 = t_arena.vertices.items[he.start_vertex].point;
                    const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;
                    const len_sq = math.distSq(p1, p2);
                    if (len_sq > max_len_sq) {
                        max_len_sq = len_sq;
                        best_he = curr;
                    }
                }
            }

            curr = he.next;
            if (curr == loop.first_half_edge) break;
        }
    }
    return best_he;
}

fn weaveFilletTopology(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    fillet_face: topo.FaceId,
    rail_a: topo.HalfEdgeId,
    rail_b: topo.HalfEdgeId,
    p_start: math.Vec3,
) !struct { cap_start: topo.HalfEdgeId, cap_end: topo.HalfEdgeId } {
    const he_a = t_arena.half_edges.items[rail_a];
    const he_b = t_arena.half_edges.items[rail_b];

    const p_a_start = t_arena.vertices.items[he_a.start_vertex].point;
    const p_a_next = t_arena.vertices.items[t_arena.half_edges.items[he_a.next].start_vertex].point;
    const a_starts_near_p_start = math.distSq(p_a_start, p_start) < math.distSq(p_a_next, p_start);

    const v_a_p_start = if (a_starts_near_p_start) he_a.start_vertex else t_arena.half_edges.items[he_a.next].start_vertex;
    const v_a_p_end = if (a_starts_near_p_start) t_arena.half_edges.items[he_a.next].start_vertex else he_a.start_vertex;

    const p_b_start = t_arena.vertices.items[he_b.start_vertex].point;
    const p_b_next = t_arena.vertices.items[t_arena.half_edges.items[he_b.next].start_vertex].point;
    const b_starts_near_p_start = math.distSq(p_b_start, p_start) < math.distSq(p_b_next, p_start);

    const v_b_p_start = if (b_starts_near_p_start) he_b.start_vertex else t_arena.half_edges.items[he_b.next].start_vertex;
    const v_b_p_end = if (b_starts_near_p_start) t_arena.half_edges.items[he_b.next].start_vertex else he_b.start_vertex;

    const cap_start_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{
        .start = t_arena.vertices.items[v_a_p_start].point,
        .end = t_arena.vertices.items[v_b_p_start].point,
    });

    const cap_end_idx: u24 = @intCast(g_arena.lines.items.len);
    try g_arena.lines.append(allocator, .{
        .start = t_arena.vertices.items[v_b_p_end].point,
        .end = t_arena.vertices.items[v_a_p_end].point,
    });

    const loop_id: u32 = @intCast(t_arena.loops.items.len);
    const start_he: u32 = @intCast(t_arena.half_edges.items.len);

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_a_p_end,
        .twin = rail_a,
        .next = start_he + 1,
        .prev = start_he + 3,
        .loop_id = loop_id,
        .curve = he_a.curve,
        .forward = !he_a.forward,
    });
    t_arena.half_edges.items[rail_a].twin = start_he;

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_a_p_start,
        .twin = topo.NULL_ID,
        .next = start_he + 2,
        .prev = start_he,
        .loop_id = loop_id,
        .curve = .{ .index = cap_start_idx, .curve_type = .line },
        .forward = true,
    });

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_b_p_start,
        .twin = rail_b,
        .next = start_he + 3,
        .prev = start_he + 1,
        .loop_id = loop_id,
        .curve = he_b.curve,
        .forward = !he_b.forward,
    });
    t_arena.half_edges.items[rail_b].twin = start_he + 2;

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = v_b_p_end,
        .twin = topo.NULL_ID,
        .next = start_he,
        .prev = start_he + 2,
        .loop_id = loop_id,
        .curve = .{ .index = cap_end_idx, .curve_type = .line },
        .forward = true,
    });

    try t_arena.loops.append(allocator, .{ .face_id = fillet_face, .first_half_edge = start_he });
    const fl_start: u32 = @intCast(t_arena.face_loops.items.len);
    try t_arena.face_loops.append(allocator, loop_id);

    t_arena.faces.items[fillet_face].loops_start = fl_start;
    t_arena.faces.items[fillet_face].loops_len = 1;

    return .{ .cap_start = start_he + 1, .cap_end = start_he + 3 };
}

/// Helper that dynamically selects the split rail half-edge that points TOWARDS the target coordinate.
/// This prevents topological corruption caused by assuming loop parity assignments.
fn pickFilletSegment(
    t_arena: *topo.TopologyArena,
    he_old: topo.HalfEdgeId,
    he_new: topo.HalfEdgeId,
    v_mid: topo.VertexId,
    p_target: math.Vec3,
) topo.HalfEdgeId {
    const he_old_v = t_arena.half_edges.items[he_old].start_vertex;
    const he_old_start = t_arena.vertices.items[he_old_v].point;
    const p_mid = t_arena.vertices.items[v_mid].point;

    const next_he = t_arena.half_edges.items[he_new].next;
    const he_new_v_end = t_arena.half_edges.items[next_he].start_vertex;
    const p_new_end = t_arena.vertices.items[he_new_v_end].point;

    const mid_old = math.scale(math.add(he_old_start, p_mid), 0.5);
    const mid_new = math.scale(math.add(p_mid, p_new_end), 0.5);

    if (math.distSq(mid_new, p_target) < math.distSq(mid_old, p_target)) {
        return he_new;
    }
    return he_old;
}

pub fn applyEdgeBlendEx(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    he_id: topo.HalfEdgeId,
    radius: f64,
    options: BlendOptions,
) BlendError!BlendResult {
    const he = t_arena.half_edges.items[he_id];
    if (he.twin == topo.NULL_ID) return error.DegenerateEdge;

    const twin = t_arena.half_edges.items[he.twin];
    const face_a_id = t_arena.loops.items[he.loop_id].face_id;
    const face_b_id = t_arena.loops.items[twin.loop_id].face_id;
    const face_a = t_arena.faces.items[face_a_id];
    const face_b = t_arena.faces.items[face_b_id];

    const surf_idx = try createConstantFilletSurface(allocator, t_arena, g_arena, he_id, radius);

    const plane_a = g_arena.planes.items[face_a.surface.index];
    var n_a = math.normalize(math.cross(plane_a.u_axis, plane_a.v_axis));
    if (!face_a.forward) n_a = math.scale(n_a, -1.0);

    const plane_b = g_arena.planes.items[face_b.surface.index];
    var n_b = math.normalize(math.cross(plane_b.u_axis, plane_b.v_axis));
    if (!face_b.forward) n_b = math.scale(n_b, -1.0);

    const cos_theta = std.math.clamp(math.dot(n_a, n_b), -1.0, 1.0);
    const d = radius * @tan(std.math.acos(cos_theta) / 2.0);

    const p_start = t_arena.vertices.items[he.start_vertex].point;
    const p_end = t_arena.vertices.items[twin.start_vertex].point;
    const tangent = math.normalize(math.sub(p_end, p_start));

    const p_start_eff = math.add(p_start, math.scale(tangent, options.setback_start));
    const p_end_eff = math.sub(p_end, math.scale(tangent, options.setback_end));

    const v_a = math.normalize(math.cross(n_a, tangent));
    const v_b = math.normalize(math.cross(tangent, n_b));

    const line_a = types.MathLine{
        .origin = math.add(p_start, math.scale(v_a, d)),
        .direction = tangent,
    };

    const line_b = types.MathLine{
        .origin = math.add(p_start, math.scale(v_b, d)),
        .direction = tangent,
    };

    const tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };

    const segs_a = try modifiers.clipMathLineToFace(allocator, t_arena, g_arena, face_a_id, line_a, tol);
    defer allocator.free(segs_a);

    const segs_b = try modifiers.clipMathLineToFace(allocator, t_arena, g_arena, face_b_id, line_b, tol);
    defer allocator.free(segs_b);

    if (segs_a.len == 0 or segs_b.len == 0) return error.TopologyCorrupted;

    const new_fa_opt = try modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, face_a_id, segs_a[0], tol);
    const new_fb_opt = try modifiers.sliceFaceWithSegment(allocator, t_arena, g_arena, face_b_id, segs_b[0], tol);

    const v_corner_start = t_arena.half_edges.items[he_id].start_vertex;
    const v_corner_end = twin.start_vertex;

    var rail_a = he_id;
    var keep_fa = face_a_id;
    var strip_fa = face_a_id;

    if (new_fa_opt) |fa| {
        const fa_is_main = !containsVertex(t_arena, fa, v_corner_start);
        keep_fa = if (fa_is_main) fa else face_a_id;
        strip_fa = if (fa_is_main) face_a_id else fa;
        rail_a = findSharedHalfEdge(t_arena, keep_fa, strip_fa) orelse he_id;
    }

    var rail_b = he.twin;
    var keep_fb = face_b_id;
    var strip_fb = face_b_id;

    if (new_fb_opt) |fb| {
        const fb_is_main = !containsVertex(t_arena, fb, v_corner_start);
        keep_fb = if (fb_is_main) fb else face_b_id;
        strip_fb = if (fb_is_main) face_b_id else fb;
        rail_b = findSharedHalfEdge(t_arena, keep_fb, strip_fb) orelse he.twin;
    }

    if (options.setback_start > 0.0) {
        const pt_split_a = math.add(p_start_eff, math.scale(v_a, d));
        const split_a = try modifiers.splitHalfEdge(allocator, t_arena, g_arena, rail_a, pt_split_a, tol.absolute);
        rail_a = pickFilletSegment(t_arena, rail_a, split_a.he_new, split_a.v_mid, p_end);

        const pt_split_b = math.add(p_start_eff, math.scale(v_b, d));
        const split_b = try modifiers.splitHalfEdge(allocator, t_arena, g_arena, rail_b, pt_split_b, tol.absolute);
        rail_b = pickFilletSegment(t_arena, rail_b, split_b.he_new, split_b.v_mid, p_end);
    }

    if (options.setback_end > 0.0) {
        const pt_split_a = math.add(p_end_eff, math.scale(v_a, d));
        const split_a = try modifiers.splitHalfEdge(allocator, t_arena, g_arena, rail_a, pt_split_a, tol.absolute);
        rail_a = pickFilletSegment(t_arena, rail_a, split_a.he_new, split_a.v_mid, p_start);

        const pt_split_b = math.add(p_end_eff, math.scale(v_b, d));
        const split_b = try modifiers.splitHalfEdge(allocator, t_arena, g_arena, rail_b, pt_split_b, tol.absolute);
        rail_b = pickFilletSegment(t_arena, rail_b, split_b.he_new, split_b.v_mid, p_start);
    }

    const fillet_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.faces.append(allocator, .{
        .surface = .{ .index = @intCast(surf_idx), .surface_type = .nurbs },
        .forward = true,
        .loops_start = 0,
        .loops_len = 0,
    });

    const caps = try weaveFilletTopology(allocator, t_arena, g_arena, fillet_face_id, rail_a, rail_b, p_start);

    var remove_shell_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer remove_shell_faces.deinit(allocator);

    var add_shell_faces = std.ArrayListUnmanaged(topo.FaceId).empty;
    defer add_shell_faces.deinit(allocator);

    if (new_fa_opt != null) {
        try remove_shell_faces.append(allocator, strip_fa);
        if (keep_fa != face_a_id) try add_shell_faces.append(allocator, keep_fa);
    }
    if (new_fb_opt != null) {
        try remove_shell_faces.append(allocator, strip_fb);
        if (keep_fb != face_b_id) try add_shell_faces.append(allocator, keep_fb);
    }
    try add_shell_faces.append(allocator, fillet_face_id);

    try replaceShellFaces(allocator, t_arena, solid_id, remove_shell_faces.items, add_shell_faces.items);

    if (options.setback_start == 0.0 and !options.skip_trim_start) {
        try modifiers.trimOrthogonalCap(allocator, t_arena, solid_id, v_corner_start, caps.cap_start);
    }
    if (options.setback_end == 0.0 and !options.skip_trim_end) {
        try modifiers.trimOrthogonalCap(allocator, t_arena, solid_id, v_corner_end, caps.cap_end);
    }

    return .{ .fillet_face = fillet_face_id, .new_solid = solid_id };
}

pub fn applyEdgeBlend(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    he_id: topo.HalfEdgeId,
    radius: f64,
) BlendError!BlendResult {
    return applyEdgeBlendEx(allocator, t_arena, g_arena, solid_id, he_id, radius, .{});
}

pub fn createCornerSetbackPatch(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    p_corner: math.Vec3,
    radius: f64,
    normals: [3]math.Vec3,
) !u32 {
    const n_sum = math.normalize(math.add(normals[0], math.add(normals[1], normals[2])));
    const offset_dist = radius * std.math.sqrt(3.0);
    const sphere_center = math.sub(p_corner, math.scale(n_sum, offset_dist));

    const pt0 = math.add(p_corner, math.scale(normals[0], -radius));
    const pt1 = math.add(p_corner, math.scale(normals[1], -radius));
    const pt2 = math.add(p_corner, math.scale(normals[2], -radius));

    var cps = try allocator.alloc(math.Vec4, 9);
    defer allocator.free(cps);

    const w_corner = 0.7071067811865476;

    cps[0] = .{ pt0[0], pt0[1], pt0[2], 1.0 };
    cps[1] = .{ p_corner[0] * w_corner, p_corner[1] * w_corner, p_corner[2] * w_corner, w_corner };
    cps[2] = .{ pt1[0], pt1[1], pt1[2], 1.0 };

    cps[3] = .{ pt0[0] * 0.5, pt0[1] * 0.5, pt0[2] * 0.5, 0.5 };
    cps[4] = .{ sphere_center[0] * w_corner, sphere_center[1] * w_corner, sphere_center[2] * w_corner, w_corner };
    cps[5] = .{ pt1[0] * 0.5, pt1[1] * 0.5, pt1[2] * 0.5, 0.5 };

    cps[6] = .{ pt2[0], pt2[1], pt2[2], 1.0 };
    cps[7] = .{ pt2[0] * w_corner, pt2[1] * w_corner, pt2[2] * w_corner, w_corner };
    cps[8] = .{ pt2[0], pt2[1], pt2[2], 1.0 };

    var knots = [_]f64{ 0.0, 0.0, 0.0, 1.0, 1.0, 1.0 };

    const surf_idx: u24 = @intCast(g_arena.nurbs_surfaces.items.len);
    try g_arena.nurbs_surfaces.append(allocator, .{
        .degree_u = 2,
        .degree_v = 2,
        .knots_u = try allocator.dupe(f64, &knots),
        .knots_v = try allocator.dupe(f64, &knots),
        .num_cp_u = 3,
        .num_cp_v = 3,
        .control_points = try allocator.dupe(math.Vec4, cps),
    });

    return surf_idx;
}

pub fn applyCornerSetback3Way(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    v_corner: topo.VertexId,
    radius: f64,
) BlendError!topo.FaceId {
    const p_corner = t_arena.vertices.items[v_corner].point;

    var cap_hes = std.ArrayListUnmanaged(topo.HalfEdgeId).empty;
    defer cap_hes.deinit(allocator);

    const search_radius_sq = (radius * 4.0) * (radius * 4.0);

    for (t_arena.half_edges.items, 0..) |he, i| {
        if (he.twin == topo.NULL_ID) {
            const p_start = t_arena.vertices.items[he.start_vertex].point;
            if (math.distSq(p_start, p_corner) < search_radius_sq) {
                try cap_hes.append(allocator, @intCast(i));
            }
        }
    }

    if (cap_hes.items.len < 3) return error.TopologyCorrupted;

    const normals = [_]math.Vec3{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    };

    const surf_idx = try createCornerSetbackPatch(allocator, g_arena, p_corner, radius, normals);

    const setback_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.faces.append(allocator, .{
        .surface = .{ .index = @intCast(surf_idx), .surface_type = .nurbs },
        .forward = true,
        .loops_start = 0,
        .loops_len = 0,
    });

    const loop_id: u32 = @intCast(t_arena.loops.items.len);
    const start_he: u32 = @intCast(t_arena.half_edges.items.len);

    const c0 = cap_hes.items[0];
    const c1 = cap_hes.items[1];
    const c2 = cap_hes.items[2];

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = t_arena.half_edges.items[c0].start_vertex,
        .twin = c0,
        .next = start_he + 1,
        .prev = start_he + 2,
        .loop_id = loop_id,
        .curve = t_arena.half_edges.items[c0].curve,
        .forward = !t_arena.half_edges.items[c0].forward,
    });
    t_arena.half_edges.items[c0].twin = start_he;

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = t_arena.half_edges.items[c1].start_vertex,
        .twin = c1,
        .next = start_he + 2,
        .prev = start_he,
        .loop_id = loop_id,
        .curve = t_arena.half_edges.items[c1].curve,
        .forward = !t_arena.half_edges.items[c1].forward,
    });
    t_arena.half_edges.items[c1].twin = start_he + 1;

    try t_arena.half_edges.append(allocator, .{
        .start_vertex = t_arena.half_edges.items[c2].start_vertex,
        .twin = c2,
        .next = start_he,
        .prev = start_he + 1,
        .loop_id = loop_id,
        .curve = t_arena.half_edges.items[c2].curve,
        .forward = !t_arena.half_edges.items[c2].forward,
    });
    t_arena.half_edges.items[c2].twin = start_he + 2;

    try t_arena.loops.append(allocator, .{ .face_id = setback_face_id, .first_half_edge = start_he });
    const fl_start: u32 = @intCast(t_arena.face_loops.items.len);
    try t_arena.face_loops.append(allocator, loop_id);

    t_arena.faces.items[setback_face_id].loops_start = fl_start;
    t_arena.faces.items[setback_face_id].loops_len = 1;

    try replaceShellFaces(allocator, t_arena, solid_id, &[_]topo.FaceId{}, &[_]topo.FaceId{setback_face_id});

    return setback_face_id;
}
