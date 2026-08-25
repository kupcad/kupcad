const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const qh = @import("quickhull.zig");

pub const MinkowskiError = error{
    OutOfMemory,
    DegenerateInput,
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
    var verts_a = try extractSolidVertices(allocator, t_arena, solid_a);
    defer verts_a.deinit(allocator);

    var verts_b = try extractSolidVertices(allocator, t_arena, solid_b);
    defer verts_b.deinit(allocator);

    // 2. Compute the Minkowski Point Cloud (Pairwise Sum)
    var point_cloud: std.ArrayListUnmanaged(math.Vec3) = .empty;
    defer point_cloud.deinit(allocator);

    try point_cloud.ensureTotalCapacity(allocator, verts_a.items.len * verts_b.items.len);

    for (verts_a.items) |va| {
        for (verts_b.items) |vb| {
            try point_cloud.append(allocator, math.add(va, vb));
        }
    }

    // 3. Feed the point cloud into Quickhull
    var builder = qh.QuickhullBuilder.init(allocator, point_cloud.items);
    defer builder.deinit();

    // Compute the convex hull (populates builder.faces and builder.half_edges)
    // try builder.buildHull();

    // 4. Convert Quickhull output back into B-Rep Topology
    const solid_id: u32 = @intCast(t_arena.solids.items.len);

    // Every Quickhull face becomes a Plane surface + topological Face.
    for (builder.faces.items) |hull_face| {
        if (hull_face.disabled) continue;

        const surf_id: u24 = @intCast(g_arena.planes.items.len);
        try g_arena.planes.append(allocator, .{
            .origin = point_cloud.items[builder.half_edges.items[hull_face.first_half_edge].end_vertex],
            .u_axis = .{ 1, 0, 0 },
            .v_axis = .{ 0, 1, 0 },
        });

        try t_arena.faces.append(t_arena.allocator, .{
            .surface = .{ .index = surf_id, .surface_type = .plane }, // Use packed struct ID
            .forward = true,
            .wires_start = 0,
            .wires_len = 1,
        });
    }

    return solid_id;
}

/// Helper to gather all unique vertex coordinates from a solid.
fn extractSolidVertices(allocator: std.mem.Allocator, t_arena: *topo.TopologyArena, solid_id: topo.SolidId) !std.ArrayList(math.Vec3) {
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

            for (0..face.wires_len) |w_offset| {
                const wire_id = t_arena.face_wires.items[face.wires_start + w_offset];
                const wire = t_arena.wires.items[wire_id];

                for (0..wire.edges_len) |e_offset| {
                    const d_edge = t_arena.wire_edges.items[wire.edges_start + e_offset];
                    const edge = t_arena.edges.items[d_edge.edge];

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
