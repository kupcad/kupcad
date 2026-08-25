const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("../../geometry_handle.zig");
const driver = @import("driver.zig");

/// Converts a Native B-Rep Solid into a triangulated Mesh for STL/GLTF export.
pub fn tessellateSolid(allocator: std.mem.Allocator, solid: *const driver.BrepSolid) !geom.Mesh {
    const b = &solid.brep;

    // 1. Extract vertices (x, y, z floats)
    var vert_props = try allocator.alloc(f32, b.vertices.items.len * 3);
    for (b.vertices.items, 0..) |v, i| {
        vert_props[i * 3 + 0] = @floatCast(v.point.x);
        vert_props[i * 3 + 1] = @floatCast(v.point.y);
        vert_props[i * 3 + 2] = @floatCast(v.point.z);
    }

    var tri_verts = std.ArrayListUnmanaged(u32).empty;
    defer tri_verts.deinit(allocator);

    // 2. Simple Triangle Fan for each face
    for (b.faces.items) |face| {
        const wire = b.wires.items[face.outer_wire];
        if (wire.num_edges < 3) continue;

        // Extract the ordered vertices of the wire
        var face_verts = try allocator.alloc(u32, wire.num_edges);
        defer allocator.free(face_verts);

        for (0..wire.num_edges) |i| {
            const e_idx = b.wire_edges.items[wire.first_edge + i];
            const edge = b.edges.items[e_idx];

            // For this MVP, we assume the generator writes edges in forward order
            face_verts[i] = edge.start_vertex;
        }

        // Fan triangulation: (0, 1, 2), (0, 2, 3), (0, 3, 4), etc.
        var i: usize = 1;
        while (i + 1 < face_verts.len) : (i += 1) {
            try tri_verts.appendSlice(allocator, &[_]u32{
                face_verts[0],
                face_verts[i],
                face_verts[i + 1],
            });
        }
    }

    return geom.Mesh{
        .vert_props = vert_props,
        .tri_verts = try tri_verts.toOwnedSlice(allocator),
        .num_prop = 3, // x, y, z
    };
}
