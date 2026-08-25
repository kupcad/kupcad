const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const GenError = error{OutOfMemory};

pub const EdgeKey = struct {
    min_v: topo.VertexId,
    max_v: topo.VertexId,

    pub fn init(v1: topo.VertexId, v2: topo.VertexId) EdgeKey {
        return .{
            .min_v = @min(v1, v2),
            .max_v = @max(v1, v2),
        };
    }
};

/// Helper to add a flat polygonal face to the graph and wire its Half-Edges.
pub fn addPolygonFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    vertices: []const topo.VertexId,
    surface_id: geom.SurfaceId,
    twin_map: *std.AutoHashMap(EdgeKey, topo.HalfEdgeId),
) !topo.FaceId {
    const face_id: u32 = @intCast(t_arena.faces.items.len);
    const loop_id: u32 = @intCast(t_arena.loops.items.len);
    const he_start: u32 = @intCast(t_arena.half_edges.items.len);
    const n = vertices.len;

    for (0..n) |i| {
        const v_start = vertices[i];
        const v_end = vertices[(i + 1) % n];

        const p_start = t_arena.vertices.items[v_start].point;
        const p_end = t_arena.vertices.items[v_end].point;
        const line_idx: u24 = @intCast(g_arena.lines.items.len);
        try g_arena.lines.append(allocator, .{ .start = p_start, .end = p_end });

        const he_id: u32 = @intCast(t_arena.half_edges.items.len);
        try t_arena.half_edges.append(allocator, .{
            .start_vertex = v_start,
            .twin = topo.NULL_ID,
            .next = he_start + @as(u32, @intCast((i + 1) % n)),
            .prev = he_start + @as(u32, @intCast((i + n - 1) % n)),
            .loop_id = loop_id,
            .curve = .{ .index = line_idx, .curve_type = .line },
            .forward = true,
        });

        const key = EdgeKey.init(v_start, v_end);
        if (twin_map.get(key)) |twin_id| {
            t_arena.half_edges.items[he_id].twin = twin_id;
            t_arena.half_edges.items[twin_id].twin = he_id;
            _ = twin_map.remove(key);
        } else {
            try twin_map.put(key, he_id);
        }
    }

    try t_arena.loops.append(allocator, .{
        .face_id = face_id,
        .first_half_edge = he_start,
    });

    const f_loops_start: u32 = @intCast(t_arena.face_loops.items.len);
    try t_arena.face_loops.append(allocator, loop_id);

    try t_arena.faces.append(allocator, .{
        .surface = surface_id,
        .forward = true,
        .loops_start = f_loops_start,
        .loops_len = 1,
    });

    return face_id;
}

pub fn generateCube(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    x: f64,
    y: f64,
    z: f64,
    center: bool,
) GenError!topo.SolidId {
    const cx = if (center) x / 2.0 else x;
    const cy = if (center) y / 2.0 else y;
    const cz = if (center) z / 2.0 else z;
    const ox = if (center) -cx else 0;
    const oy = if (center) -cy else 0;
    const oz = if (center) -cz else 0;

    const v_start: u32 = @intCast(t_arena.vertices.items.len);
    const points = [_]math.Vec3{
        .{ ox, oy, oz },
        .{ ox + x, oy, oz },
        .{ ox + x, oy + y, oz },
        .{ ox, oy + y, oz },
        .{ ox, oy, oz + z },
        .{ ox + x, oy, oz + z },
        .{ ox + x, oy + y, oz + z },
        .{ ox, oy + y, oz + z },
    };
    for (points) |pt| try t_arena.vertices.append(allocator, .{ .point = pt });

    const p_start: u24 = @intCast(g_arena.planes.items.len);
    const planes = [_]geom.Plane{
        .{ .origin = .{ 0, 0, oz }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, -1, 0 } },
        .{ .origin = .{ 0, 0, oz + z }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } },
        .{ .origin = .{ 0, oy, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 0, 1 } },
        .{ .origin = .{ ox + x, 0, 0 }, .u_axis = .{ 0, 1, 0 }, .v_axis = .{ 0, 0, 1 } },
        .{ .origin = .{ 0, oy + y, 0 }, .u_axis = .{ -1, 0, 0 }, .v_axis = .{ 0, 0, 1 } },
        .{ .origin = .{ ox, 0, 0 }, .u_axis = .{ 0, -1, 0 }, .v_axis = .{ 0, 0, 1 } },
    };
    for (planes) |p| try g_arena.planes.append(allocator, p);

    var twin_map = std.AutoHashMap(EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    const face_indices = [_][4]u32{
        .{ 0, 3, 2, 1 },
        .{ 4, 5, 6, 7 },
        .{ 0, 1, 5, 4 },
        .{ 1, 2, 6, 5 },
        .{ 2, 3, 7, 6 },
        .{ 3, 0, 4, 7 },
    };

    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    for (face_indices, 0..) |f_idx, i| {
        const mapped = [_]u32{ v_start + f_idx[0], v_start + f_idx[1], v_start + f_idx[2], v_start + f_idx[3] };
        const surf = geom.SurfaceId{ .index = p_start + @as(u24, @intCast(i)), .surface_type = .plane };
        const f_id = try addPolygonFace(allocator, t_arena, g_arena, &mapped, surf, &twin_map);
        try t_arena.shell_faces.append(allocator, f_id);
    }

    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = 6 });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

pub fn generateCylinder(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    radius: f64,
    height: f64,
    centered: bool,
) GenError!topo.SolidId {
    const oz = if (centered) -height / 2.0 else 0.0;
    const segments: usize = 16;

    var bot_verts = try allocator.alloc(topo.VertexId, segments);
    defer allocator.free(bot_verts);
    var top_verts = try allocator.alloc(topo.VertexId, segments);
    defer allocator.free(top_verts);

    for (0..segments) |i| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segments));
        const px = radius * @cos(angle);
        const py = radius * @sin(angle);

        const v_bot: u32 = @intCast(t_arena.vertices.items.len);
        try t_arena.vertices.append(allocator, .{ .point = .{ px, py, oz } });
        bot_verts[i] = v_bot;

        const v_top: u32 = @intCast(t_arena.vertices.items.len);
        try t_arena.vertices.append(allocator, .{ .point = .{ px, py, oz + height } });
        top_verts[i] = v_top;
    }

    var twin_map = std.AutoHashMap(EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);

    // Bottom Cap
    const bot_plane_idx: u24 = @intCast(g_arena.planes.items.len);
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, oz }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, -1, 0 } });
    var bot_rev = try allocator.alloc(topo.VertexId, segments);
    defer allocator.free(bot_rev);
    for (0..segments) |i| bot_rev[i] = bot_verts[segments - 1 - i];
    const bot_f = try addPolygonFace(allocator, t_arena, g_arena, bot_rev, .{ .index = bot_plane_idx, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(allocator, bot_f);

    // Top Cap
    const top_plane_idx: u24 = @intCast(g_arena.planes.items.len);
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, oz + height }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    const top_f = try addPolygonFace(allocator, t_arena, g_arena, top_verts, .{ .index = top_plane_idx, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(allocator, top_f);

    // Side Quads
    const cyl_surf_idx: u24 = @intCast(g_arena.cylinders.items.len);
    try g_arena.cylinders.append(allocator, .{ .origin = .{ 0, 0, oz }, .axis = .{ 0, 0, 1 }, .x_axis = .{ 1, 0, 0 }, .y_axis = .{ 0, 1, 0 }, .radius = radius });

    for (0..segments) |i| {
        const next_i = (i + 1) % segments;
        const quad = [_]topo.VertexId{ bot_verts[i], bot_verts[next_i], top_verts[next_i], top_verts[i] };
        const side_f = try addPolygonFace(allocator, t_arena, g_arena, &quad, .{ .index = cyl_surf_idx, .surface_type = .cylinder }, &twin_map);
        try t_arena.shell_faces.append(allocator, side_f);
    }

    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = @intCast(2 + segments) });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

pub fn generateSphere(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    radius: f64,
) GenError!topo.SolidId {
    return generateCylinder(allocator, t_arena, g_arena, radius, radius * 2.0, true);
}

pub fn generatePolygon(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    pts: []const [2]f64,
) GenError!topo.FaceId {
    const v_start: u32 = @intCast(t_arena.vertices.items.len);
    var vert_ids = try allocator.alloc(topo.VertexId, pts.len);
    defer allocator.free(vert_ids);

    for (pts, 0..) |pt, i| {
        const v_id = v_start + @as(u32, @intCast(i));
        try t_arena.vertices.append(allocator, .{ .point = .{ pt[0], pt[1], 0.0 } });
        vert_ids[i] = v_id;
    }

    const plane_idx: u24 = @intCast(g_arena.planes.items.len);
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    var twin_map = std.AutoHashMap(EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    return addPolygonFace(allocator, t_arena, g_arena, vert_ids, .{ .index = plane_idx, .surface_type = .plane }, &twin_map);
}

pub fn generateSquare(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    size_x: f64,
    size_y: f64,
    centered: bool,
) GenError!topo.FaceId {
    const ox = if (centered) -size_x / 2.0 else 0.0;
    const oy = if (centered) -size_y / 2.0 else 0.0;
    const mx = ox + size_x;
    const my = oy + size_y;
    const pts = [_][2]f64{
        .{ ox, oy },
        .{ mx, oy },
        .{ mx, my },
        .{ ox, my },
    };
    return generatePolygon(allocator, t_arena, g_arena, &pts);
}

pub fn generateCircle(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    radius: f64,
    segments: i32,
) GenError!topo.FaceId {
    const segs = if (segments < 3) 32 else @as(usize, @intCast(segments));
    var pts = try allocator.alloc([2]f64, segs);
    defer allocator.free(pts);
    for (0..segs) |i| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segs));
        pts[i] = .{ radius * @cos(angle), radius * @sin(angle) };
    }
    return generatePolygon(allocator, t_arena, g_arena, pts);
}
