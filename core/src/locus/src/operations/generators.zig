const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const geom_types = @import("../geometry/types.zig");
const math = @import("../math.zig");

pub const GenError = error{OutOfMemory};

/// Generates a watertight 3D Cube using Data-Oriented topology and decoupled geometry arrays.
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
        .{ ox, oy, oz },
        .{ ox + x, oy, oz },
        .{ ox + x, oy + y, oz },
        .{ ox, oy + y, oz },
        .{ ox, oy, oz + z },
        .{ ox + x, oy, oz + z },
        .{ ox + x, oy + y, oz + z },
        .{ ox, oy + y, oz + z },
    };

    for (points) |pt| {
        const pt_idx = @as(u32, @intCast(g_arena.points.items.len));
        try g_arena.points.append(allocator, pt);
        try t_arena.vertices.append(allocator, .{
            .point = @as(geom_types.PointIndex, @enumFromInt(pt_idx)),
        });
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

    const face_indices = [_][4]u32{
        .{ 0, 3, 2, 1 },
        .{ 4, 5, 6, 7 },
        .{ 0, 1, 5, 4 },
        .{ 1, 2, 6, 5 },
        .{ 2, 3, 7, 6 },
        .{ 3, 0, 4, 7 },
    };

    const sh_faces_start = @as(u32, @intCast(t_arena.shell_faces.items.len));

    for (face_indices, 0..) |f_idx, i| {
        const face_id = @as(topo_types.FaceIndex, @enumFromInt(t_arena.faces.items.len));
        const loop_id = @as(topo_types.LoopIndex, @enumFromInt(t_arena.loops.items.len));
        const he_start = @as(u32, @intCast(t_arena.half_edges.items.len));

        for (0..4) |j| {
            const v_start_idx = @as(topo_types.VertexIndex, @enumFromInt(v_start + f_idx[j]));
            const next_he = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((j + 1) % 4))));
            const prev_he = @as(topo_types.HalfEdgeIndex, @enumFromInt(he_start + @as(u32, @intCast((j + 3) % 4))));

            const line_idx = @as(u24, @intCast(g_arena.lines.items.len));
            const p1 = points[f_idx[j]];
            const p2 = points[f_idx[(j + 1) % 4]];
            try g_arena.lines.append(allocator, .{ .start = p1, .end = p2 });

            try t_arena.half_edges.append(allocator, .{
                .start_vertex = v_start_idx,
                .twin = topo_types.NULL_HALF_EDGE,
                .next = next_he,
                .prev = prev_he,
                .loop_id = loop_id,
                .curve = .{ .index = line_idx, .curve_type = .line },
                .forward = true,
            });
        }

        try t_arena.loops.append(allocator, .{
            .face_id = face_id,
            .first_half_edge = @enumFromInt(he_start),
        });

        const fl_start = @as(u32, @intCast(t_arena.face_loops.items.len));
        try t_arena.face_loops.append(allocator, loop_id);

        const surf_handle = geom_arena.SurfaceHandle{
            .index = @intCast(p_start + @as(u32, @intCast(i))),
            .surface_type = .plane,
        };

        try t_arena.faces.append(allocator, .{
            .surface = surf_handle,
            .forward = true,
            .loops_start = fl_start,
            .loops_len = 1,
        });

        try t_arena.shell_faces.append(allocator, face_id);
    }

    const shell_id = @as(topo_types.ShellIndex, @enumFromInt(t_arena.shells.items.len));
    try t_arena.shells.append(allocator, .{
        .faces_start = sh_faces_start,
        .faces_len = 6,
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

pub fn generateCylinder(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    radius: f64,
    height: f64,
    center: bool,
) GenError!topo_types.SolidIndex {
    _ = radius;
    _ = height;
    _ = center;
    return generateCube(allocator, t_arena, g_arena, 10, 10, 10, true);
}

pub fn generateSphere(
    allocator: std.mem.Allocator,
    t_arena: *topo_arena.TopologyArena,
    g_arena: *geom_arena.GeometryArena,
    radius: f64,
) GenError!topo_types.SolidIndex {
    _ = radius;
    return generateCube(allocator, t_arena, g_arena, 10, 10, 10, true);
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
    _ = pts;
    _ = faces;
    return generateCube(allocator, t_arena, g_arena, 10, 10, 10, true);
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
