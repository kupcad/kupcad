const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const GeneratorError = error{
    OutOfMemory,
};

/// Generates a Cube and pushes its elements into the topology and geometry arenas[cite: 14].
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
    const line_start: u24 = @intCast(g_arena.lines.items.len); // Track specific geometry array index

    const edge_pairs = [_][2]u32{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, // Bottom
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, // Top
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // Vertical
    };

    for (edge_pairs, 0..) |pair, i| {
        const start_pt = t_arena.vertices.items[v_start + pair[0]].point;
        const end_pt = t_arena.vertices.items[v_start + pair[1]].point;

        // Push directly to the lines array, bypassing unions[cite: 14]
        try g_arena.lines.append(g_arena.allocator, .{ .start = start_pt, .end = end_pt });

        try t_arena.edges.append(t_arena.allocator, .{
            .front = v_start + pair[0],
            .back = v_start + pair[1],
            // Construct the packed 32-bit ID[cite: 14]
            .curve = .{ .index = line_start + @as(u24, @intCast(i)), .curve_type = .line },
        });
    }

    // 3. Create 6 Faces (and their geometric planes)
    const f_start: u32 = @intCast(t_arena.faces.items.len);
    const plane_start: u24 = @intCast(g_arena.planes.items.len); // Track specific geometry array index

    // Each face is defined by a 4-edge loop (index relative to e_start) and orientation[cite: 14]
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
        // Push directly to the planes array[cite: 14]
        try g_arena.planes.append(g_arena.allocator, .{ .origin = loop.o, .u_axis = loop.u, .v_axis = loop.v });

        // Push wire topology[cite: 14]
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

        // Push face topology[cite: 14]
        const f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
        try t_arena.face_wires.append(t_arena.allocator, w_start); // 1 wire per face

        try t_arena.faces.append(t_arena.allocator, .{
            // Construct the packed 32-bit ID[cite: 14]
            .surface = .{ .index = plane_start + @as(u24, @intCast(i)), .surface_type = .plane },
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

/// Generates a B-Rep Cylinder along the Z axis.
pub fn generateCylinder(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    radius: f64,
    height: f64,
    centered: bool,
) GeneratorError!topo.SolidId {
    const oz = if (centered) -height / 2.0 else 0.0;
    const mz = oz + height;

    // 1. Vertices (2 on bottom rim, 2 on top rim)
    const v_start: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.appendSlice(t_arena.allocator, &[_]topo.Vertex{
        .{ .point = .{ radius, 0, oz } }, // 0: Bottom +X
        .{ .point = .{ -radius, 0, oz } }, // 1: Bottom -X
        .{ .point = .{ radius, 0, mz } }, // 2: Top +X
        .{ .point = .{ -radius, 0, mz } }, // 3: Top -X
    });

    // 2. Edges & Curves
    const arc_start: u24 = @intCast(g_arena.circle_arcs.items.len);
    const line_start: u24 = @intCast(g_arena.lines.items.len);
    const e_start: u32 = @intCast(t_arena.edges.items.len);

    try g_arena.circle_arcs.appendSlice(g_arena.allocator, &[_]geom.CircleArc{
        .{ .center = .{ 0, 0, oz }, .radius = radius, .x_axis = .{ 1, 0, 0 }, .y_axis = .{ 0, 1, 0 } }, // Bottom Arc 1 (y+)
        .{ .center = .{ 0, 0, oz }, .radius = radius, .x_axis = .{ -1, 0, 0 }, .y_axis = .{ 0, -1, 0 } }, // Bottom Arc 2 (y-)
        .{ .center = .{ 0, 0, mz }, .radius = radius, .x_axis = .{ 1, 0, 0 }, .y_axis = .{ 0, 1, 0 } }, // Top Arc 1 (y+)
        .{ .center = .{ 0, 0, mz }, .radius = radius, .x_axis = .{ -1, 0, 0 }, .y_axis = .{ 0, -1, 0 } }, // Top Arc 2 (y-)
    });

    try g_arena.lines.appendSlice(g_arena.allocator, &[_]geom.Line{
        .{ .start = .{ radius, 0, oz }, .end = .{ radius, 0, mz } }, // Seam 1 (+X)
        .{ .start = .{ -radius, 0, oz }, .end = .{ -radius, 0, mz } }, // Seam 2 (-X)
    });

    try t_arena.edges.appendSlice(t_arena.allocator, &[_]topo.Edge{
        .{ .front = v_start + 0, .back = v_start + 1, .curve = .{ .index = arc_start + 0, .curve_type = .circle_arc } }, // e0: Bot Arc1
        .{ .front = v_start + 1, .back = v_start + 0, .curve = .{ .index = arc_start + 1, .curve_type = .circle_arc } }, // e1: Bot Arc2
        .{ .front = v_start + 2, .back = v_start + 3, .curve = .{ .index = arc_start + 2, .curve_type = .circle_arc } }, // e2: Top Arc1
        .{ .front = v_start + 3, .back = v_start + 2, .curve = .{ .index = arc_start + 3, .curve_type = .circle_arc } }, // e3: Top Arc2
        .{ .front = v_start + 0, .back = v_start + 2, .curve = .{ .index = line_start + 0, .curve_type = .line } }, // e4: Seam1 (+X)
        .{ .front = v_start + 1, .back = v_start + 3, .curve = .{ .index = line_start + 1, .curve_type = .line } }, // e5: Seam2 (-X)
    });

    // 3. Faces & Surfaces
    const f_start: u32 = @intCast(t_arena.faces.items.len);

    // Push geometric surfaces
    const plane_start: u24 = @intCast(g_arena.planes.items.len);
    try g_arena.planes.appendSlice(g_arena.allocator, &[_]geom.Plane{
        .{ .origin = .{ 0, 0, oz }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, -1, 0 } }, // Bottom Plane (Normal -Z)
        .{ .origin = .{ 0, 0, mz }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } }, // Top Plane (Normal +Z)
    });

    const cyl_start: u24 = @intCast(g_arena.cylinders.items.len);
    try g_arena.cylinders.append(g_arena.allocator, .{ .origin = .{ 0, 0, oz }, .axis = .{ 0, 0, 1 }, .x_axis = .{ 1, 0, 0 }, .y_axis = .{ 0, 1, 0 }, .radius = radius });

    // Define face loops (edges relative to e_start)
    const face_loops = [_]struct { edges: []const u32, forward: []const bool, surf: geom.SurfaceId }{
        // Bottom Face (Bot Arc1, Bot Arc2 - reversed to face outward)
        .{ .edges = &.{ 0, 1 }, .forward = &.{ false, false }, .surf = .{ .index = plane_start + 0, .surface_type = .plane } },
        // Top Face (Top Arc1, Top Arc2)
        .{ .edges = &.{ 2, 3 }, .forward = &.{ true, true }, .surf = .{ .index = plane_start + 1, .surface_type = .plane } },
        // Side Face 1 (+Y half): Bot Arc1, Seam2, Top Arc1 (rev), Seam1 (rev)
        .{ .edges = &.{ 0, 5, 2, 4 }, .forward = &.{ true, true, false, false }, .surf = .{ .index = cyl_start, .surface_type = .cylinder } },
        // Side Face 2 (-Y half): Bot Arc2, Seam1, Top Arc2 (rev), Seam2 (rev)
        .{ .edges = &.{ 1, 4, 3, 5 }, .forward = &.{ true, true, false, false }, .surf = .{ .index = cyl_start, .surface_type = .cylinder } },
    };

    for (face_loops) |loop| {
        const w_edges_start: u32 = @intCast(t_arena.wire_edges.items.len);
        for (loop.edges, loop.forward) |e_idx, fwd| {
            try t_arena.wire_edges.append(t_arena.allocator, .{ .edge = e_start + e_idx, .forward = fwd });
        }
        const w_start: u32 = @intCast(t_arena.wires.items.len);
        try t_arena.wires.append(t_arena.allocator, .{ .edges_start = w_edges_start, .edges_len = @intCast(loop.edges.len) });

        const f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
        try t_arena.face_wires.append(t_arena.allocator, w_start);

        try t_arena.faces.append(t_arena.allocator, .{
            .surface = loop.surf,
            .forward = true,
            .wires_start = f_wires_start,
            .wires_len = 1,
        });
    }

    // 4. Create 1 Shell & 1 Solid
    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    for (0..4) |i| try t_arena.shell_faces.append(t_arena.allocator, f_start + @as(u32, @intCast(i)));
    try t_arena.shells.append(t_arena.allocator, .{ .faces_start = sh_faces_start, .faces_len = 4 });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(t_arena.allocator, shell_start);
    try t_arena.solids.append(t_arena.allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

/// Generates a B-Rep Sphere.
pub fn generateSphere(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    radius: f64,
) GeneratorError!topo.SolidId {
    // 1. Create North and South pole vertices
    const v_start: u32 = @intCast(t_arena.vertices.items.len);
    try t_arena.vertices.appendSlice(t_arena.allocator, &[_]topo.Vertex{
        .{ .point = .{ 0, 0, -radius } }, // 0: South Pole
        .{ .point = .{ 0, 0, radius } }, // 1: North Pole
    });

    // 2. Create semi-circular seam edges connecting the poles
    const arc_start: u24 = @intCast(g_arena.circle_arcs.items.len);
    const e_start: u32 = @intCast(t_arena.edges.items.len);

    try g_arena.circle_arcs.appendSlice(g_arena.allocator, &[_]geom.CircleArc{
        .{ .center = .{ 0, 0, 0 }, .radius = radius, .x_axis = .{ 1, 0, 0 }, .y_axis = .{ 0, 0, 1 } }, // Arc 1 (+X)
        .{ .center = .{ 0, 0, 0 }, .radius = radius, .x_axis = .{ -1, 0, 0 }, .y_axis = .{ 0, 0, 1 } }, // Arc 2 (-X)
    });

    try t_arena.edges.appendSlice(t_arena.allocator, &[_]topo.Edge{
        .{ .front = v_start + 0, .back = v_start + 1, .curve = .{ .index = arc_start + 0, .curve_type = .circle_arc } }, // e0: Bot to Top
        .{ .front = v_start + 1, .back = v_start + 0, .curve = .{ .index = arc_start + 1, .curve_type = .circle_arc } }, // e1: Top to Bot
    });

    // 3. Create spherical surfaces and hemispherical faces
    const f_start: u32 = @intCast(t_arena.faces.items.len);
    const surf_start: u24 = @intCast(g_arena.spheres.items.len);

    try g_arena.spheres.append(g_arena.allocator, .{
        .center = .{ 0, 0, 0 },
        .radius = radius,
    });

    const surf_id = geom.SurfaceId{ .index = surf_start, .surface_type = .sphere };

    const face_loops = [_]struct { edges: []const u32, forward: []const bool }{
        .{ .edges = &.{ 0, 1 }, .forward = &.{ true, true } }, // Hemisphere 1
        .{ .edges = &.{ 1, 0 }, .forward = &.{ false, false } }, // Hemisphere 2
    };

    for (face_loops) |loop| {
        const w_edges_start: u32 = @intCast(t_arena.wire_edges.items.len);
        for (loop.edges, loop.forward) |e_idx, fwd| {
            try t_arena.wire_edges.append(t_arena.allocator, .{ .edge = e_start + e_idx, .forward = fwd });
        }
        const w_start: u32 = @intCast(t_arena.wires.items.len);
        try t_arena.wires.append(t_arena.allocator, .{ .edges_start = w_edges_start, .edges_len = @intCast(loop.edges.len) });

        const f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
        try t_arena.face_wires.append(t_arena.allocator, w_start);

        try t_arena.faces.append(t_arena.allocator, .{
            .surface = surf_id,
            .forward = true,
            .wires_start = f_wires_start,
            .wires_len = 1,
        });
    }

    // 4. Create 1 Shell & 1 Solid
    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    for (0..2) |i| try t_arena.shell_faces.append(t_arena.allocator, f_start + @as(u32, @intCast(i)));
    try t_arena.shells.append(t_arena.allocator, .{ .faces_start = sh_faces_start, .faces_len = 2 });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(t_arena.allocator, shell_start);
    try t_arena.solids.append(t_arena.allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}
