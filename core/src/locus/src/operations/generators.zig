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

/// Calculates the exact 3D Plane geometry passing through 3 non-collinear points.
pub fn computePlaneFromPoints(p0: math.Vec3, p1: math.Vec3, p2: math.Vec3) geom_arena.surfaces.Plane {
    const u_dir = math.sub(p1, p0);
    const u_len = math.mag(u_dir);
    const u_axis = if (u_len > 1e-12) math.scale(u_dir, 1.0 / u_len) else math.Vec3{ 1, 0, 0 };

    const v_dir = math.sub(p2, p0);
    var norm = math.cross(u_axis, v_dir);
    const n_len = math.mag(norm);
    if (n_len > 1e-12) {
        norm = math.scale(norm, 1.0 / n_len);
    } else {
        norm = .{ 0, 0, 1 };
    }
    const v_axis = math.cross(norm, u_axis);

    return .{
        .origin = p0,
        .u_axis = u_axis,
        .v_axis = v_axis,
    };
}

/// Universal B-Rep face builder with explicit boundary curves and twin stitching.
pub fn addFaceWithCurves(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    vertices: []const topo_types.VertexIndex,
    curves: []const geom_types.CurveId,
    surface_id: geom_types.SurfaceId,
    twin_map: *std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex),
) GenError!topo_types.FaceIndex {
    const face_id = @as(topo_types.FaceIndex, @enumFromInt(t_arena.faces.items.len));
    const loop_id = @as(topo_types.LoopIndex, @enumFromInt(t_arena.loops.items.len));
    const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));
    const n = vertices.len;

    for (0..n) |i| {
        const va = vertices[i];
        const vb = vertices[(i + 1) % n];
        const next_he = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((i + 1) % n))));
        const prev_he = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((i + n - 1) % n))));
        const he_id = @as(topo_types.HalfEdgeIndex, @enumFromInt(t_arena.half_edges.items.len));

        try t_arena.half_edges.append(allocator, .{
            .start_vertex = va,
            .twin = topo_types.NULL_HALF_EDGE,
            .next = next_he,
            .prev = prev_he,
            .loop_id = loop_id,
            .curve = curves[i],
            .forward = true,
        });

        const key = EdgeKey.init(va, vb);
        if (twin_map.get(key)) |twin_id| {
            t_arena.half_edges.items[@intFromEnum(he_id)].twin = twin_id;
            t_arena.half_edges.items[@intFromEnum(twin_id)].twin = he_id;
            _ = twin_map.remove(key);
        } else {
            try twin_map.put(key, he_id);
        }
    }

    try t_arena.loops.append(allocator, .{ .face_id = face_id, .first_half_edge = @enumFromInt(he_start) });
    const fl_start = @as(u32, @intCast(t_arena.face_loops.items.len));
    try t_arena.face_loops.append(allocator, loop_id);

    try t_arena.faces.append(allocator, .{
        .surface = surface_id,
        .forward = true,
        .loops_start = fl_start,
        .loops_len = 1,
    });

    return face_id;
}

/// Helper to add a flat planar face, generating straight Line curves automatically.
pub fn addPolygonFace(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    vertices: []const topo_types.VertexIndex,
    surface_id: geom_types.SurfaceId,
    twin_map: *std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex),
) GenError!topo_types.FaceIndex {
    const n = vertices.len;
    const curves_buf = try allocator.alloc(geom_types.CurveId, n);
    defer allocator.free(curves_buf);

    for (0..n) |i| {
        const v_start = vertices[i];
        const v_end = vertices[(i + 1) % n];
        const p_start = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(v_start)].point)];
        const p_end = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(v_end)].point)];

        const line_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.lines.items.len));
        try g_arena.lines.append(allocator, .{ .start = p_start, .end = p_end });
        curves_buf[i] = .{ .index = line_idx, .curve_type = .line };
    }

    return addFaceWithCurves(allocator, t_arena, vertices, curves_buf, surface_id, twin_map);
}

/// Adds a planar face while automatically computing its exact 3D Plane surface from its first 3 points.
pub fn addPolygonFaceAutoPlane(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    vertices: []const topo_types.VertexIndex,
    twin_map: *std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex),
) GenError!topo_types.FaceIndex {
    std.debug.assert(vertices.len >= 3);
    const p0 = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(vertices[0])].point)];
    const p1 = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(vertices[1])].point)];
    const p2 = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(vertices[2])].point)];

    const plane_idx = @as(u32, @intCast(g_arena.planes.items.len));
    try g_arena.planes.append(allocator, computePlaneFromPoints(p0, p1, p2));

    const surf_id = geom_types.SurfaceId{
        .index = @enumFromInt(plane_idx),
        .surface_type = .plane,
    };

    return addPolygonFace(allocator, t_arena, g_arena, vertices, surf_id, twin_map);
}

/// Packages shell_faces starting from `sh_faces_start` into a single Shell and Solid container.
pub fn packageSingleShellSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    sh_faces_start: u32,
) GenError!topo_types.SolidIndex {
    const num_faces = @as(u32, @intCast(t_arena.shell_faces.items.len - sh_faces_start));
    const shell_id = @as(topo_types.ShellIndex, @enumFromInt(t_arena.shells.items.len));
    try t_arena.shells.append(allocator, .{
        .faces_start = sh_faces_start,
        .faces_len = num_faces,
    });

    const solid_id = @as(topo_types.SolidIndex, @enumFromInt(t_arena.solids.items.len));
    const so_shells_start = @as(u32, @intCast(t_arena.solid_shells.items.len));
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{
        .shells_start = so_shells_start,
        .shells_len = 1,
    });

    return solid_id;
}

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
        const quad = [_]topo_types.VertexIndex{
            @enumFromInt(v_start + f_idx[0]),
            @enumFromInt(v_start + f_idx[1]),
            @enumFromInt(v_start + f_idx[2]),
            @enumFromInt(v_start + f_idx[3]),
        };
        const surf_handle = geom_types.SurfaceId{ .index = @enumFromInt(p_start + @as(u32, @intCast(i))), .surface_type = .plane };
        const face_id = try addPolygonFace(allocator, t_arena, g_arena, &quad, surf_handle, &twin_map);
        try t_arena.shell_faces.append(allocator, face_id);
    }

    return packageSingleShellSolid(allocator, t_arena, sh_faces_start);
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

    const p_start = @as(u32, @intCast(g_arena.points.items.len));
    const v_start = @as(u32, @intCast(t_arena.vertices.items.len));

    const p0 = math.Vec3{ radius, 0.0, oz };
    const p1 = math.Vec3{ -radius, 0.0, oz };
    const p2 = math.Vec3{ -radius, 0.0, oz + height };
    const p3 = math.Vec3{ radius, 0.0, oz + height };

    try g_arena.points.append(allocator, p0);
    try g_arena.points.append(allocator, p1);
    try g_arena.points.append(allocator, p2);
    try g_arena.points.append(allocator, p3);

    for (0..4) |i| {
        try t_arena.vertices.append(allocator, .{
            .point = @as(geom_types.PointIndex, @enumFromInt(p_start + @as(u32, @intCast(i)))),
        });
    }

    const v0 = @as(topo_types.VertexIndex, @enumFromInt(v_start + 0));
    const v1 = @as(topo_types.VertexIndex, @enumFromInt(v_start + 1));
    const v2 = @as(topo_types.VertexIndex, @enumFromInt(v_start + 2));
    const v3 = @as(topo_types.VertexIndex, @enumFromInt(v_start + 3));

    // Cap Planes
    const bot_plane_idx = @as(geom_types.SurfaceIndex, @enumFromInt(g_arena.planes.items.len));
    try g_arena.planes.append(allocator, .{ .origin = .{ 0.0, 0.0, oz }, .u_axis = .{ 1.0, 0.0, 0.0 }, .v_axis = .{ 0.0, -1.0, 0.0 } });

    const top_plane_idx = @as(geom_types.SurfaceIndex, @enumFromInt(g_arena.planes.items.len));
    try g_arena.planes.append(allocator, .{ .origin = .{ 0.0, 0.0, oz + height }, .u_axis = .{ 1.0, 0.0, 0.0 }, .v_axis = .{ 0.0, 1.0, 0.0 } });

    // Analytical Quadric Surface
    const cyl_surf_idx = @as(geom_types.SurfaceIndex, @enumFromInt(g_arena.cylinders.items.len));
    try g_arena.cylinders.append(allocator, .{
        .origin = .{ 0.0, 0.0, oz },
        .axis = .{ 0.0, 0.0, 1.0 },
        .x_axis = .{ 1.0, 0.0, 0.0 },
        .y_axis = .{ 0.0, 1.0, 0.0 },
        .radius = radius,
    });

    // Circular Arcs
    const bot_arc_pos_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.circle_arcs.items.len));
    try g_arena.circle_arcs.append(allocator, .{ .center = .{ 0.0, 0.0, oz }, .radius = radius, .x_axis = .{ 1.0, 0.0, 0.0 }, .y_axis = .{ 0.0, 1.0, 0.0 } });

    const bot_arc_neg_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.circle_arcs.items.len));
    try g_arena.circle_arcs.append(allocator, .{ .center = .{ 0.0, 0.0, oz }, .radius = radius, .x_axis = .{ -1.0, 0.0, 0.0 }, .y_axis = .{ 0.0, -1.0, 0.0 } });

    const top_arc_pos_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.circle_arcs.items.len));
    try g_arena.circle_arcs.append(allocator, .{ .center = .{ 0.0, 0.0, oz + height }, .radius = radius, .x_axis = .{ 1.0, 0.0, 0.0 }, .y_axis = .{ 0.0, 1.0, 0.0 } });

    const top_arc_neg_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.circle_arcs.items.len));
    try g_arena.circle_arcs.append(allocator, .{ .center = .{ 0.0, 0.0, oz + height }, .radius = radius, .x_axis = .{ -1.0, 0.0, 0.0 }, .y_axis = .{ 0.0, -1.0, 0.0 } });

    // Vertical Seam Lines
    const seam_180_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.lines.items.len));
    try g_arena.lines.append(allocator, .{ .start = p1, .end = p2 });

    const seam_0_idx = @as(geom_types.CurveIndex, @enumFromInt(g_arena.lines.items.len));
    try g_arena.lines.append(allocator, .{ .start = p0, .end = p3 });

    const bot_surf_id = geom_types.SurfaceId{ .index = bot_plane_idx, .surface_type = .plane };
    const top_surf_id = geom_types.SurfaceId{ .index = top_plane_idx, .surface_type = .plane };
    const cyl_surf_id = geom_types.SurfaceId{ .index = cyl_surf_idx, .surface_type = .cylinder };

    const c_bot_pos = geom_types.CurveId{ .index = bot_arc_pos_idx, .curve_type = .circle_arc };
    const c_bot_neg = geom_types.CurveId{ .index = bot_arc_neg_idx, .curve_type = .circle_arc };
    const c_top_pos = geom_types.CurveId{ .index = top_arc_pos_idx, .curve_type = .circle_arc };
    const c_top_neg = geom_types.CurveId{ .index = top_arc_neg_idx, .curve_type = .circle_arc };
    const c_seam_180 = geom_types.CurveId{ .index = seam_180_idx, .curve_type = .line };
    const c_seam_0 = geom_types.CurveId{ .index = seam_0_idx, .curve_type = .line };

    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));

    // Face 0: Bottom Cap
    const f0 = try addFaceWithCurves(allocator, t_arena, &[_]topo_types.VertexIndex{ v0, v1 }, &[_]geom_types.CurveId{ c_bot_neg, c_bot_pos }, bot_surf_id, &twin_map);
    try t_arena.shell_faces.append(allocator, f0);

    // Face 1: Top Cap
    const f1 = try addFaceWithCurves(allocator, t_arena, &[_]topo_types.VertexIndex{ v3, v2 }, &[_]geom_types.CurveId{ c_top_pos, c_top_neg }, top_surf_id, &twin_map);
    try t_arena.shell_faces.append(allocator, f1);

    // Face 2: Front Half-Cylinder
    const f2 = try addFaceWithCurves(allocator, t_arena, &[_]topo_types.VertexIndex{ v0, v1, v2, v3 }, &[_]geom_types.CurveId{ c_bot_pos, c_seam_180, c_top_pos, c_seam_0 }, cyl_surf_id, &twin_map);
    try t_arena.shell_faces.append(allocator, f2);

    // Face 3: Back Half-Cylinder
    const f3 = try addFaceWithCurves(allocator, t_arena, &[_]topo_types.VertexIndex{ v1, v0, v3, v2 }, &[_]geom_types.CurveId{ c_bot_neg, c_seam_0, c_top_neg, c_seam_180 }, cyl_surf_id, &twin_map);
    try t_arena.shell_faces.append(allocator, f3);

    return packageSingleShellSolid(allocator, t_arena, sh_faces_start);
}

pub fn generateSphere(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    radius: f64,
) GenError!topo_types.SolidIndex {
    const rings: u32 = 8;
    const segments: u32 = 16;

    const v_start = @as(u32, @intCast(t_arena.vertices.items.len));
    const p_start = @as(u32, @intCast(g_arena.points.items.len));
    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));
    const first_he_idx = t_arena.half_edges.items.len;

    const top_pt = math.Vec3{ 0, 0, radius };
    try g_arena.points.append(allocator, top_pt);
    try t_arena.vertices.append(allocator, .{ .point = @as(geom_types.PointIndex, @enumFromInt(p_start)) });

    const bot_pt = math.Vec3{ 0, 0, -radius };
    try g_arena.points.append(allocator, bot_pt);
    try t_arena.vertices.append(allocator, .{ .point = @as(geom_types.PointIndex, @enumFromInt(p_start + 1)) });

    for (1..rings) |r| {
        const phi = std.math.pi * @as(f64, @floatFromInt(r)) / @as(f64, @floatFromInt(rings));
        const sin_phi = @sin(phi);
        const cos_phi = @cos(phi);

        for (0..segments) |s| {
            const theta = 2.0 * std.math.pi * @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(segments));
            const pt = math.Vec3{
                radius * sin_phi * @cos(theta),
                radius * sin_phi * @sin(theta),
                radius * cos_phi,
            };
            const pt_idx = @as(u32, @intCast(g_arena.points.items.len));
            try g_arena.points.append(allocator, pt);
            try t_arena.vertices.append(allocator, .{ .point = @as(geom_types.PointIndex, @enumFromInt(pt_idx)) });
        }
    }

    const top_v = @as(topo_types.VertexIndex, @enumFromInt(v_start + 0));
    const bot_v = @as(topo_types.VertexIndex, @enumFromInt(v_start + 1));

    const ringVertex = struct {
        fn get(v_base: u32, r_idx: usize, s_idx: usize, segs: u32) topo_types.VertexIndex {
            const idx = v_base + 2 + @as(u32, @intCast(r_idx * segs + (s_idx % segs)));
            return @as(topo_types.VertexIndex, @enumFromInt(idx));
        }
    }.get;

    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    // 1. Build Top Cap
    for (0..segments) |s| {
        const tri = [_]topo_types.VertexIndex{ top_v, ringVertex(v_start, 0, s, segments), ringVertex(v_start, 0, s + 1, segments) };
        const f_id = try addPolygonFaceAutoPlane(allocator, t_arena, g_arena, &tri, &twin_map);
        try t_arena.shell_faces.append(allocator, f_id);
    }

    // 2. Build Intermediate Bands
    if (rings > 2) {
        for (0..rings - 2) |r| {
            for (0..segments) |s| {
                const quad = [_]topo_types.VertexIndex{
                    ringVertex(v_start, r, s, segments),
                    ringVertex(v_start, r + 1, s, segments),
                    ringVertex(v_start, r + 1, s + 1, segments),
                    ringVertex(v_start, r, s + 1, segments),
                };
                const f_id = try addPolygonFaceAutoPlane(allocator, t_arena, g_arena, &quad, &twin_map);
                try t_arena.shell_faces.append(allocator, f_id);
            }
        }
    }

    // 3. Build Bottom Cap
    for (0..segments) |s| {
        const tri = [_]topo_types.VertexIndex{ bot_v, ringVertex(v_start, rings - 2, s + 1, segments), ringVertex(v_start, rings - 2, s, segments) };
        const f_id = try addPolygonFaceAutoPlane(allocator, t_arena, g_arena, &tri, &twin_map);
        try t_arena.shell_faces.append(allocator, f_id);
    }

    // Post-stitch twins for half-edges allocated before twin_map was active
    for (first_he_idx..t_arena.half_edges.items.len) |i| {
        const he = &t_arena.half_edges.items[i];
        if (he.twin != topo_types.NULL_HALF_EDGE) continue;
        const next_he = t_arena.half_edges.items[@intFromEnum(he.next)];
        const key = EdgeKey.init(he.start_vertex, next_he.start_vertex);
        if (twin_map.get(key)) |twin_idx| {
            he.twin = twin_idx;
            t_arena.half_edges.items[@intFromEnum(twin_idx)].twin = @enumFromInt(i);
        }
    }

    return packageSingleShellSolid(allocator, t_arena, sh_faces_start);
}

pub fn generateSquare(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    size_x: f64,
    size_y: f64,
    centered: bool,
) GenError!topo_types.SolidIndex {
    const ox = if (centered) -size_x / 2.0 else 0.0;
    const oy = if (centered) -size_y / 2.0 else 0.0;
    const mx = ox + size_x;
    const my = oy + size_y;
    const pts = [_][2]f64{ .{ ox, oy }, .{ mx, oy }, .{ mx, my }, .{ ox, my } };
    return generatePolygon(allocator, t_arena, g_arena, &pts);
}

pub fn generateCircle(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    radius: f64,
    segments: i32,
) GenError!topo_types.SolidIndex {
    const segs = if (segments < 3) 32 else @as(usize, @intCast(segments));
    var pts = try allocator.alloc([2]f64, segs);
    defer allocator.free(pts);
    for (0..segs) |i| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segs));
        pts[i] = .{ radius * @cos(angle), radius * @sin(angle) };
    }
    return generatePolygon(allocator, t_arena, g_arena, pts);
}

pub fn addMultiLoopFace(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    loops: []const []const topo_types.VertexIndex,
    surface_id: geom_types.SurfaceId,
    twin_map: *std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex),
) GenError!topo_types.FaceIndex {
    const f_loops_start = @as(u32, @intCast(t_arena.face_loops.items.len));

    for (loops) |vertices| {
        const loop_id = @as(topo_types.LoopIndex, @enumFromInt(t_arena.loops.items.len));
        const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));
        const n = vertices.len;

        for (0..n) |i| {
            const v_start = vertices[i];
            const v_end = vertices[(i + 1) % n];

            const p_start = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(v_start)].point)];
            const p_end = g_arena.points.items[@intFromEnum(t_arena.vertices.items[@intFromEnum(v_end)].point)];

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
        try t_arena.loops.append(allocator, .{ .face_id = topo_types.NULL_FACE, .first_half_edge = @enumFromInt(he_start) });
        try t_arena.face_loops.append(allocator, loop_id);
    }

    const face_id = @as(topo_types.FaceIndex, @enumFromInt(t_arena.faces.items.len));
    try t_arena.faces.append(allocator, .{
        .surface = surface_id,
        .forward = true,
        .loops_start = f_loops_start,
        .loops_len = @intCast(loops.len),
    });

    for (0..loops.len) |i| {
        const loop_id = t_arena.face_loops.items[f_loops_start + i];
        t_arena.loops.items[@intFromEnum(loop_id)].face_id = face_id;
    }

    return face_id;
}

pub fn generatePolygon(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    pts: []const [2]f64,
) GenError!topo_types.SolidIndex {
    var vert_ids = try allocator.alloc(topo_types.VertexIndex, pts.len);
    defer allocator.free(vert_ids);

    for (pts, 0..) |pt, i| {
        const pt_idx = @as(u32, @intCast(g_arena.points.items.len));
        try g_arena.points.append(allocator, .{ pt[0], pt[1], 0.0 });
        const v_id = @as(topo_types.VertexIndex, @enumFromInt(t_arena.vertices.items.len));
        try t_arena.vertices.append(allocator, .{ .point = @enumFromInt(pt_idx) });
        vert_ids[i] = v_id;
    }

    const plane_idx = @as(u32, @intCast(g_arena.planes.items.len));
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    const surf_id = geom_types.SurfaceId{ .index = @enumFromInt(plane_idx), .surface_type = .plane };
    const face_id = try addPolygonFace(allocator, t_arena, g_arena, vert_ids, surf_id, &twin_map);

    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));
    try t_arena.shell_faces.append(allocator, face_id);

    return packageSingleShellSolid(allocator, t_arena, sh_faces_start);
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

    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));

    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    for (faces) |f| {
        const tri_verts = [_]topo_types.VertexIndex{
            @enumFromInt(v_start + f[0]),
            @enumFromInt(v_start + f[1]),
            @enumFromInt(v_start + f[2]),
        };

        const face_id = try addPolygonFaceAutoPlane(allocator, t_arena, g_arena, &tri_verts, &twin_map);
        try t_arena.shell_faces.append(allocator, face_id);
    }

    return packageSingleShellSolid(allocator, t_arena, sh_faces_start);
}

pub fn generatePolygonsEvenOdd(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    contours: []const []const [2]f64,
) GenError!topo_types.SolidIndex {
    const plane_idx = @as(u32, @intCast(g_arena.planes.items.len));
    try g_arena.planes.append(allocator, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });
    var twin_map = std.AutoHashMap(EdgeKey, topo_types.HalfEdgeIndex).init(allocator);
    defer twin_map.deinit();

    var loops_verts = std.ArrayListUnmanaged([]topo_types.VertexIndex).empty;
    defer {
        for (loops_verts.items) |arr| allocator.free(arr);
        loops_verts.deinit(allocator);
    }

    for (contours) |pts| {
        var vert_ids = try allocator.alloc(topo_types.VertexIndex, pts.len);
        for (pts, 0..) |pt, i| {
            const pt_idx = @as(u32, @intCast(g_arena.points.items.len));
            try g_arena.points.append(allocator, .{ pt[0], pt[1], 0.0 });
            const v_id = @as(topo_types.VertexIndex, @enumFromInt(t_arena.vertices.items.len));
            try t_arena.vertices.append(allocator, .{ .point = @enumFromInt(pt_idx) });
            vert_ids[i] = v_id;
        }
        try loops_verts.append(allocator, vert_ids);
    }

    const surf_id = geom_types.SurfaceId{ .index = @enumFromInt(plane_idx), .surface_type = .plane };
    const face_id = try addMultiLoopFace(allocator, t_arena, g_arena, loops_verts.items, surf_id, &twin_map);

    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));
    try t_arena.shell_faces.append(allocator, face_id);

    return packageSingleShellSolid(allocator, t_arena, sh_faces_start);
}
