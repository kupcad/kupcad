const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const qh = @import("quickhull.zig");
const generators = @import("generators.zig");

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
    // 1. Extract unique 3D vertices from Solid A and Solid B by traversing Half-Edge loops
    var verts_a = extractSolidVertices(allocator, t_arena, solid_a) catch return error.OutOfMemory;
    defer verts_a.deinit(allocator);

    var verts_b = extractSolidVertices(allocator, t_arena, solid_b) catch return error.OutOfMemory;
    defer verts_b.deinit(allocator);

    // 2. Compute the Minkowski Point Cloud (Pairwise Sum of all vertex pairs)
    var point_cloud: std.ArrayListUnmanaged(math.Vec3) = .empty;
    defer point_cloud.deinit(allocator);

    point_cloud.ensureTotalCapacity(allocator, verts_a.items.len * verts_b.items.len) catch return error.OutOfMemory;

    for (verts_a.items) |va| {
        for (verts_b.items) |vb| {
            point_cloud.appendAssumeCapacity(math.add(va, vb));
        }
    }

    // 3. Feed the resulting point cloud into the Quickhull 3D convex hull generator
    var builder = qh.QuickhullBuilder.init(allocator, point_cloud.items);
    defer builder.deinit();

    builder.buildHull() catch return error.NotEnoughPoints;

    // 4. Convert Quickhull triangular faces into Half-Edge B-Rep topology
    var v_map = std.AutoHashMap(u32, topo.VertexId).init(allocator);
    defer v_map.deinit();

    var twin_map = std.AutoHashMap(generators.EdgeKey, topo.HalfEdgeId).init(allocator);
    defer twin_map.deinit();

    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);
    var face_count: u32 = 0;

    for (builder.faces.items) |hull_face| {
        if (hull_face.disabled) continue;

        // Extract the ordered vertex sequence for this convex hull face
        var face_v_ids: std.ArrayListUnmanaged(topo.VertexId) = .empty;
        defer face_v_ids.deinit(allocator);

        var curr_he_idx = hull_face.first_half_edge;
        var started = false;

        while (!started or curr_he_idx != hull_face.first_half_edge) {
            started = true;
            const he = builder.half_edges.items[@as(usize, @intCast(curr_he_idx))];

            // Trace backward along the Quickhull half-edge loop to find the start vertex (p0)
            var prev_he_idx = he.next_edge;
            while (builder.half_edges.items[@as(usize, @intCast(prev_he_idx))].next_edge != curr_he_idx) {
                prev_he_idx = builder.half_edges.items[@as(usize, @intCast(prev_he_idx))].next_edge;
            }
            const p0_idx = builder.half_edges.items[@as(usize, @intCast(prev_he_idx))].end_vertex;

            // Register and deduplicate 3D topological vertices
            if (!v_map.contains(p0_idx)) {
                const new_v_id: u32 = @intCast(t_arena.vertices.items.len);
                try t_arena.vertices.append(allocator, .{ .point = point_cloud.items[@as(usize, @intCast(p0_idx))] });
                try v_map.put(p0_idx, new_v_id);
            }

            try face_v_ids.append(allocator, v_map.get(p0_idx).?);
            curr_he_idx = he.next_edge;
        }

        if (face_v_ids.items.len < 3) continue;

        // Push Plane geometry calculating true U and V axes from the triangle's vertices
        const plane_idx: u24 = @intCast(g_arena.planes.items.len);
        const p0_pos = t_arena.vertices.items[face_v_ids.items[0]].point;
        const p1_pos = t_arena.vertices.items[face_v_ids.items[1]].point;
        const p2_pos = t_arena.vertices.items[face_v_ids.items[2]].point;

        const u_axis = math.normalize(math.sub(p1_pos, p0_pos));
        var normal = math.normalize(math.cross(u_axis, math.sub(p2_pos, p0_pos)));

        // Fallback to Quickhull's calculated normal if vertices are nearly degenerate
        if (math.magSq(normal) < 1e-12) normal = hull_face.plane_normal;

        const v_axis = math.normalize(math.cross(normal, u_axis));

        try g_arena.planes.append(allocator, .{
            .origin = p0_pos,
            .u_axis = u_axis,
            .v_axis = v_axis,
        });

        // Wire Half-Edges, Loops, and Face using the generator helper
        const surf_id = geom.SurfaceId{ .index = plane_idx, .surface_type = .plane };
        const face_id = try generators.addPolygonFace(allocator, t_arena, g_arena, face_v_ids.items, surf_id, &twin_map);
        try t_arena.shell_faces.append(allocator, face_id);
        face_count += 1;
    }

    // 5. Package all new faces into a Shell and Solid
    const shell_id: u32 = @intCast(t_arena.shells.items.len);
    try t_arena.shells.append(allocator, .{
        .faces_start = sh_faces_start,
        .faces_len = face_count,
    });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(allocator, shell_id);
    try t_arena.solids.append(allocator, .{
        .shells_start = so_shells_start,
        .shells_len = 1,
    });

    return solid_id;
}

/// Helper to gather all unique 3D vertex coordinates from a solid by traversing its Half-Edge loops.
fn extractSolidVertices(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    solid_id: topo.SolidId,
) !std.ArrayListUnmanaged(math.Vec3) {
    var verts: std.ArrayListUnmanaged(math.Vec3) = .empty;
    var seen = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer seen.deinit();

    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_offset| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_offset];
        const shell = t_arena.shells.items[shell_id];

        for (0..shell.faces_len) |f_offset| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_offset];
            const face = t_arena.faces.items[face_id];

            for (0..face.loops_len) |l_offset| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_offset];
                const loop = t_arena.loops.items[loop_id];

                var curr_he = loop.first_half_edge;
                while (true) {
                    const he = t_arena.half_edges.items[curr_he];
                    const v_id = he.start_vertex;

                    if (!seen.contains(v_id)) {
                        try seen.put(v_id, {});
                        try verts.append(allocator, t_arena.vertices.items[v_id].point);
                    }

                    curr_he = he.next;
                    if (curr_he == loop.first_half_edge) break;
                }
            }
        }
    }
    return verts;
}
