const std = @import("std");
const math_env = @import("../math_env.zig");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const geom_types = @import("../geometry/types.zig");
const verifier = @import("../topology/verifier.zig");

pub const FixtureData = struct {
    version: u32 = 1,
    tolerance: f64 = 1e-6,
    points: [][3]f64,
    vertices: []u32, // PointIndex array
    half_edges: []SerializedHalfEdge,
    loops: []SerializedLoop,
    faces: []SerializedFace,
    shells: []SerializedShell,
    solids: []SerializedSolid,
    solid_shells: []u32,
    shell_faces: []u32,
    face_loops: []u32,
    target_solid: u32,
    lines: []SerializedLine = &.{},
    planes: []SerializedPlane = &.{},
    circle_arcs: []SerializedCircleArc = &.{},
    cylinders: []SerializedCylinder = &.{},

    pub const SerializedHalfEdge = struct {
        start_vertex: u32,
        twin: u32,
        next: u32,
        prev: u32,
        loop_id: u32,
        curve_type: u8,
        curve_index: u32,
        forward: bool,
    };

    pub const SerializedLoop = struct {
        face_id: u32,
        first_half_edge: u32,
    };

    pub const SerializedFace = struct {
        surface_type: u8,
        surface_index: u32,
        forward: bool,
        loops_start: u32,
        loops_len: u32,
    };

    pub const SerializedShell = struct {
        faces_start: u32,
        faces_len: u32,
    };

    pub const SerializedSolid = struct {
        shells_start: u32,
        shells_len: u32,
    };

    pub const SerializedLine = struct {
        start: [3]f64,
        end: [3]f64,
    };

    pub const SerializedPlane = struct {
        origin: [3]f64,
        u_axis: [3]f64,
        v_axis: [3]f64,
    };

    pub const SerializedCircleArc = struct {
        center: [3]f64,
        radius: f64,
        x_axis: [3]f64,
        y_axis: [3]f64,
    };

    pub const SerializedCylinder = struct {
        origin: [3]f64,
        axis: [3]f64,
        x_axis: [3]f64,
        y_axis: [3]f64,
        radius: f64,
    };
};

pub const Fixture = struct {
    pub fn dump(
        allocator: std.mem.Allocator,
        t_arena: *const topo_arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        solid_idx: topo_types.SolidIndex,
        env: math_env.MathEnv,
    ) ![]const u8 {
        const points = try allocator.alloc([3]f64, g_arena.points.items.len);
        defer allocator.free(points);
        @memcpy(points, g_arena.points.items);

        const lines = try allocator.alloc(FixtureData.SerializedLine, g_arena.lines.items.len);
        defer allocator.free(lines);
        for (g_arena.lines.items, 0..) |l, i| {
            lines[i] = .{ .start = l.start, .end = l.end };
        }

        const planes = try allocator.alloc(FixtureData.SerializedPlane, g_arena.planes.items.len);
        defer allocator.free(planes);
        for (g_arena.planes.items, 0..) |p, i| {
            planes[i] = .{ .origin = p.origin, .u_axis = p.u_axis, .v_axis = p.v_axis };
        }

        const circle_arcs = try allocator.alloc(FixtureData.SerializedCircleArc, g_arena.circle_arcs.items.len);
        defer allocator.free(circle_arcs);
        for (g_arena.circle_arcs.items, 0..) |a, i| {
            circle_arcs[i] = .{ .center = a.center, .radius = a.radius, .x_axis = a.x_axis, .y_axis = a.y_axis };
        }

        const cylinders = try allocator.alloc(FixtureData.SerializedCylinder, g_arena.cylinders.items.len);
        defer allocator.free(cylinders);
        for (g_arena.cylinders.items, 0..) |c, i| {
            cylinders[i] = .{ .origin = c.origin, .axis = c.axis, .x_axis = c.x_axis, .y_axis = c.y_axis, .radius = c.radius };
        }

        const vertices = try allocator.alloc(u32, t_arena.vertices.items.len);
        defer allocator.free(vertices);
        for (t_arena.vertices.items, 0..) |v, i| {
            vertices[i] = @intFromEnum(v.point);
        }

        const half_edges = try allocator.alloc(FixtureData.SerializedHalfEdge, t_arena.half_edges.items.len);
        defer allocator.free(half_edges);
        for (t_arena.half_edges.items, 0..) |he, i| {
            half_edges[i] = .{
                .start_vertex = @intFromEnum(he.start_vertex),
                .twin = @intFromEnum(he.twin),
                .next = @intFromEnum(he.next),
                .prev = @intFromEnum(he.prev),
                .loop_id = @intFromEnum(he.loop_id),
                .curve_type = @intFromEnum(he.curve.curve_type),
                .curve_index = @intFromEnum(he.curve.index),
                .forward = he.forward,
            };
        }

        const loops = try allocator.alloc(FixtureData.SerializedLoop, t_arena.loops.items.len);
        defer allocator.free(loops);
        for (t_arena.loops.items, 0..) |l, i| {
            loops[i] = .{
                .face_id = @intFromEnum(l.face_id),
                .first_half_edge = @intFromEnum(l.first_half_edge),
            };
        }

        const faces = try allocator.alloc(FixtureData.SerializedFace, t_arena.faces.items.len);
        defer allocator.free(faces);
        for (t_arena.faces.items, 0..) |f, i| {
            faces[i] = .{
                .surface_type = @intFromEnum(f.surface.surface_type),
                .surface_index = @intFromEnum(f.surface.index),
                .forward = f.forward,
                .loops_start = f.loops_start,
                .loops_len = f.loops_len,
            };
        }

        const shells = try allocator.alloc(FixtureData.SerializedShell, t_arena.shells.items.len);
        defer allocator.free(shells);
        for (t_arena.shells.items, 0..) |sh, i| {
            shells[i] = .{
                .faces_start = sh.faces_start,
                .faces_len = sh.faces_len,
            };
        }

        const solids = try allocator.alloc(FixtureData.SerializedSolid, t_arena.solids.items.len);
        defer allocator.free(solids);
        for (t_arena.solids.items, 0..) |so, i| {
            solids[i] = .{
                .shells_start = so.shells_start,
                .shells_len = so.shells_len,
            };
        }

        const solid_shells = try allocator.alloc(u32, t_arena.solid_shells.items.len);
        defer allocator.free(solid_shells);
        for (t_arena.solid_shells.items, 0..) |s_idx, i| solid_shells[i] = @intFromEnum(s_idx);

        const shell_faces = try allocator.alloc(u32, t_arena.shell_faces.items.len);
        defer allocator.free(shell_faces);
        for (t_arena.shell_faces.items, 0..) |f_idx, i| shell_faces[i] = @intFromEnum(f_idx);

        const face_loops = try allocator.alloc(u32, t_arena.face_loops.items.len);
        defer allocator.free(face_loops);
        for (t_arena.face_loops.items, 0..) |l_idx, i| face_loops[i] = @intFromEnum(l_idx);

        const data = FixtureData{
            .tolerance = env.vertex_tolerance,
            .points = points,
            .lines = lines,
            .planes = planes,
            .circle_arcs = circle_arcs,
            .cylinders = cylinders,
            .vertices = vertices,
            .half_edges = half_edges,
            .loops = loops,
            .faces = faces,
            .shells = shells,
            .solids = solids,
            .solid_shells = solid_shells,
            .shell_faces = shell_faces,
            .face_loops = face_loops,
            .target_solid = @intFromEnum(solid_idx),
        };

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.print("{f}", .{std.json.fmt(data, .{ .whitespace = .indent_2 })});
        return try out.toOwnedSlice();
    }

    pub fn load(
        allocator: std.mem.Allocator,
        json_content: []const u8,
        t_arena: *topo_arena.TopologyArena,
        g_arena: *geom_arena.GeometryArena,
    ) !struct { solid_idx: topo_types.SolidIndex, env: math_env.MathEnv } {
        var parsed = try std.json.parseFromSlice(FixtureData, allocator, json_content, .{});
        defer parsed.deinit();

        const data = parsed.value;

        for (data.points) |p| {
            try g_arena.points.append(allocator, p);
        }

        for (data.lines) |l| {
            try g_arena.lines.append(allocator, .{ .start = l.start, .end = l.end });
        }
        for (data.planes) |p| {
            try g_arena.planes.append(allocator, .{ .origin = p.origin, .u_axis = p.u_axis, .v_axis = p.v_axis });
        }
        for (data.circle_arcs) |a| {
            try g_arena.circle_arcs.append(allocator, .{ .center = a.center, .radius = a.radius, .x_axis = a.x_axis, .y_axis = a.y_axis });
        }
        for (data.cylinders) |c| {
            try g_arena.cylinders.append(allocator, .{ .origin = c.origin, .axis = c.axis, .x_axis = c.x_axis, .y_axis = c.y_axis, .radius = c.radius });
        }

        for (data.vertices) |pt_idx| {
            try t_arena.vertices.append(allocator, .{ .point = @enumFromInt(pt_idx) });
        }

        for (data.half_edges) |he| {
            try t_arena.half_edges.append(allocator, .{
                .start_vertex = @enumFromInt(he.start_vertex),
                .twin = @enumFromInt(he.twin),
                .next = @enumFromInt(he.next),
                .prev = @enumFromInt(he.prev),
                .loop_id = @enumFromInt(he.loop_id),
                .curve = .{
                    .index = @enumFromInt(he.curve_index),
                    .curve_type = @enumFromInt(he.curve_type),
                },
                .forward = he.forward,
            });
        }

        for (data.loops) |l| {
            try t_arena.loops.append(allocator, .{
                .face_id = @enumFromInt(l.face_id),
                .first_half_edge = @enumFromInt(l.first_half_edge),
            });
        }

        for (data.faces) |f| {
            try t_arena.faces.append(allocator, .{
                .surface = .{
                    .index = @enumFromInt(f.surface_index),
                    .surface_type = @enumFromInt(f.surface_type),
                },
                .forward = f.forward,
                .loops_start = f.loops_start,
                .loops_len = f.loops_len,
            });
        }

        for (data.shells) |sh| {
            try t_arena.shells.append(allocator, .{
                .faces_start = sh.faces_start,
                .faces_len = sh.faces_len,
            });
        }

        for (data.solids) |so| {
            try t_arena.solids.append(allocator, .{
                .shells_start = so.shells_start,
                .shells_len = so.shells_len,
            });
        }

        for (data.solid_shells) |s_idx| try t_arena.solid_shells.append(allocator, @enumFromInt(s_idx));
        for (data.shell_faces) |f_idx| try t_arena.shell_faces.append(allocator, @enumFromInt(f_idx));
        for (data.face_loops) |l_idx| try t_arena.face_loops.append(allocator, @enumFromInt(l_idx));

        return .{
            .solid_idx = @enumFromInt(data.target_solid),
            .env = .{ .vertex_tolerance = data.tolerance },
        };
    }
};
