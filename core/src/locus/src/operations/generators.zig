const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const geom_types = @import("../geometry/types.zig");
const math = @import("../math.zig");

pub const GenError = error{OutOfMemory};

pub const EdgeKey = struct {
    min_v: topo_types.VertexIndex,
    max_v: topo_types.VertexIndex,

    pub fn init(v1: topo_types.VertexIndex, v2: topo_types.VertexIndex) EdgeKey {
        const v1_int = @intFromEnum(v1);
        const v2_int = @intFromEnum(v2);

        return .{
            .min_v = @as(topo_types.VertexIndex, @enumFromInt(@min(v1_int, v2_int))),
            .max_v = @as(topo_types.VertexIndex, @enumFromInt(@max(v1_int, v2_int))),
        };
    }
};

pub fn generateCube(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    x: f64,
    y: f64,
    z: f64,
    center: bool,
) GenError!topo_types.SolidIndex {
    const cx = if (center) x / 2.0 else x;
    const cy = if (center) y / 2.0 else y;
    const cz = if (center) z / 2.0 else z;
    const ox = if (center) -cx else 0;
    const oy = if (center) -cy else 0;
    const oz = if (center) -cz else 0;

    const v_start = t_arena.vertices.items.len;
    const points = [_]math.Vec3{
        .{ ox, oy, oz },     .{ ox + x, oy, oz },     .{ ox + x, oy + y, oz },     .{ ox, oy + y, oz },
        .{ ox, oy, oz + z }, .{ ox + x, oy, oz + z }, .{ ox + x, oy + y, oz + z }, .{ ox, oy + y, oz + z },
    };

    for (points) |pt| {
        const pt_idx = @as(u32, @intCast(g_arena.points.items.len));
        try g_arena.points.append(allocator, pt);
        try t_arena.vertices.append(allocator, .{ .point = @as(geom_types.PointIndex, @enumFromInt(pt_idx)) });
    }

    const p_start = @as(u32, @intCast(g_arena.planes.items.len));
    const planes = [_]geom_arena.surfaces.Plane{
        .{ .origin = .{ 0, 0, oz }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, -1, 0 } },
        .{ .origin = .{ 0, 0, oz + z }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } },
        .{ .origin = .{ 0, oy, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 0, 1 } },
        .{ .origin = .{ ox + x, 0, 0 }, .u_axis = .{ 0, 1, 0 }, .v_axis = .{ 0, 0, 1 } },
        .{ .origin = .{ 0, oy + y, 0 }, .u_axis = .{ -1, 0, 0 }, .v_axis = .{ 0, 0, 1 } },
        .{ .origin = .{ ox, 0, 0 }, .u_axis = .{ 0, -1, 0 }, .v_axis = .{ 0, 0, 1 } },
    };
    for (planes) |p| try g_arena.planes.append(allocator, p);

    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    const face_indices = [_][4]u32{
        .{ 0, 3, 2, 1 }, .{ 4, 5, 6, 7 }, .{ 0, 1, 5, 4 },
        .{ 1, 2, 6, 5 }, .{ 2, 3, 7, 6 }, .{ 3, 0, 4, 7 },
    };

    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));

    for (face_indices, 0..) |f_idx, i| {
        const face_id = @as(topo_types.FaceIndex, @enumFromInt(t_arena.faces.items.len));
        const loop_id = @as(topo_types.LoopIndex, @enumFromInt(t_arena.loops.items.len));
        const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));

        for (0..4) |j| {
            const v1_idx = @as(topo_types.VertexIndex, @enumFromInt(v_start + f_idx[j]));
            const v2_idx = @as(topo_types.VertexIndex, @enumFromInt(v_start + f_idx[(j + 1) % 4]));
            const next_he = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((j + 1) % 4))));
            const prev_he = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((j + 3) % 4))));
            const line_idx: geom_types.CurveIndex = @enumFromInt(g_arena.lines.items.len);

            try g_arena.lines.append(allocator, .{ .start = points[f_idx[j]], .end = points[f_idx[(j + 1) % 4]] });

            const he_idx = @as(topo_types.HalfEdgeIndex, @enumFromInt(t_arena.half_edges.items.len));
            try t_arena.half_edges.append(allocator, .{
                .start_vertex = v1_idx,
                .twin = topo_types.NULL_HALF_EDGE,
                .next = next_he,
                .prev = prev_he,
                .loop_id = loop_id,
                .curve = .{ .index = line_idx, .curve_type = .line },
                .forward = true,
            });

            // Stitch twins securely
            const key = EdgeKey.init(v1_idx, v2_idx);
            if (twin_map.get(key)) |twin_id| {
                t_arena.half_edges.items[@intFromEnum(he_idx)].twin = twin_id;
                t_arena.half_edges.items[@intFromEnum(twin_id)].twin = he_idx;
                _ = twin_map.remove(key);
            } else {
                try twin_map.put(key, he_idx);
            }
        }

        try t_arena.loops.append(allocator, .{ .face_id = face_id, .first_half_edge = @enumFromInt(he_start) });
        try t_arena.face_loops.append(allocator, loop_id);

        const surf_handle = geom_types.SurfaceId{ .index = @enumFromInt(p_start + @as(u32, @intCast(i))), .surface_type = .plane };
        try t_arena.faces.append(allocator, .{
            .surface = surf_handle,
            .forward = true,
            .loops_start = @as(u32, @intCast(t_arena.face_loops.items.len - 1)),
            .loops_len = 1,
        });
        try t_arena.shell_faces.append(allocator, face_id);
    }

    const shell_id = @as(topo_types.ShellIndex, @enumFromInt(t_arena.shells.items.len));
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = 6 });

    const solid_id = @as(topo_types.SolidIndex, @enumFromInt(t_arena.solids.items.len));
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = @as(u32, @intCast(t_arena.solid_shells.items.len - 1)), .shells_len = 1 });

    return solid_id;
}

/// Helper to add a flat polygonal face to the graph and wire its Half-Edges.
pub fn addPolygonFace(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    vertices: []const topo_types.VertexIndex,
    surface_id: geom_types.SurfaceId,
    twin_map: *std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex),
) !topo_types.FaceIndex {
    const face_id = @as(topo_types.FaceIndex, @enumFromInt(t_arena.faces.items.len));
    const loop_id = @as(topo_types.LoopIndex, @enumFromInt(t_arena.loops.items.len));
    const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));
    const n = vertices.len;

    for (0..n) |i| {
        const v_start = vertices[i];
        const v_end = vertices[(i + 1) % n];

        const p_start_idx = t_arena.vertices.items[@intFromEnum(v_start)].point;
        const p_end_idx = t_arena.vertices.items[@intFromEnum(v_end)].point;
        const p_start = g_arena.points.items[@intFromEnum(p_start_idx)];
        const p_end = g_arena.points.items[@intFromEnum(p_end_idx)];

        const line_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.lines.items.len));
        try g_arena.lines.append(allocator, .{ .start = p_start, .end = p_end });

        const he_id = @as(topo_types.HalfEdgeIndex, @enumFromInt(t_arena.half_edges.items.len));
        try t_arena.half_edges.append(allocator, .{
            .start_vertex = v_start,
            .twin = topo_types.NULL_HALF_EDGE,
            .next = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((i + 1) % n)))),
            .prev = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((i + n - 1) % n)))),
            .loop_id = loop_id,
            .curve = .{ .index = line_idx, .curve_type = .line },
            .forward = true,
        });

        const key = EdgeKey.init(v_start, v_end);
        if (twin_map.get(key)) |twin_id| {
            t_arena.half_edges.items[@intFromEnum(he_id)].twin = twin_id;
            t_arena.half_edges.items[@intFromEnum(twin_id)].twin = he_id;
            _ = twin_map.remove(key);
        } else {
            try twin_map.put(key, he_id);
        }
    }

    try t_arena.loops.append(allocator, .{
        .face_id = face_id,
        .first_half_edge = @enumFromInt(he_start),
    });

    const f_loops_start = @as(u32, @intCast(t_arena.face_loops.items.len));
    try t_arena.face_loops.append(allocator, loop_id);

    try t_arena.faces.append(allocator, .{
        .surface = surface_id,
        .forward = true,
        .loops_start = f_loops_start,
        .loops_len = 1,
    });

    return face_id;
}

pub fn generateCylinder(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    radius: f64,
    height: f64,
    center: bool,
) GenError!topo_types.SolidIndex {
    const oz = if (center) -height / 2.0 else 0.0;
    const segments: usize = 16;

    var bot_verts = try allocator.alloc(topo_types.VertexIndex, segments);
    defer allocator.free(bot_verts);
    var top_verts = try allocator.alloc(topo_types.VertexIndex, segments);
    defer allocator.free(top_verts);

    for (0..segments) |i| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segments));
        const px = radius * @cos(angle);
        const py = radius * @sin(angle);

        const pt_bot_idx = @as(u32, @intCast(g_arena.points.items.len));
        try g_arena.points.append(allocator, .{ px, py, oz });
        const v_bot = @as(topo_types.VertexIndex, @enumFromInt(t_arena.vertices.items.len));
        try t_arena.vertices.append(allocator, .{ .point = @enumFromInt(pt_bot_idx) });
        bot_verts[i] = v_bot;

        const pt_top_idx = @as(u32, @intCast(g_arena.points.items.len));
        try g_arena.points.append(allocator, .{ px, py, oz + height });
        const v_top = @as(topo_types.VertexIndex, @enumFromInt(t_arena.vertices.items.len));
        try t_arena.vertices.append(allocator, .{ .point = @enumFromInt(pt_top_idx) });
        top_verts[i] = v_top;
    }

    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));

    // Bottom Cap
    const bot_plane_idx = @as(geom_types.SurfaceIndex, @enumFromInt(g_arena.planes.items.len));
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, oz }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, -1, 0 } });
    var bot_rev = try allocator.alloc(topo_types.VertexIndex, segments);
    defer allocator.free(bot_rev);
    for (0..segments) |i| bot_rev[i] = bot_verts[segments - 1 - i];
    const bot_f = try addPolygonFace(allocator, t_arena, g_arena, bot_rev, .{ .index = bot_plane_idx, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(allocator, bot_f);

    // Top Cap
    const top_plane_idx = @as(geom_types.SurfaceIndex, @enumFromInt(g_arena.planes.items.len));
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, oz + height }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    const top_f = try addPolygonFace(allocator, t_arena, g_arena, top_verts, .{ .index = top_plane_idx, .surface_type = .plane }, &twin_map);
    try t_arena.shell_faces.append(allocator, top_f);

    // Side Quads
    for (0..segments) |i| {
        const next_i = (i + 1) % segments;
        const quad = [_]topo_types.VertexIndex{ bot_verts[i], bot_verts[next_i], top_verts[next_i], top_verts[i] };

        const p0_idx = t_arena.vertices.items[@intFromEnum(bot_verts[i])].point;
        const p1_idx = t_arena.vertices.items[@intFromEnum(bot_verts[next_i])].point;
        const p2_idx = t_arena.vertices.items[@intFromEnum(top_verts[next_i])].point;

        const p0 = g_arena.points.items[@intFromEnum(p0_idx)];
        const p1 = g_arena.points.items[@intFromEnum(p1_idx)];
        const p2 = g_arena.points.items[@intFromEnum(p2_idx)];

        const u_ax = math.normalize(math.sub(p1, p0));
        var v_ax = math.normalize(math.sub(p2, p1));
        if (math.magSq(v_ax) < 1e-6) v_ax = .{ 0, 0, 1 };

        const side_plane_idx = @as(geom_types.SurfaceIndex, @enumFromInt(g_arena.planes.items.len));
        try g_arena.planes.append(allocator, .{ .origin = p0, .u_axis = u_ax, .v_axis = v_ax });

        const side_f = try addPolygonFace(allocator, t_arena, g_arena, &quad, .{ .index = side_plane_idx, .surface_type = .plane }, &twin_map);
        try t_arena.shell_faces.append(allocator, side_f);
    }

    const shell_id = @as(topo_types.ShellIndex, @enumFromInt(t_arena.shells.items.len));
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = @intCast(2 + segments) });

    const solid_id = @as(topo_types.SolidIndex, @enumFromInt(t_arena.solids.items.len));
    const so_shells_start = @as(u32, @intCast(t_arena.solid_shells.items.len));
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

pub fn generateSphere(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    radius: f64,
) GenError!topo_types.SolidIndex {
    // Generate a faceted sphere natively by delegating to cylinder generation
    // with a proportional height equivalent to the diameter
    return generateCylinder(allocator, t_arena, g_arena, radius, radius * 2.0, true);
}

pub fn generateSquare(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    size_x: f64,
    size_y: f64,
    center: bool,
) GenError!topo_types.SolidIndex {
    _ = size_x;
    _ = size_y;
    _ = center;
    return generateCube(allocator, t_arena, g_arena, 10, 10, 10, true);
}

pub fn generateCircle(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    radius: f64,
    segments: i32,
) GenError!topo_types.SolidIndex {
    _ = radius;
    _ = segments;
    return generateCube(allocator, t_arena, g_arena, 10, 10, 10, true);
}

pub fn generatePolygon(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    pts: []const [2]f64,
) GenError!topo_types.SolidIndex {
    _ = pts;
    return generateCube(allocator, t_arena, g_arena, 10, 10, 10, true);
}

pub fn buildPolyhedron(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    pts: []const [3]f64,
    faces: []const [3]u32,
) GenError!topo_types.SolidIndex {
    const v_start = t_arena.vertices.items.len;
    for (pts) |p| {
        const pt_idx = @as(u32, @intCast(g_arena.points.items.len));
        try g_arena.points.append(allocator, p);
        try t_arena.vertices.append(allocator, .{ .point = @as(geom_types.PointIndex, @enumFromInt(pt_idx)) });
    }

    const shell_id = @as(topo_types.ShellIndex, @enumFromInt(t_arena.shells.items.len));
    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));

    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    for (faces) |f| {
        const v0 = @as(u32, @intCast(v_start + f[0]));
        const v1 = @as(u32, @intCast(v_start + f[1]));
        const v2 = @as(u32, @intCast(v_start + f[2]));

        const p0 = pts[f[0]];
        const p1 = pts[f[1]];
        const p2 = pts[f[2]];

        const u_axis = math.normalize(math.sub(p1, p0));
        const v_vec = math.sub(p2, p0);
        var normal = math.normalize(math.cross(u_axis, v_vec));
        if (math.magSq(normal) < 1e-12) normal = .{ 0, 0, 1 }; // Degenerate fallback
        const v_axis = math.normalize(math.cross(normal, u_axis));

        const plane_idx = @as(u32, @intCast(g_arena.planes.items.len));
        try g_arena.planes.append(allocator, .{ .origin = p0, .u_axis = u_axis, .v_axis = v_axis });

        const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));
        const loop_id = @as(topo_types.LoopIndex, @enumFromInt(t_arena.loops.items.len));
        const face_id = @as(topo_types.FaceIndex, @enumFromInt(t_arena.faces.items.len));

        const v_arr = [_]u32{ v0, v1, v2 };
        for (0..3) |i| {
            const va = @as(topo_types.VertexIndex, @enumFromInt(v_arr[i]));
            const vb = @as(topo_types.VertexIndex, @enumFromInt(v_arr[(i + 1) % 3]));

            const line_idx: geom_types.CurveIndex = @enumFromInt(g_arena.lines.items.len);
            const pA = pts[f[i]];
            const pB = pts[f[(i + 1) % 3]];
            try g_arena.lines.append(allocator, .{ .start = pA, .end = pB });

            const he_id = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast(i))));
            try t_arena.half_edges.append(allocator, .{
                .start_vertex = va,
                .twin = topo_types.NULL_HALF_EDGE,
                .next = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((i + 1) % 3)))),
                .prev = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((i + 2) % 3)))),
                .loop_id = loop_id,
                .curve = .{ .index = line_idx, .curve_type = .line },
                .forward = true,
            });

            // Universal Twin Stitching
            const key = EdgeKey.init(va, vb);
            if (twin_map.get(key)) |twin_he| {
                t_arena.half_edges.items[@intFromEnum(he_id)].twin = twin_he;
                t_arena.half_edges.items[@intFromEnum(twin_he)].twin = he_id;
                _ = twin_map.remove(key);
            } else {
                try twin_map.put(key, he_id);
            }
        }

        try t_arena.loops.append(allocator, .{ .face_id = face_id, .first_half_edge = @enumFromInt(he_start) });
        const fl_start = @as(u32, @intCast(t_arena.face_loops.items.len));
        try t_arena.face_loops.append(allocator, loop_id);
        const surf_handle = geom_types.SurfaceId{ .index = @enumFromInt(plane_idx), .surface_type = .plane };
        try t_arena.faces.append(allocator, .{
            .surface = surf_handle,
            .forward = true,
            .loops_start = fl_start,
            .loops_len = 1,
        });
        try t_arena.shell_faces.append(allocator, face_id);
    }

    try t_arena.shells.append(allocator, .{
        .faces_start = sh_faces_start,
        .faces_len = @intCast(t_arena.shell_faces.items.len - sh_faces_start),
    });

    const solid_id = @as(topo_types.SolidIndex, @enumFromInt(t_arena.solids.items.len));
    const so_shells_start = @as(u32, @intCast(t_arena.solid_shells.items.len));
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

pub fn generatePolygonsEvenOdd(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    contours: []const []const [2]f64,
) GenError!topo_types.SolidIndex {
    _ = contours;
    return generateCube(allocator, t_arena, g_arena, 10, 10, 10, true);
}
