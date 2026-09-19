const std = @import("std");
const topo_arena = @import("topology/arena.zig");
const topo_types = @import("topology/types.zig");
const geom_arena = @import("geometry/arena.zig");
const math = @import("math.zig");

pub const DebugDumper = struct {
    pub fn dumpSolidToObj(
        allocator: std.mem.Allocator,
        io: std.Io,
        filepath: []const u8,
        t_arena: *const topo_arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        solid_id: topo_types.SolidIndex,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        var vertex_map = std.AutoHashMap(topo_types.VertexIndex, usize).init(allocator);
        defer vertex_map.deinit();

        var v_count: usize = 1; // OBJ indices are 1-based

        const solid = t_arena.solids.items[@intFromEnum(solid_id)];

        // 1. Pass: Dump all unique referenced 3D vertices
        for (0..solid.shells_len) |s_off| {
            const shell_idx = t_arena.solid_shells.items[solid.shells_start + s_off];
            const shell = t_arena.shells.items[@intFromEnum(shell_idx)];
            for (0..shell.faces_len) |f_off| {
                const face_idx = t_arena.shell_faces.items[shell.faces_start + f_off];
                const face = t_arena.faces.items[@intFromEnum(face_idx)];

                for (0..face.loops_len) |l_off| {
                    const loop_idx = t_arena.face_loops.items[face.loops_start + l_off];
                    const loop = t_arena.loops.items[@intFromEnum(loop_idx)];
                    var curr_he = loop.first_half_edge;

                    var safety: usize = 0;
                    while (true) : (safety += 1) {
                        if (safety > 10_000) return error.TopologyCorrupted;
                        const he = t_arena.half_edges.items[@intFromEnum(curr_he)];

                        if (!vertex_map.contains(he.start_vertex)) {
                            try vertex_map.put(he.start_vertex, v_count);
                            const pt_idx = t_arena.vertices.items[@intFromEnum(he.start_vertex)].point;
                            const p = g_arena.points.items[@intFromEnum(pt_idx)];
                            try out.writer.print("v {d:.6} {d:.6} {d:.6}\n", .{ p[0], p[1], p[2] });
                            v_count += 1;
                        }

                        curr_he = he.next;
                        if (curr_he == loop.first_half_edge) break;
                    }
                }
            }
        }

        // 2. Pass: Dump all half-edges as explicit lines
        for (0..solid.shells_len) |s_off| {
            const shell_idx = t_arena.solid_shells.items[solid.shells_start + s_off];
            const shell = t_arena.shells.items[@intFromEnum(shell_idx)];
            for (0..shell.faces_len) |f_off| {
                const face_idx = t_arena.shell_faces.items[shell.faces_start + f_off];
                const face = t_arena.faces.items[@intFromEnum(face_idx)];

                for (0..face.loops_len) |l_off| {
                    const loop_idx = t_arena.face_loops.items[face.loops_start + l_off];
                    const loop = t_arena.loops.items[@intFromEnum(loop_idx)];
                    var curr_he = loop.first_half_edge;

                    var safety: usize = 0;
                    while (true) : (safety += 1) {
                        if (safety > 10_000) break;
                        const he = t_arena.half_edges.items[@intFromEnum(curr_he)];
                        const next_he = t_arena.half_edges.items[@intFromEnum(he.next)];

                        const v1_obj = vertex_map.get(he.start_vertex).?;
                        const v2_obj = vertex_map.get(next_he.start_vertex).?;

                        try out.writer.print("l {} {}\n", .{ v1_obj, v2_obj });

                        curr_he = he.next;
                        if (curr_he == loop.first_half_edge) break;
                    }
                }
            }
        }

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{
            .sub_path = filepath,
            .data = out.written(),
        });
    }

    /// Dumps 2D parameter space UVs to SVG for debugging loops and winding order on curved surfaces.
    pub fn dumpParametricToSvg(
        allocator: std.mem.Allocator,
        io: std.Io,
        filepath: []const u8,
        t_arena: *const topo_arena.TopologyArena,
        g_arena: *const geom_arena.GeometryArena,
        face_id: topo_types.FaceIndex,
        width: usize,
        height: usize,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        try out.writer.print(
            \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1" width="{d}" height="{d}">
            \\<rect width="1" height="1" fill="#1e1e1e" />
            \\
        , .{ width, height });

        const face = t_arena.faces.items[@intFromEnum(face_id)];

        for (0..face.loops_len) |l_off| {
            const loop_idx = t_arena.face_loops.items[face.loops_start + l_off];
            const loop = t_arena.loops.items[@intFromEnum(loop_idx)];

            try out.writer.writeAll("<polyline fill=\"none\" stroke=\"#007acc\" stroke-width=\"0.005\" points=\"");

            var curr_he = loop.first_half_edge;
            var safety: usize = 0;
            while (true) : (safety += 1) {
                if (safety > 10_000) return error.TopologyCorrupted;

                const he = t_arena.half_edges.items[@intFromEnum(curr_he)];

                // Use cached boundary UV if available, otherwise project the 3D point dynamically
                const uv = he.start_uv orelse blk: {
                    const pt_idx = t_arena.vertices.items[@intFromEnum(he.start_vertex)].point;
                    const p = g_arena.points.items[@intFromEnum(pt_idx)];
                    break :blk g_arena.surfaceProject(face.surface, p);
                };

                try out.writer.print("{d:.6},{d:.6} ", .{ uv[0], 1.0 - uv[1] }); // Y inverted for SVG

                curr_he = he.next;
                if (curr_he == loop.first_half_edge) break;
            }

            // Close the loop explicitly in SVG by re-emitting the first vertex
            const first_he = t_arena.half_edges.items[@intFromEnum(loop.first_half_edge)];
            const first_uv = first_he.start_uv orelse blk: {
                const pt_idx = t_arena.vertices.items[@intFromEnum(first_he.start_vertex)].point;
                const p = g_arena.points.items[@intFromEnum(pt_idx)];
                break :blk g_arena.surfaceProject(face.surface, p);
            };

            try out.writer.print("{d:.6},{d:.6}\" />\n", .{ first_uv[0], 1.0 - first_uv[1] });
        }

        try out.writer.writeAll("</svg>");

        // Write atomically using KupCAD's VFS/Io integration
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{
            .sub_path = filepath,
            .data = out.written(),
        });
    }
};
