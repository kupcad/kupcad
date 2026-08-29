const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const generators = @import("generators.zig");
const booleans_2d = @import("booleans_2d.zig");

/// Flattens a 3D Solid into a unified 2D cross-section silhouette projected along the Z-axis.
pub fn projectSolid(
    allocator: std.mem.Allocator,
    out_t_arena: *topo.TopologyArena,
    out_g_arena: *geom.GeometryArena,
    in_t_arena: *const topo.TopologyArena,
    in_g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
) !?topo.SolidId {
    _ = in_g_arena;
    var combined_2d: ?topo.SolidId = null;
    const s = in_t_arena.solids.items[solid_id];

    for (0..s.shells_len) |s_off| {
        const shell = in_t_arena.shells.items[in_t_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = in_t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = in_t_arena.faces.items[face_id];
            if (face.loops_len == 0) continue;

            const loop = in_t_arena.loops.items[in_t_arena.face_loops.items[face.loops_start]];
            var pts2d = std.ArrayListUnmanaged([2]f64).empty;
            defer pts2d.deinit(allocator);

            var curr_he = loop.first_half_edge;
            while (true) {
                const he = in_t_arena.half_edges.items[curr_he];
                const pt = in_t_arena.vertices.items[he.start_vertex].point;
                try pts2d.append(allocator, .{ pt[0], pt[1] });
                curr_he = he.next;
                if (curr_he == loop.first_half_edge) break;
            }

            if (pts2d.items.len < 3) continue;

            // Calculate exact 2D footprint area (signed)
            var area: f64 = 0;
            for (0..pts2d.items.len) |i| {
                const p1 = pts2d.items[i];
                const p2 = pts2d.items[(i + 1) % pts2d.items.len];
                area += (p1[0] * p2[1] - p2[0] * p1[1]);
            }

            // If it's a vertical wall, its projection area is 0; discard it.
            if (@abs(area) < 1e-4) continue;

            // Force strict CCW winding for 2D boolean safety
            if (area < 0.0) {
                std.mem.reverse([2]f64, pts2d.items);
            }

            const face_cs_id = try generators.generatePolygon(allocator, out_t_arena, out_g_arena, pts2d.items);

            if (combined_2d == null) {
                combined_2d = face_cs_id;
            } else {
                const new_combined = try booleans_2d.crossSectionBoolean(allocator, out_t_arena, out_g_arena, combined_2d.?, face_cs_id, .union_op);
                combined_2d = new_combined;
            }
        }
    }
    return combined_2d;
}
