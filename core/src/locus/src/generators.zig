const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const GeneratorError = error{
    OutOfMemory,
};

/// Generates a Cube and pushes its elements into the topology and geometry arenas.
pub fn generateCube(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    size_x: f64,
    size_y: f64,
    size_z: f64,
    centered: bool,
) GeneratorError!topo.SolidId {
    const ox = if (centered) -size_x / 2.0 else 0.0;
    const oy = if (centered) -size_y / 2.0 else 0.0;
    const oz = if (centered) -size_z / 2.0 else 0.0;

    const mx = ox + size_x;
    const my = oy + size_y;
    const mz = oz + size_z;

    // 1. Create 8 Vertices
    const v_start: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.appendSlice(t_arena.allocator, &[_]topo.Vertex{
        // Bottom 4
        .{ .point = .{ ox, oy, oz } }, // 0
        .{ .point = .{ mx, oy, oz } }, // 1
        .{ .point = .{ mx, my, oz } }, // 2
        .{ .point = .{ ox, my, oz } }, // 3
        // Top 4
        .{ .point = .{ ox, oy, mz } }, // 4
        .{ .point = .{ mx, oy, mz } }, // 5
        .{ .point = .{ mx, my, mz } }, // 6
        .{ .point = .{ ox, my, mz } }, // 7
    });

    // 2. Create 12 Edges (and their geometric lines)
    const e_start: u32 = @intCast(t_arena.edges.items.len);
    const c_start: u32 = @intCast(g_arena.curves.items.len);

    const edge_pairs = [_][2]u32{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, // Bottom
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, // Top
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // Vertical
    };

    for (edge_pairs, 0..) |pair, i| {
        const start_pt = t_arena.vertices.items[v_start + pair[0]].point;
        const end_pt = t_arena.vertices.items[v_start + pair[1]].point;

        try g_arena.curves.append(g_arena.allocator, .{ .line = .{ .start = start_pt, .end = end_pt } });

        try t_arena.edges.append(t_arena.allocator, .{
            .front = v_start + pair[0],
            .back = v_start + pair[1],
            .curve_idx = c_start + @as(u32, @intCast(i)),
        });
    }

    // 3. Create 6 Faces (and their geometric planes)
    const f_start: u32 = @intCast(t_arena.faces.items.len);
    const s_start: u32 = @intCast(g_arena.surfaces.items.len);

    // Each face is defined by a 4-edge loop (index relative to e_start) and orientation
    const face_loops = [_]struct { edges: [4]u32, forward: [4]bool, u: math.Vec3, v: math.Vec3, o: math.Vec3 }{
        // Bottom (Z-)
        .{ .edges = .{ 0, 1, 2, 3 }, .forward = .{ false, false, false, false }, .u = .{ 1, 0, 0 }, .v = .{ 0, -1, 0 }, .o = .{ ox, my, oz } },
        // Top (Z+)
        .{ .edges = .{ 4, 5, 6, 7 }, .forward = .{ true, true, true, true }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .o = .{ ox, oy, mz } },
        // Front (Y-)
        .{ .edges = .{ 0, 9, 4, 8 }, .forward = .{ true, true, false, false }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 }, .o = .{ ox, oy, oz } },
        // Right (X+)
        .{ .edges = .{ 1, 10, 5, 9 }, .forward = .{ true, true, false, false }, .u = .{ 0, 1, 0 }, .v = .{ 0, 0, 1 }, .o = .{ mx, oy, oz } },
        // Back (Y+)
        .{ .edges = .{ 2, 11, 6, 10 }, .forward = .{ true, true, false, false }, .u = .{ -1, 0, 0 }, .v = .{ 0, 0, 1 }, .o = .{ mx, my, oz } },
        // Left (X-)
        .{ .edges = .{ 3, 8, 7, 11 }, .forward = .{ true, true, false, false }, .u = .{ 0, -1, 0 }, .v = .{ 0, 0, 1 }, .o = .{ ox, my, oz } },
    };

    for (face_loops, 0..) |loop, i| {
        // Push plane geometry
        try g_arena.surfaces.append(g_arena.allocator, .{ .plane = .{ .origin = loop.o, .u_axis = loop.u, .v_axis = loop.v } });

        // Push wire topology
        const w_edges_start: u32 = @intCast(t_arena.wire_edges.items.len);
        for (loop.edges, loop.forward) |e_idx, fwd| {
            try t_arena.wire_edges.append(t_arena.allocator, .{
                .edge = e_start + e_idx,
                .forward = fwd,
            });
        }

        const w_start: u32 = @intCast(t_arena.wires.items.len);
        try t_arena.wires.append(t_arena.allocator, .{
            .edges_start = w_edges_start,
            .edges_len = 4,
        });

        // Push face topology
        const f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
        try t_arena.face_wires.append(t_arena.allocator, w_start); // 1 wire per face

        try t_arena.faces.append(t_arena.allocator, .{
            .surface_idx = s_start + @as(u32, @intCast(i)),
            .forward = true,
            .wires_start = f_wires_start,
            .wires_len = 1,
        });
    }

    // 4. Create 1 Shell
    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    for (0..6) |i| {
        try t_arena.shell_faces.append(t_arena.allocator, f_start + @as(u32, @intCast(i)));
    }
    try t_arena.shells.append(t_arena.allocator, .{
        .faces_start = sh_faces_start,
        .faces_len = 6,
    });

    // 5. Create 1 Solid
    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(t_arena.allocator, shell_start);

    try t_arena.solids.append(t_arena.allocator, .{
        .shells_start = so_shells_start,
        .shells_len = 1,
    });

    return solid_id;
}
