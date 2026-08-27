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
    base_face_id: topo.FaceId,
    vec: math.Vec3,
) SweepError!topo.SolidId {
    const base_face = t_arena.faces.items[base_face_id];
    const outer_loop_id = t_arena.face_loops.items[base_face.loops_start];
    const outer_loop = t_arena.loops.items[outer_loop_id];

    var base_verts = std.ArrayListUnmanaged(topo.VertexId).empty;
    defer base_verts.deinit(allocator);

    var curr_he = outer_loop.first_half_edge;
    while (true) {
        const he = t_arena.half_edges.items[curr_he];
        try base_verts.append(allocator, he.start_vertex);
        curr_he = he.next;
        if (curr_he == outer_loop.first_half_edge) break;
    }

    const n = base_verts.items.len;
    var top_verts = try allocator.alloc(topo.VertexId, n);
    defer allocator.free(top_verts);

    for (0..n) |i| {
        const p_base = t_arena.vertices.items[base_verts.items[i]].point;
        const v_top_id: u32 = @intCast(t_arena.vertices.items.len);
        try t_arena.vertices.append(allocator, .{ .point = math.add(p_base, vec) });
        top_verts[i] = v_top_id;
    }

    var twin_map = std.AutoHashMap(generators.EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.append(allocator, base_face_id);

    // Top Cap
    const top_plane_idx: u24 = @intCast(g_arena.planes.items.len);
    if (base_face.surface.surface_type == .plane) {
        const bp = g_arena.planes.items[base_face.surface.index];
        try g_arena.planes.append(allocator, .{ .origin = math.add(bp.origin, vec), .u_axis = bp.u_axis, .v_axis = bp.v_axis });
    }
    const top_f = try generators.addPolygonFace(allocator, t_arena, g_arena, top_verts, .{ .index = top_plane_idx, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(allocator, top_f);

    // Side Quads
    for (0..n) |i| {
        const next_i = (i + 1) % n;
        const quad = [_]topo.VertexId{ base_verts.items[i], base_verts.items[next_i], top_verts[next_i], top_verts[i] };
        const side_plane_idx: u24 = @intCast(g_arena.planes.items.len);
        try g_arena.planes.append(allocator, .{ .origin = t_arena.vertices.items[base_verts.items[i]].point, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 0, 1 } });
        const side_f = try generators.addPolygonFace(allocator, t_arena, g_arena, &quad, .{ .index = side_plane_idx, .surface_type = .plane }, &twin_map);
        try t_arena.shell_faces.append(allocator, side_f);
    }

    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = @intCast(2 + n) });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

/// Revolves a 2D cross-section face around the Y-axis to generate a 3D solid.
pub fn revolveFace(
    allocator: std.mem.Allocator,
    out_t_arena: *topo.TopologyArena,
    out_g_arena: *geom.GeometryArena,
    in_t_arena: *const topo.TopologyArena,
    base_face_id: topo.FaceId, // <-- Changed from SolidId to FaceId
    segments: u32,
    degrees: f64,
) !topo.SolidId {
    var profile_pts = std.ArrayListUnmanaged([3]f64).empty;
    defer profile_pts.deinit(allocator);

    // 1. Extract vertices directly from the base 2D cross section face
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

    // 2. Generate swept layers by rotating around the Y-axis
    for (0..segments + 1) |layer| {
        const angle = @as(f64, @floatFromInt(layer)) * rad_step;
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        for (profile_pts.items) |p| {
            try all_pts.append(allocator, .{ p[0] * cos_a + p[2] * sin_a, p[1], -p[0] * sin_a + p[2] * cos_a });
        }
    }

    // 3. Generate quad triangles for the swept walls (CCW outward winding)
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

    // 4. Generate End Caps if it's not a complete 360 revolution
    if (degrees < 359.99) {
        for (1..num_pts - 1) |p| {
            // Start cap
            try all_faces.append(allocator, .{ 0, @as(u32, @intCast(p)), @as(u32, @intCast(p + 1)) });
            // End cap
            const end_offset = @as(u32, @intCast(segments)) * num_pts;
            try all_faces.append(allocator, .{ end_offset, end_offset + @as(u32, @intCast(p + 1)), end_offset + @as(u32, @intCast(p)) });
        }
    }

    // 5. Pipe into the universal stitcher!
    return generators.buildPolyhedron(allocator, out_t_arena, out_g_arena, all_pts.items, all_faces.items);
}
