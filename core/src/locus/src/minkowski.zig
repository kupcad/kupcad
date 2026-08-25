const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const qh = @import("quickhull.zig");

pub const MinkowskiError = error{
    OutOfMemory,
    DegenerateInput,
    NotEnoughPoints,
};

/// Computes the 3D Minkowski sum of two convex solids using Pairwise Addition + Quickhull.
pub fn minkowskiSumConvex(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
) MinkowskiError!topo.SolidId {
    // 1. Extract unique vertices from Solid A and Solid B
    var verts_a = extractSolidVertices(allocator, t_arena, solid_a) catch return error.OutOfMemory;
    defer verts_a.deinit(allocator);

    var verts_b = extractSolidVertices(allocator, t_arena, solid_b) catch return error.OutOfMemory;
    defer verts_b.deinit(allocator);

    // 2. Compute the Minkowski Point Cloud (Pairwise Sum)
    var point_cloud: std.ArrayListUnmanaged(math.Vec3) = .empty;
    defer point_cloud.deinit(allocator);

    point_cloud.ensureTotalCapacity(allocator, verts_a.items.len * verts_b.items.len) catch return error.OutOfMemory;

    for (verts_a.items) |va| {
        for (verts_b.items) |vb| {
            point_cloud.appendAssumeCapacity(math.add(va, vb));
        }
    }

    // 3. Feed the point cloud into Quickhull
    var builder = qh.QuickhullBuilder.init(allocator, point_cloud.items);
    defer builder.deinit();

    builder.buildHull() catch return error.NotEnoughPoints;

    // 4. Convert Quickhull output back into B-Rep Topology
    var v_map = std.AutoHashMap(u32, topo.VertexId).init(allocator);
    defer v_map.deinit();

    // Edge map key: u64 formed by (min(v1,v2) << 32) | max(v1,v2) to prevent duplicate edges
    var e_map = std.AutoHashMap(u64, topo.EdgeId).init(allocator);
    defer e_map.deinit();

    const f_start: u32 = @intCast(t_arena.faces.items.len);
    var valid_faces: u32 = 0;

    for (builder.faces.items) |hull_face| {
        if (hull_face.disabled) continue;

        // Push Plane geometry
        const surf_idx: u24 = @intCast(g_arena.planes.items.len);
        try g_arena.planes.append(allocator, .{
            .origin = point_cloud.items[@as(usize, @intCast(builder.half_edges.items[@as(usize, @intCast(hull_face.first_half_edge))].end_vertex))],
            .u_axis = .{ 1, 0, 0 }, // Simplified local basis
            .v_axis = .{ 0, 1, 0 },
        });
        const surf_id = geom.SurfaceId{ .index = surf_idx, .surface_type = .plane };

        const w_edges_start: u32 = @intCast(t_arena.wire_edges.items.len);
        var edge_count: u32 = 0;

        var curr_he_idx = hull_face.first_half_edge;
        var started = false;

        // Walk the half-edge loop to build the Wire
        while (!started or curr_he_idx != hull_face.first_half_edge) {
            started = true;
            const he = builder.half_edges.items[@as(usize, @intCast(curr_he_idx))];
            const p1_idx = he.end_vertex;

            // Find previous half-edge to get the start vertex (p0)
            var prev_he_idx = he.next_edge;
            while (builder.half_edges.items[@as(usize, @intCast(prev_he_idx))].next_edge != curr_he_idx) {
                prev_he_idx = builder.half_edges.items[@as(usize, @intCast(prev_he_idx))].next_edge;
            }
            const p0_idx = builder.half_edges.items[@as(usize, @intCast(prev_he_idx))].end_vertex;

            // Register Vertices
            if (!v_map.contains(p0_idx)) {
                try v_map.put(p0_idx, @intCast(t_arena.vertices.items.len));
                try t_arena.vertices.append(allocator, .{ .point = point_cloud.items[@as(usize, @intCast(p0_idx))] });
            }
            if (!v_map.contains(p1_idx)) {
                try v_map.put(p1_idx, @intCast(t_arena.vertices.items.len));
                try t_arena.vertices.append(allocator, .{ .point = point_cloud.items[@as(usize, @intCast(p1_idx))] });
            }

            const t_v0 = v_map.get(p0_idx).?;
            const t_v1 = v_map.get(p1_idx).?;

            // Register Edge (Deduplicated)
            const min_v = @min(p0_idx, p1_idx);
            const max_v = @max(p0_idx, p1_idx);
            const edge_key = (@as(u64, min_v) << 32) | @as(u64, max_v);

            var t_edge_id: topo.EdgeId = 0;
            var forward = (p0_idx == min_v);

            if (!e_map.contains(edge_key)) {
                const line_idx: u24 = @intCast(g_arena.lines.items.len);
                try g_arena.lines.append(allocator, .{
                    .start = t_arena.vertices.items[t_v0].point,
                    .end = t_arena.vertices.items[t_v1].point,
                });

                t_edge_id = @intCast(t_arena.edges.items.len);
                try t_arena.edges.append(allocator, .{
                    .front = t_v0,
                    .back = t_v1,
                    .curve = .{ .index = line_idx, .curve_type = .line },
                });
                try e_map.put(edge_key, t_edge_id);
                forward = true;
            } else {
                t_edge_id = e_map.get(edge_key).?;
                const existing_edge = t_arena.edges.items[t_edge_id];
                forward = (existing_edge.front == t_v0);
            }

            try t_arena.wire_edges.append(allocator, .{ .edge = t_edge_id, .forward = forward });
            edge_count += 1;
            curr_he_idx = he.next_edge;
        }

        // Connect the Wire to the Face
        const w_start: u32 = @intCast(t_arena.wires.items.len);
        try t_arena.wires.append(allocator, .{ .edges_start = w_edges_start, .edges_len = edge_count });

        const f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
        try t_arena.face_wires.append(allocator, w_start);

        try t_arena.faces.append(allocator, .{
            .surface = surf_id,
            .forward = true,
            .wires_start = f_wires_start,
            .wires_len = 1,
        });

        valid_faces += 1;
    }

    // 5. Build Shell and Solid
    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    for (0..valid_faces) |i| {
        try t_arena.shell_faces.append(allocator, f_start + @as(u32, @intCast(i)));
    }
    try t_arena.shells.append(allocator, .{ .faces_start = sh_faces_start, .faces_len = valid_faces });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_start);
    try t_arena.solids.append(allocator, .{ .shells_start = so_shells_start, .shells_len = 1 });

    return solid_id;
}

/// Helper to gather all unique vertex coordinates from a solid.
fn extractSolidVertices(allocator: std.mem.Allocator, t_arena: *topo.TopologyArena, solid_id: topo.SolidId) !std.ArrayListUnmanaged(math.Vec3) {
    var verts: std.ArrayListUnmanaged(math.Vec3) = .empty;
    var seen = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer seen.deinit();

    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_offset| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start + s_offset]];
        for (0..shell.faces_len) |f_offset| {
            const face = t_arena.faces.items[t_arena.shell_faces.items[shell.faces_start + f_offset]];
            for (0..face.wires_len) |w_offset| {
                const wire = t_arena.wires.items[t_arena.face_wires.items[face.wires_start + w_offset]];
                for (0..wire.edges_len) |e_offset| {
                    const edge = t_arena.edges.items[t_arena.wire_edges.items[wire.edges_start + e_offset].edge];
                    for ([_]topo.VertexId{ edge.front, edge.back }) |v_id| {
                        if (!seen.contains(v_id)) {
                            try seen.put(v_id, {});
                            try verts.append(allocator, t_arena.vertices.items[v_id].point);
                        }
                    }
                }
            }
        }
    }
    return verts;
}
