const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const generators = @import("generators.zig");

pub const SweepError = error{ OutOfMemory, InvalidFace };

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
