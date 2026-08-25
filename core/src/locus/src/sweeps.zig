const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const SweepError = error{
    OutOfMemory,
    InvalidTopology,
};

/// Extrudes a flat 2D face along a 3D vector to create a Solid[cite: 62].
pub fn extrudeFace(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    base_face_id: topo.FaceId,
    vector: math.Vec3,
) SweepError!topo.SolidId {
    const base_face = t_arena.faces.items[base_face_id];

    // We need to build a map of base vertices to top vertices
    var top_vertex_map = std.AutoHashMap(topo.VertexId, topo.VertexId).init(t_arena.allocator);
    defer top_vertex_map.deinit();

    // 1. Iterate over the base face's wires and edges to find vertices
    var base_edge_ids: std.ArrayListUnmanaged(topo.EdgeId) = .empty;
    defer base_edge_ids.deinit(t_arena.allocator);

    for (0..base_face.wires_len) |w_offset| {
        const wire_id = t_arena.face_wires.items[base_face.wires_start + w_offset];
        const wire = t_arena.wires.items[wire_id];

        for (0..wire.edges_len) |e_offset| {
            const d_edge = t_arena.wire_edges.items[wire.edges_start + e_offset];
            const edge = t_arena.edges.items[d_edge.edge];
            try base_edge_ids.append(t_arena.allocator, d_edge.edge);

            // 2. Duplicate vertices shifted by `vector` for the top cap[cite: 62]
            for ([_]topo.VertexId{ edge.front, edge.back }) |v_id| {
                if (!top_vertex_map.contains(v_id)) {
                    const base_pt = t_arena.vertices.items[v_id].point;
                    const top_pt = math.add(base_pt, vector);

                    const new_v_id: u32 = @intCast(t_arena.vertices.items.len);
                    try t_arena.vertices.append(t_arena.allocator, .{ .point = top_pt });
                    try top_vertex_map.put(v_id, new_v_id);
                }
            }
        }
    }

    // 3. For each edge in the base face, create an Extruded surface and a side Face[cite: 62]
    var side_face_ids: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer side_face_ids.deinit(t_arena.allocator);

    // Inside the extrusion edge loop:
    for (base_edge_ids.items) |e_id| {
        _ = e_id;

        // Push the geometric surface of extrusion directly to planes array for now
        const surf_id: u24 = @intCast(g_arena.planes.items.len);
        try g_arena.planes.append(t_arena.allocator, .{ .origin = .{ 0, 0, 0 }, .u_axis = .{ 1, 0, 0 }, .v_axis = .{ 0, 1, 0 } });

        const side_face_id: u32 = @intCast(t_arena.faces.items.len);
        try t_arena.faces.append(t_arena.allocator, .{
            .surface = .{ .index = surf_id, .surface_type = .plane }, // Use packed struct ID
            .forward = true,
            .wires_start = 0, // Placeholder
            .wires_len = 1,
        });
        try side_face_ids.append(t_arena.allocator, side_face_id);
    }

    // 4. Create the Top Cap and assemble into Shell -> Solid[cite: 62].
    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    try t_arena.solids.append(t_arena.allocator, .{
        .shells_start = 0, // Placeholder
        .shells_len = 1,
    });

    return solid_id;
}
