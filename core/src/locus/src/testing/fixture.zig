const std = @import("std");
const math_env = @import("../math_env.zig");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");

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
            vertices[i] = @backingInt(v.point);
        }

        const half_edges = try allocator.alloc(FixtureData.SerializedHalfEdge, t_arena.half_edges.items.len);
        defer allocator.free(half_edges);
        for (t_arena.half_edges.items, 0..) |he, i| {
            half_edges[i] = .{
                .start_vertex = @backingInt(he.start_vertex),
                .twin = @backingInt(he.twin),
                .next = @backingInt(he.next),
                .prev = @backingInt(he.prev),
                .loop_id = @backingInt(he.loop_id),
                .curve_type = @backingInt(he.curve.curve_type),
                .curve_index = @backingInt(he.curve.index),
                .forward = he.forward,
            };
        }

        const loops = try allocator.alloc(FixtureData.SerializedLoop, t_arena.loops.items.len);
        defer allocator.free(loops);
        for (t_arena.loops.items, 0..) |l, i| {
            loops[i] = .{
                .face_id = @backingInt(l.face_id),
                .first_half_edge = @backingInt(l.first_half_edge),
            };
        }

        const faces = try allocator.alloc(FixtureData.SerializedFace, t_arena.faces.items.len);
        defer allocator.free(faces);
        for (t_arena.faces.items, 0..) |f, i| {
            faces[i] = .{
                .surface_type = @backingInt(f.surface.surface_type),
                .surface_index = @backingInt(f.surface.index),
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
        for (t_arena.solid_shells.items, 0..) |s_idx, i| solid_shells[i] = @backingInt(s_idx);

        const shell_faces = try allocator.alloc(u32, t_arena.shell_faces.items.len);
        defer allocator.free(shell_faces);
        for (t_arena.shell_faces.items, 0..) |f_idx, i| shell_faces[i] = @backingInt(f_idx);

        const face_loops = try allocator.alloc(u32, t_arena.face_loops.items.len);
        defer allocator.free(face_loops);
        for (t_arena.face_loops.items, 0..) |l_idx, i| face_loops[i] = @backingInt(l_idx);

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
            .target_solid = @backingInt(solid_idx),
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
            try t_arena.vertices.append(allocator, .{ .point = @fromBackingInt(pt_idx) });
        }

        for (data.half_edges) |he| {
            try t_arena.half_edges.append(allocator, .{
                .start_vertex = @fromBackingInt(he.start_vertex),
                .twin = @fromBackingInt(he.twin),
                .next = @fromBackingInt(he.next),
                .prev = @fromBackingInt(he.prev),
                .loop_id = @fromBackingInt(he.loop_id),
                .curve = .{
                    .index = @fromBackingInt(he.curve_index),
                    .curve_type = @fromBackingInt(he.curve_type),
                },
                .forward = he.forward,
            });
        }

        for (data.loops) |l| {
            try t_arena.loops.append(allocator, .{
                .face_id = @fromBackingInt(l.face_id),
                .first_half_edge = @fromBackingInt(l.first_half_edge),
            });
        }

        for (data.faces) |f| {
            try t_arena.faces.append(allocator, .{
                .surface = .{
                    .index = @fromBackingInt(f.surface_index),
                    .surface_type = @fromBackingInt(f.surface_type),
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

        for (data.solid_shells) |s_idx| try t_arena.solid_shells.append(allocator, @fromBackingInt(s_idx));
        for (data.shell_faces) |f_idx| try t_arena.shell_faces.append(allocator, @fromBackingInt(f_idx));
        for (data.face_loops) |l_idx| try t_arena.face_loops.append(allocator, @fromBackingInt(l_idx));

        return .{
            .solid_idx = @fromBackingInt(data.target_solid),
            .env = .{ .vertex_tolerance = data.tolerance },
        };
    }

    /// VCR/Snapshot style testing helper.
    /// If the file exists, it asserts the current state matches the file.
    /// If the file is missing, it records the current state to the file and returns error.SnapshotCreated.
    pub fn matchSnapshot(
        allocator: std.mem.Allocator,
        io: std.Io,
        file_path: []const u8,
        t_arena: *const topo_arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        solid_idx: topo_types.SolidIndex,
        env: math_env.MathEnv,
    ) !void {
        // 1. Generate the current topological state as JSON
        const current_json = try dump(allocator, t_arena, g_arena, solid_idx, env);
        defer allocator.free(current_json);

        const cwd = std.Io.Dir.cwd();

        // 2. Ensure parent directory exists
        if (std.fs.path.dirname(file_path)) |dir_path| {
            _ = cwd.createDirPath(io, dir_path) catch |err| {
                std.log.warn("Failed to create snapshot dir: {}", .{err});
            };
        }

        // 3. Try to open the existing snapshot
        var file = cwd.openFile(io, file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // 4a. Record new snapshot if missing
                var new_file = try cwd.createFile(io, file_path, .{});
                defer new_file.close(io);

                // Write out the JSON using the positional writer wrapper
                try std.Io.File.writePositionalAll(new_file, io, current_json, 0);

                std.log.warn("\n[!] Created new snapshot at: {s}\n[!] Please review the generated JSON and rerun the tests.\n", .{file_path});
                return error.SnapshotCreated; // Fail intentionally so CI doesn't silently ignore missing files
            }
            return err;
        };
        defer file.close(io);

        // 4b. Verify existing snapshot
        const file_len = try file.length(io);
        const expected_json = try allocator.alloc(u8, file_len);
        defer allocator.free(expected_json);

        const read_len = try std.Io.File.readPositionalAll(file, io, expected_json, 0);

        // Uses std.testing to give us a nice diff output if the geometries diverge
        std.testing.expectEqualStrings(expected_json[0..read_len], current_json) catch |err| {
            std.log.err("\n[X] Snapshot mismatch for {s}! The generator logic has changed.\n", .{file_path});
            return err;
        };
    }
};
