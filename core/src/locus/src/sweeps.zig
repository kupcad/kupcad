const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const generators = @import("generators.zig");

pub const SweepError = error{
    OutOfMemory,
    InvalidFace,
};

pub const Frame = struct {
    origin: math.Vec3,
    tangent: math.Vec3,
    normal: math.Vec3,
    binormal: math.Vec3,
};

pub fn extrudeFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    base_solid_id: topo.SolidId,
    vec: math.Vec3,
) SweepError!topo.SolidId {
    const s = t_arena.solids.items[base_solid_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[s.shells_start]];
    const base_face_id = t_arena.shell_faces.items[shell.faces_start];
    const base_face = t_arena.faces.items[base_face_id];

    var twin_map = std.AutoHashMap(generators.EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);

    var bot_loops = std.ArrayListUnmanaged([]topo.VertexId).empty;
    defer {
        for (bot_loops.items) |arr| allocator.free(arr);
        bot_loops.deinit(allocator);
    }
    var top_loops = std.ArrayListUnmanaged([]topo.VertexId).empty;
    defer {
        for (top_loops.items) |arr| allocator.free(arr);
        top_loops.deinit(allocator);
    }

    var num_side_faces: u32 = 0;

    for (0..base_face.loops_len) |l_off| {
        const loop = t_arena.loops.items[t_arena.face_loops.items[base_face.loops_start + l_off]];
        var base_pts = std.ArrayListUnmanaged(topo.VertexId).empty;
        defer base_pts.deinit(allocator);
        var curr_he = loop.first_half_edge;
        while (true) {
            const he = t_arena.half_edges.items[curr_he];
            try base_pts.append(allocator, he.start_vertex);
            curr_he = he.next;
            if (curr_he == loop.first_half_edge) break;
        }
        const n = base_pts.items.len;

        var bot_verts = try allocator.alloc(topo.VertexId, n);
        var top_verts = try allocator.alloc(topo.VertexId, n);

        for (0..n) |i| {
            const p_base = t_arena.vertices.items[base_pts.items[i]].point;
            bot_verts[i] = @intCast(t_arena.vertices.items.len);
            try t_arena.vertices.append(allocator, .{ .point = p_base });

            top_verts[i] = @intCast(t_arena.vertices.items.len);
            try t_arena.vertices.append(allocator, .{ .point = math.add(p_base, vec) });
        }

        var bot_rev = try allocator.alloc(topo.VertexId, n);
        for (0..n) |i| bot_rev[i] = bot_verts[n - 1 - i];

        // Side Quads
        for (0..n) |i| {
            const next_i = (i + 1) % n;
            const quad = [_]topo.VertexId{ bot_verts[i], bot_verts[next_i], top_verts[next_i], top_verts[i] };
            const side_plane_idx: u24 = @intCast(g_arena.planes.items.len);
            const p0 = t_arena.vertices.items[bot_verts[i]].point;
            const p1 = t_arena.vertices.items[bot_verts[next_i]].point;
            const p2 = t_arena.vertices.items[top_verts[next_i]].point;
            const u_ax = math.normalize(math.sub(p1, p0));
            var v_ax = math.normalize(math.sub(p2, p1));
            if (math.magSq(v_ax) < 1e-6) v_ax = .{ 0, 0, 1 };
            try g_arena.planes.append(allocator, .{ .origin = p0, .u_axis = u_ax, .v_axis = v_ax });

            const side_f = try generators.addPolygonFace(allocator, t_arena, g_arena, &quad, .{ .index = side_plane_idx, .surface_type = .plane }, &twin_map);
            try t_arena.shell_faces.append(allocator, side_f);
            num_side_faces += 1;
        }

        allocator.free(bot_verts);
        try bot_loops.append(allocator, bot_rev);
        try top_loops.append(allocator, top_verts);
    }

    const bot_plane_idx: u24 = @intCast(g_arena.planes.items.len);
    const orig_plane = g_arena.planes.items[base_face.surface.index];
    try g_arena.planes.append(allocator, .{ .origin = orig_plane.origin, .u_axis = orig_plane.u_axis, .v_axis = math.scale(orig_plane.v_axis, -1.0) });
    const bot_f = try generators.addMultiLoopFace(allocator, t_arena, g_arena, bot_loops.items, .{ .index = bot_plane_idx, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(allocator, bot_f);

    const top_plane_idx: u24 = @intCast(g_arena.planes.items.len);
    try g_arena.planes.append(allocator, .{ .origin = math.add(orig_plane.origin, vec), .u_axis = orig_plane.u_axis, .v_axis = orig_plane.v_axis });
    const top_f = try generators.addMultiLoopFace(allocator, t_arena, g_arena, top_loops.items, .{ .index = top_plane_idx, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(allocator, top_f);

    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = num_side_faces + 2 });
    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

pub fn revolveFace(
    allocator: std.mem.Allocator,
    out_t_arena: *topo.TopologyArena,
    out_g_arena: *geom.GeometryArena,
    in_t_arena: *const topo.TopologyArena,
    base_face_id: topo.FaceId,
    segments: u32,
    degrees: f64,
) !topo.SolidId {
    var profile_pts = std.ArrayListUnmanaged([3]f64).empty;
    defer profile_pts.deinit(allocator);

    const face = in_t_arena.faces.items[base_face_id];
    const loop = in_t_arena.loops.items[in_t_arena.face_loops.items[face.loops_start]];

    var curr = loop.first_half_edge;
    while (true) {
        const he = in_t_arena.half_edges.items[curr];
        const pt = in_t_arena.vertices.items[he.start_vertex].point;
        try profile_pts.append(allocator, .{ pt[0], pt[1], pt[2] });
        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }

    var all_pts = std.ArrayListUnmanaged([3]f64).empty;
    defer all_pts.deinit(allocator);
    var all_faces = std.ArrayListUnmanaged([3]u32).empty;
    defer all_faces.deinit(allocator);

    const rad_step = (degrees * std.math.pi / 180.0) / @as(f64, @floatFromInt(segments));
    const num_pts = @as(u32, @intCast(profile_pts.items.len));

    for (0..segments + 1) |layer| {
        const angle = @as(f64, @floatFromInt(layer)) * rad_step;
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        for (profile_pts.items) |p| {
            try all_pts.append(allocator, .{ p[0] * cos_a + p[2] * sin_a, p[1], -p[0] * sin_a + p[2] * cos_a });
        }
    }

    for (0..segments) |layer| {
        for (0..num_pts) |p| {
            const next_p = (p + 1) % num_pts;
            const v0 = @as(u32, @intCast(layer)) * num_pts + @as(u32, @intCast(p));
            const v1 = @as(u32, @intCast(layer)) * num_pts + @as(u32, @intCast(next_p));
            const v2 = @as(u32, @intCast(layer + 1)) * num_pts + @as(u32, @intCast(next_p));
            const v3 = @as(u32, @intCast(layer + 1)) * num_pts + @as(u32, @intCast(p));

            try all_faces.append(allocator, .{ v0, v3, v2 });
            try all_faces.append(allocator, .{ v0, v2, v1 });
        }
    }

    if (degrees < 359.99) {
        for (1..num_pts - 1) |p| {
            try all_faces.append(allocator, .{ 0, @as(u32, @intCast(p)), @as(u32, @intCast(p + 1)) });
            const end_offset = @as(u32, @intCast(segments)) * num_pts;
            try all_faces.append(allocator, .{ end_offset, end_offset + @as(u32, @intCast(p + 1)), end_offset + @as(u32, @intCast(p)) });
        }
    }

    return generators.buildPolyhedron(allocator, out_t_arena, out_g_arena, all_pts.items, all_faces.items);
}

// Simple linear resampler to ensure topological parity between dissimilar profiles
fn resamplePolygon(allocator: std.mem.Allocator, pts: []const [2]f64, target_len: usize) ![]const [2]f64 {
    if (pts.len == target_len) return allocator.dupe([2]f64, pts);
    var new_pts = try allocator.alloc([2]f64, target_len);
    for (0..target_len) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(target_len));
        const scaled = t * @as(f64, @floatFromInt(pts.len));
        const idx = @as(usize, @intFromFloat(scaled));
        const next_idx = (idx + 1) % pts.len;
        const fract = scaled - @as(f64, @floatFromInt(idx));
        new_pts[i] = .{
            pts[idx][0] * (1.0 - fract) + pts[next_idx][0] * fract,
            pts[idx][1] * (1.0 - fract) + pts[next_idx][1] * fract,
        };
    }
    return new_pts;
}

pub fn loftPolygons(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    base_pts_in: []const [2]f64,
    top_pts_in: []const [2]f64,
    height: f64,
) SweepError!topo.SolidId {
    if (base_pts_in.len < 3 or top_pts_in.len < 3) return error.InvalidFace;
    const n = @max(base_pts_in.len, top_pts_in.len);

    // Resample both profiles to match the highest vertex count
    const base_pts = resamplePolygon(allocator, base_pts_in, n) catch return error.OutOfMemory;
    defer allocator.free(base_pts);
    const top_pts = resamplePolygon(allocator, top_pts_in, n) catch return error.OutOfMemory;
    defer allocator.free(top_pts);

    var twin_map = std.AutoHashMap(generators.EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    var num_side_faces: u32 = 0;

    var bot_verts = allocator.alloc(topo.VertexId, n) catch return error.OutOfMemory;
    defer allocator.free(bot_verts);
    var top_verts = allocator.alloc(topo.VertexId, n) catch return error.OutOfMemory;
    defer allocator.free(top_verts);

    for (0..n) |i| {
        bot_verts[i] = @intCast(t_arena.vertices.items.len);
        t_arena.vertices.append(allocator, .{ .point = .{ base_pts[i][0], base_pts[i][1], 0.0 } }) catch return error.OutOfMemory;

        top_verts[i] = @intCast(t_arena.vertices.items.len);
        t_arena.vertices.append(allocator, .{ .point = .{ top_pts[i][0], top_pts[i][1], height } }) catch return error.OutOfMemory;
    }

    // Reverse bottom vertices to face outward (-Z)
    var bot_rev = allocator.alloc(topo.VertexId, n) catch return error.OutOfMemory;
    defer allocator.free(bot_rev);
    for (0..n) |i| bot_rev[i] = bot_verts[n - 1 - i];

    // Side Quads (Skinning)
    for (0..n) |i| {
        const next_i = (i + 1) % n;
        const quad = [_]topo.VertexId{ bot_verts[i], bot_verts[next_i], top_verts[next_i], top_verts[i] };
        const side_plane_idx: u24 = @intCast(g_arena.planes.items.len);
        const p0 = t_arena.vertices.items[bot_verts[i]].point;
        const p1 = t_arena.vertices.items[bot_verts[next_i]].point;
        const p2 = t_arena.vertices.items[top_verts[next_i]].point;

        const u_ax = math.normalize(math.sub(p1, p0));
        var v_ax = math.normalize(math.sub(p2, p1));
        if (math.magSq(v_ax) < 1e-6) v_ax = .{ 0, 0, 1 };

        g_arena.planes.append(allocator, .{ .origin = p0, .u_axis = u_ax, .v_axis = v_ax }) catch return error.OutOfMemory;
        const side_f = generators.addPolygonFace(allocator, t_arena, g_arena, &quad, .{ .index = side_plane_idx, .surface_type = .plane }, &twin_map) catch return error.OutOfMemory;
        t_arena.shell_faces.append(allocator, side_f) catch return error.OutOfMemory;
        num_side_faces += 1;
    }

    // Bottom Cap
    const bot_plane_idx: u24 = @intCast(g_arena.planes.items.len);
    g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, -1, 0 } }) catch return error.OutOfMemory;
    const bot_f = generators.addPolygonFace(allocator, t_arena, g_arena, bot_rev, .{ .index = bot_plane_idx, .surface_type = .plane }, &twin_map) catch return error.OutOfMemory;
    t_arena.shell_faces.append(allocator, bot_f) catch return error.OutOfMemory;

    // Top Cap
    const top_plane_idx: u24 = @intCast(g_arena.planes.items.len);
    g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, height }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } }) catch return error.OutOfMemory;
    const top_f = generators.addPolygonFace(allocator, t_arena, g_arena, top_verts, .{ .index = top_plane_idx, .surface_type = .plane }, &twin_map) catch return error.OutOfMemory;
    t_arena.shell_faces.append(allocator, top_f) catch return error.OutOfMemory;

    // Package into Solid
    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = num_side_faces + 2 }) catch return error.OutOfMemory;
    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    t_arena.solid_shells.append(allocator, shell_id) catch return error.OutOfMemory;
    t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 }) catch return error.OutOfMemory;

    return solid_id;
}

/// Evaluates a 3D point and its normalized tangent vector at parameter t.
fn evaluateCurveAndTangent(g_arena: *const geom.GeometryArena, curve: geom.CurveId, t: f64) struct { pt: math.Vec3, tan: math.Vec3 } {
    const eps = 1e-5;
    var pt: math.Vec3 = undefined;
    var tan: math.Vec3 = undefined;

    switch (curve.curve_type) {
        .line => {
            const line = g_arena.lines.items[curve.index];
            pt = math.add(line.start, math.scale(math.sub(line.end, line.start), t));
            tan = math.normalize(math.sub(line.end, line.start));
        },
        .circle_arc => {
            const arc = g_arena.circle_arcs.items[curve.index];
            // Assuming t in [0, 1] sweeps a full circle for this primitive evaluation
            const angle = t * 2.0 * std.math.pi;
            const radial = math.add(math.scale(arc.x_axis, @cos(angle)), math.scale(arc.y_axis, @sin(angle)));
            pt = math.add(arc.center, math.scale(radial, arc.radius));
            tan = math.normalize(math.add(math.scale(arc.x_axis, -@sin(angle)), math.scale(arc.y_axis, @cos(angle))));
        },
        .nurbs => {
            const n_curve = g_arena.nurbs_curves.items[curve.index];
            pt = geom.evaluateNurbsCurve(n_curve, t);
            const pt_next = geom.evaluateNurbsCurve(n_curve, @min(t + eps, 1.0));
            const pt_prev = geom.evaluateNurbsCurve(n_curve, @max(t - eps, 0.0));
            tan = math.normalize(math.sub(pt_next, pt_prev));
        },
    }
    return .{ .pt = pt, .tan = tan };
}

/// Generates a twist-free continuous coordinate system along a curve
/// using the Wang et al. Double Reflection Parallel Transport method.
pub fn generateRMF(
    allocator: std.mem.Allocator,
    g_arena: *const geom.GeometryArena,
    curve: geom.CurveId,
    samples: usize,
) ![]Frame {
    var frames = try allocator.alloc(Frame, samples);
    errdefer allocator.free(frames);

    // 1. Initialize the first frame
    const eval0 = evaluateCurveAndTangent(g_arena, curve, 0.0);
    var init_normal = math.Vec3{ 1, 0, 0 };
    if (@abs(math.dot(eval0.tan, init_normal)) > 0.99) {
        init_normal = .{ 0, 1, 0 };
    }
    init_normal = math.normalize(math.cross(math.cross(eval0.tan, init_normal), eval0.tan));

    frames[0] = .{
        .origin = eval0.pt,
        .tangent = eval0.tan,
        .normal = init_normal,
        .binormal = math.normalize(math.cross(eval0.tan, init_normal)),
    };

    // 2. Transport frame via Double Reflection
    for (1..samples) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples - 1));
        const eval = evaluateCurveAndTangent(g_arena, curve, t);
        const x_prev = frames[i - 1].origin;
        const t_prev = frames[i - 1].tangent;
        const x_curr = eval.pt;
        const t_curr = eval.tan;

        // First reflection: Map previous frame to current origin
        const v1 = math.sub(x_curr, x_prev);
        const c1 = math.dot(v1, v1);
        var n_L = frames[i - 1].normal;
        var t_L = t_prev;

        if (c1 > 1e-12) {
            n_L = math.sub(n_L, math.scale(v1, 2.0 * math.dot(v1, n_L) / c1));
            t_L = math.sub(t_L, math.scale(v1, 2.0 * math.dot(v1, t_L) / c1));
        }

        // Second reflection: Align tangents
        const v2 = math.sub(t_curr, t_L);
        const c2 = math.dot(v2, v2);
        var n_curr = n_L;

        if (c2 > 1e-12) {
            n_curr = math.sub(n_curr, math.scale(v2, 2.0 * math.dot(v2, n_curr) / c2));
        }

        frames[i] = .{
            .origin = x_curr,
            .tangent = t_curr,
            .normal = math.normalize(n_curr),
            .binormal = math.normalize(math.cross(t_curr, n_curr)),
        };
    }

    return frames;
}

/// Sweeps a 2D NURBS profile along a 3D rail curve to generate a mathematically exact NURBS Surface.
pub fn sweepProfileAlongCurve(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    profile: geom.NurbsCurve, // 2D profile assumed to be in XY plane, sweeping along Z
    rail: geom.CurveId,
    samples: usize, // Typically matching the degree complexity of the rail
) !u32 {
    const frames = try generateRMF(allocator, g_arena, rail, samples);
    defer allocator.free(frames);

    const num_cp_u = profile.control_points.len;
    const num_cp_v = samples;
    var surface_cps = try allocator.alloc(math.Vec4, num_cp_u * num_cp_v);
    defer allocator.free(surface_cps);

    // Transform profile control points into world space at each frame
    for (frames, 0..) |frame, v| {
        for (profile.control_points, 0..) |cp, u| {
            // cp is (x, y, 0, w) where x aligns with Normal, y aligns with Binormal
            const weight = cp[3];
            const px = cp[0] / weight;
            const py = cp[1] / weight;

            const pt_world = math.add(frame.origin, math.add(math.scale(frame.normal, px), math.scale(frame.binormal, py)));

            surface_cps[v * num_cp_u + u] = .{ pt_world[0] * weight, pt_world[1] * weight, pt_world[2] * weight, weight };
        }
    }

    // Explicitly define as usize to prevent Zig's range analysis from inferring a u2,
    // which would overflow when adding 1 in the loop bound below.
    const degree_v: usize = @min(@as(usize, 3), num_cp_v - 1);

    // Exact knot allocation (Control Points + Degree + 1)
    var knots_v = try allocator.alloc(f64, num_cp_v + degree_v + 1);
    defer allocator.free(knots_v);

    // Clamped uniform knot generation
    for (0..degree_v + 1) |i| knots_v[i] = 0.0;
    for (degree_v + 1..num_cp_v) |i| {
        knots_v[i] = @as(f64, @floatFromInt(i - degree_v)) / @as(f64, @floatFromInt(num_cp_v - degree_v));
    }
    for (num_cp_v..num_cp_v + degree_v + 1) |i| knots_v[i] = 1.0;

    const surf_idx: u24 = @intCast(g_arena.nurbs_surfaces.items.len);
    try g_arena.nurbs_surfaces.append(allocator, .{
        .degree_u = profile.degree,
        .degree_v = @intCast(degree_v),
        .knots_u = try allocator.dupe(f64, profile.knots),
        .knots_v = try allocator.dupe(f64, knots_v),
        .num_cp_u = @intCast(num_cp_u),
        .num_cp_v = @intCast(num_cp_v),
        .control_points = try allocator.dupe(math.Vec4, surface_cps),
    });

    return surf_idx;
}
