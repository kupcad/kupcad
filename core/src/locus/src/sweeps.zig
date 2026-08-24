const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const SweepError = error{
    OutOfMemory,
    InvalidTopology,
};

/// Extrudes a flat 2D face along a 3D vector to create a Solid.
/// Based on truck's ExtrudedCurve and rsweep algorithms.
pub fn extrudeFace(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    base_face_id: topo.FaceId,
    vector: math.Vec3,
) SweepError!topo.SolidId {
    const base_face = t_arena.faces.items[base_face_id];

    // 1. Collect all vertices of the base face
    // (In a full implementation, we'd iterate over the face's wires -> edges -> vertices)
    // For this blueprint, assume we have a helper that extracts the vertex IDs:
    // const base_vertices = try getFaceVertices(t_arena, base_face_id);

    // 2. Duplicate vertices shifted by `vector` for the top cap
    // for (base_vertices) |v_id| {
    //     const base_pt = t_arena.vertices.items[v_id].point;
    //     try t_arena.vertices.append(.{ .point = math.add(base_pt, vector) });
    // }

    // 3. For each edge in the base face, create an Extruded surface
    // for (base_edges) |e_id| {
    //     const edge = t_arena.edges.items[e_id];
    //
    //     // Create the geometric surface of extrusion
    //     const surf_id = g_arena.surfaces.items.len;
    //     try g_arena.surfaces.append(.{
    //         .extrusion = .{
    //             .curve = &g_arena.curves.items[edge.curve_idx],
    //             .vector = vector,
    //         }
    //     });
    //
    //     // Build the topological face (side wall) connecting the base edge to the top edge
    //     // (Creates 2 vertical edges + 1 top edge, wraps them in a Wire and Face)
    // }

    // 4. Create the Top Cap (a translated copy of the base face)
    // 5. Wrap the Base Face (inverted), Top Cap, and Side Faces into a Shell, then a Solid.

    // Placeholder return
    return 0;
}

/// Revolves a flat 2D face around an axis to create a Solid.
/// Based on truck's RevolutedCurve.
pub fn revolveFace(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    base_face_id: topo.FaceId,
    origin: math.Vec3,
    axis: math.Vec3,
    angle: f64,
) SweepError!topo.SolidId {
    _ = base_face_id;
    _ = origin;
    _ = axis;
    _ = angle;
    // Similar to extrude, but we append `.revolution` surfaces to the GeometryArena
    // and apply rotation matrices to the duplicated top-cap vertices.
    return 0;
}
