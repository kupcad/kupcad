const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const SweepError = error{
    OutOfMemory,
    InvalidFace,
};

/// Extrudes a single planar face along a 3D vector to create a new Solid.
pub fn extrudeFace(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    base_face_id: topo.FaceId,
    vec: math.Vec3,
) SweepError!topo.SolidId {
    const alloc = t_arena.allocator;
    const base_face = t_arena.faces.items[base_face_id];

    // Maps original VertexId to newly extruded Top VertexId
    var top_v_map = std.AutoHashMap(topo.VertexId, topo.VertexId).init(alloc);
    defer top_v_map.deinit();

    // Maps original VertexId to the vertical "rib" EdgeId connecting base to top
    var rib_e_map = std.AutoHashMap(topo.VertexId, topo.EdgeId).init(alloc);
    defer rib_e_map.deinit();

    var side_faces: std.ArrayListUnmanaged(topo.FaceId) = .empty;
    defer side_faces.deinit(alloc);

    var top_wire_edges: std.ArrayListUnmanaged(topo.DirectedEdge) = .empty;
    defer top_wire_edges.deinit(alloc);

    // 1. Process the boundary wires of the base face
    for (0..base_face.wires_len) |w_idx| {
        const wire_id = t_arena.face_wires.items[base_face.wires_start + w_idx];
        const wire = t_arena.wires.items[wire_id];

        for (0..wire.edges_len) |e_idx| {
            const d_edge = t_arena.wire_edges.items[wire.edges_start + e_idx];
            const edge = t_arena.edges.items[d_edge.edge];

            // 2. Generate Top Vertices and Vertical Ribs for front/back
            for ([_]topo.VertexId{ edge.front, edge.back }) |v_id| {
                if (!top_v_map.contains(v_id)) {
                    const base_pt = t_arena.vertices.items[v_id].point;
                    const top_pt = math.add(base_pt, vec);

                    const top_v_id: u32 = @intCast(t_arena.vertices.items.len);
                    try t_arena.vertices.append(alloc, .{ .point = top_pt });
                    try top_v_map.put(v_id, top_v_id);

                    // Create vertical rib geometry (Line)
                    const rib_line_idx: u24 = @intCast(g_arena.lines.items.len);
                    try g_arena.lines.append(alloc, .{ .start = base_pt, .end = top_pt });

                    // Create vertical rib topology (Edge)
                    const rib_e_id: u32 = @intCast(t_arena.edges.items.len);
                    try t_arena.edges.append(alloc, .{
                        .front = v_id,
                        .back = top_v_id,
                        .curve = .{ .index = rib_line_idx, .curve_type = .line },
                    });
                    try rib_e_map.put(v_id, rib_e_id);
                }
            }

            // 3. Create the Top Edge (Geometry + Topology)
            const top_front = top_v_map.get(edge.front).?;
            const top_back = top_v_map.get(edge.back).?;

            const top_line_idx: u24 = @intCast(g_arena.lines.items.len);
            try g_arena.lines.append(alloc, .{
                .start = t_arena.vertices.items[top_front].point,
                .end = t_arena.vertices.items[top_back].point,
            });

            const top_e_id: u32 = @intCast(t_arena.edges.items.len);
            try t_arena.edges.append(alloc, .{
                .front = top_front,
                .back = top_back,
                .curve = .{ .index = top_line_idx, .curve_type = .line },
            });

            try top_wire_edges.append(alloc, .{ .edge = top_e_id, .forward = d_edge.forward });

            // 4. Build the Side Face (Plane)
            // Winding order: base edge -> right rib -> top edge (reversed) -> left rib (reversed)
            const sf_origin = t_arena.vertices.items[edge.front].point;
            var sf_u = math.sub(t_arena.vertices.items[edge.back].point, sf_origin);
            if (math.magSq(sf_u) > math.MATH_EPSILON) sf_u = math.normalize(sf_u);
            const sf_v = math.normalize(vec);

            const plane_idx: u24 = @intCast(g_arena.planes.items.len);
            try g_arena.planes.append(alloc, .{ .origin = sf_origin, .u_axis = sf_u, .v_axis = sf_v });

            const sf_w_edges_start: u32 = @intCast(t_arena.wire_edges.items.len);

            // Note: A truly robust kernel would trace the exact orientation, but for a prismatic sweep,
            // this logical loop suffices to close the faces mathematically.
            try t_arena.wire_edges.appendSlice(alloc, &[_]topo.DirectedEdge{
                .{ .edge = d_edge.edge, .forward = d_edge.forward },
                .{ .edge = rib_e_map.get(if (d_edge.forward) edge.back else edge.front).?, .forward = true },
                .{ .edge = top_e_id, .forward = !d_edge.forward },
                .{ .edge = rib_e_map.get(if (d_edge.forward) edge.front else edge.back).?, .forward = false },
            });

            const sf_w_id: u32 = @intCast(t_arena.wires.items.len);
            try t_arena.wires.append(alloc, .{ .edges_start = sf_w_edges_start, .edges_len = 4 });

            const sf_f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
            try t_arena.face_wires.append(alloc, sf_w_id);

            const sf_id: u32 = @intCast(t_arena.faces.items.len);
            try t_arena.faces.append(alloc, .{
                .surface = .{ .index = plane_idx, .surface_type = .plane },
                .forward = true,
                .wires_start = sf_f_wires_start,
                .wires_len = 1,
            });
            try side_faces.append(alloc, sf_id);
        }
    }

    // 5. Construct Top Face
    const top_w_edges_start: u32 = @intCast(t_arena.wire_edges.items.len);
    try t_arena.wire_edges.appendSlice(alloc, top_wire_edges.items);

    const top_w_id: u32 = @intCast(t_arena.wires.items.len);
    try t_arena.wires.append(alloc, .{ .edges_start = top_w_edges_start, .edges_len = @intCast(top_wire_edges.items.len) });

    const top_f_wires_start: u32 = @intCast(t_arena.face_wires.items.len);
    try t_arena.face_wires.append(alloc, top_w_id);

    // Geometry of top face (clone the base surface, shift by vec)
    var top_surf = base_face.surface;
    if (base_face.surface.surface_type == .plane) {
        const base_plane = g_arena.planes.items[base_face.surface.index];
        const new_plane_idx: u24 = @intCast(g_arena.planes.items.len);
        try g_arena.planes.append(alloc, .{
            .origin = math.add(base_plane.origin, vec),
            .u_axis = base_plane.u_axis,
            .v_axis = base_plane.v_axis,
        });
        top_surf = .{ .index = new_plane_idx, .surface_type = .plane };
    }

    const top_face_id: u32 = @intCast(t_arena.faces.items.len);
    try t_arena.faces.append(alloc, .{
        .surface = top_surf,
        .forward = base_face.forward,
        .wires_start = top_f_wires_start,
        .wires_len = 1,
    });

    // 6. Build the final Shell and Solid
    const shell_start: u32 = @intCast(t_arena.shells.items.len);
    const sh_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);

    // Add Base Face, Top Face, and Side Faces to Shell
    try t_arena.shell_faces.append(alloc, base_face_id);
    try t_arena.shell_faces.append(alloc, top_face_id);
    try t_arena.shell_faces.appendSlice(alloc, side_faces.items);

    try t_arena.shells.append(alloc, .{
        .faces_start = sh_faces_start,
        .faces_len = @intCast(2 + side_faces.items.len),
    });

    const solid_id: u32 = @intCast(t_arena.solids.items.len);
    const so_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);
    try t_arena.solid_shells.append(alloc, shell_start);
    try t_arena.solids.append(alloc, .{
        .shells_start = so_shells_start,
        .shells_len = 1,
    });

    return solid_id;
}
