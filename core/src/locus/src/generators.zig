const std = @import("std");
const builtin = @import("builtin");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const validator = @import("validator.zig");

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

    // Validate base inputs are mathematically watertight before Booleans touch them
    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // Primitives have no floating point drift upon creation, static tolerance is safe
        const base_tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
        validator.BRepSanitizer.validateSolid(allocator, t_arena, g_arena, solid_id, base_tol, .{
            .require_closed_shells = true,
            .check_euler = true,
            .check_twins = true,
        }) catch return error.OutOfMemory;
    }

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

    // Side Quads (Now correctly calculated as Planes)
    for (0..segments) |i| {
        const next_i = (i + 1) % segments;
        const quad = [_]topo.VertexId{ bot_verts[i], bot_verts[next_i], top_verts[next_i], top_verts[i] };

        const p0 = t_arena.vertices.items[bot_verts[i]].point;
        const p1 = t_arena.vertices.items[bot_verts[next_i]].point;
        const p2 = t_arena.vertices.items[top_verts[next_i]].point;
        const u_ax = math.normalize(math.sub(p1, p0));
        var v_ax = math.normalize(math.sub(p2, p1));
        if (math.magSq(v_ax) < 1e-6) v_ax = .{ 0, 0, 1 };

        const side_plane_idx: u24 = @intCast(g_arena.planes.items.len);
        try g_arena.planes.append(allocator, .{ .origin = p0, .u_axis = u_ax, .v_axis = v_ax });

        const side_f = try addPolygonFace(allocator, t_arena, g_arena, &quad, .{ .index = side_plane_idx, .surface_type = .plane }, &twin_map);
        try t_arena.shell_faces.append(allocator, side_f);
    }

    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = @intCast(2 + segments) });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    // Validate base inputs are mathematically watertight before Booleans touch them
    if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        // Primitives have no floating point drift upon creation, static tolerance is safe
        const base_tol = math.Tolerance{ .absolute = 1e-5, .squared = 1e-10, .parametric = 1e-5 };
        validator.BRepSanitizer.validateSolid(allocator, t_arena, g_arena, solid_id, base_tol, .{
            .require_closed_shells = true,
            .check_euler = true,
            .check_twins = true,
        }) catch return error.OutOfMemory;
    }

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
) GenError!topo.SolidId { // <-- Now returns a SolidId
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

    const face_id = try addPolygonFace(allocator, t_arena, g_arena, vert_ids, .{ .index = plane_idx, .surface_type = .plane }, &twin_map);

    // Package the 2D face inside a standard Solid container
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.append(allocator, face_id);

    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = 1 });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

pub fn generateSquare(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    size_x: f64,
    size_y: f64,
    centered: bool,
) GenError!topo.SolidId {
    const ox = if (centered) -size_x / 2.0 else 0.0;
    const oy = if (centered) -size_y / 2.0 else 0.0;
    const mx = ox + size_x;
    const my = oy + size_y;
    const pts = [_][2]f64{ .{ ox, oy }, .{ mx, oy }, .{ mx, my }, .{ ox, my } };
    return generatePolygon(allocator, t_arena, g_arena, &pts);
}

pub fn generateCircle(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    radius: f64,
    segments: i32,
) GenError!topo.SolidId {
    const segs = if (segments < 3) 32 else @as(usize, @intCast(segments));
    var pts = try allocator.alloc([2]f64, segs);
    defer allocator.free(pts);
    for (0..segs) |i| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segs));
        pts[i] = .{ radius * @cos(angle), radius * @sin(angle) };
    }
    return generatePolygon(allocator, t_arena, g_arena, pts);
}

/// Takes a raw array of vertices and triangle indices and stitches them into a perfect, manifold Half-Edge Solid.
/// Automatically handles twin-edge pairing and plane generation.
pub fn buildPolyhedron(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    pts: []const [3]f64,
    faces: []const [3]u32,
) !topo.SolidId {
    const v_start: u32 = @intCast(t_arena.vertices.items.len);
    for (pts) |p| {
        try t_arena.vertices.append(allocator, .{ .point = .{ p[0], p[1], p[2] } });
    }

    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);

    // Track edges to automatically wire Twins! Key: EdgeKey, Value: HalfEdgeId
    var edge_map = std.AutoHashMap(EdgeKey, topo.HalfEdgeId).init(allocator);
    defer edge_map.deinit();

    for (faces) |f| {
        const v0 = v_start + f[0];
        const v1 = v_start + f[1];
        const v2 = v_start + f[2];

        const p0 = t_arena.vertices.items[v0].point;
        const p1 = t_arena.vertices.items[v1].point;
        const p2 = t_arena.vertices.items[v2].point;

        // Calculate planar face geometry dynamically
        const u_axis = math.normalize(math.sub(p1, p0));
        const v_vec = math.sub(p2, p0);
        var normal = math.normalize(math.cross(u_axis, v_vec));
        if (math.magSq(normal) < 1e-12) normal = .{ 0, 0, 1 }; // Degenerate fallback
        const v_axis = math.normalize(math.cross(normal, u_axis));

        const plane_idx: u24 = @intCast(g_arena.planes.items.len);
        try g_arena.planes.append(allocator, .{ .origin = p0, .u_axis = u_axis, .v_axis = v_axis });

        const he_start: u32 = @intCast(t_arena.half_edges.items.len);
        const loop_id: u32 = @intCast(t_arena.loops.items.len);
        const face_id: u32 = @intCast(t_arena.faces.items.len);

        const v_arr = [_]u32{ v0, v1, v2 };
        for (0..3) |i| {
            const va = v_arr[i];
            const vb = v_arr[(i + 1) % 3];

            const line_idx: u24 = @intCast(g_arena.lines.items.len);
            try g_arena.lines.append(allocator, .{ .start = t_arena.vertices.items[va].point, .end = t_arena.vertices.items[vb].point });

            const he_id = he_start + @as(u32, @intCast(i));
            try t_arena.half_edges.append(allocator, .{
                .start_vertex = va,
                .twin = topo.NULL_ID,
                .next = he_start + @as(u32, @intCast((i + 1) % 3)),
                .prev = he_start + @as(u32, @intCast((i + 2) % 3)),
                .loop_id = loop_id,
                .curve = .{ .index = line_idx, .curve_type = .line },
                .forward = true,
            });

            // Universal Twin Stitching
            const key = EdgeKey.init(va, vb);

            if (edge_map.get(key)) |twin_he| {
                t_arena.half_edges.items[he_id].twin = twin_he;
                t_arena.half_edges.items[twin_he].twin = he_id;
                _ = edge_map.remove(key);
            } else {
                try edge_map.put(key, he_id);
            }
        }

        try t_arena.loops.append(allocator, .{ .face_id = face_id, .first_half_edge = he_start });
        const fl_start: u32 = @intCast(t_arena.face_loops.items.len);
        try t_arena.face_loops.append(allocator, loop_id);
        try t_arena.faces.append(allocator, .{
            .surface = .{ .index = plane_idx, .surface_type = .plane },
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

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

pub fn addMultiLoopFace(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    loops: []const []const topo.VertexId,
    surface_id: geom.SurfaceId,
    twin_map: *std.AutoHashMap(EdgeKey, topo.HalfEdgeId),
) !topo.FaceId {
    const f_loops_start: u32 = @intCast(t_arena.face_loops.items.len);

    for (loops) |vertices| {
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
        try t_arena.loops.append(allocator, .{ .face_id = std.math.maxInt(u32), .first_half_edge = he_start });
        try t_arena.face_loops.append(allocator, loop_id);
    }

    const face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.faces.append(allocator, .{
        .surface = surface_id,
        .forward = true,
        .loops_start = f_loops_start,
        .loops_len = @intCast(loops.len),
    });

    for (0..loops.len) |i| {
        const loop_id = t_arena.face_loops.items[f_loops_start + i];
        t_arena.loops.items[loop_id].face_id = face_id;
    }

    return face_id;
}

pub fn generatePolygonsEvenOdd(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    contours: []const []const [2]f64,
) GenError!topo.SolidId {
    const plane_idx: u24 = @intCast(g_arena.planes.items.len);
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    var loops_verts = std.ArrayListUnmanaged([]topo.VertexId).empty;
    defer {
        for (loops_verts.items) |arr| allocator.free(arr);
        loops_verts.deinit(allocator);
    }

    for (contours) |pts| {
        var vert_ids = try allocator.alloc(topo.VertexId, pts.len);
        for (pts, 0..) |pt, i| {
            const v_id = @as(u32, @intCast(t_arena.vertices.items.len));
            try t_arena.vertices.append(allocator, .{ .point = .{ pt[0], pt[1], 0.0 } });
            vert_ids[i] = v_id;
        }
        try loops_verts.append(allocator, vert_ids);
    }

    const face_id = try addMultiLoopFace(allocator, t_arena, g_arena, loops_verts.items, .{ .index = plane_idx, .surface_type = .plane }, &twin_map);

    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    try t_arena.shell_faces.append(allocator, face_id);
    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = 1 });
    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });
    return solid_id;
}
