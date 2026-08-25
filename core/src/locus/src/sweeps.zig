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
    