const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const FaceData = struct {
    index: topo.FaceId,
    normal: math.Vec3,
    centroid: math.Vec3,
};

/// Queries a solid for all faces pointing within a given tolerance of a target direction.
pub fn queryFaces(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
    direction: math.Vec3,
    tolerance: f64,
) !?[]FaceData {
    const s = t_arena.solids.items[solid_id];
    const norm_dir = math.normalize(direction);

    var max_depth: f64 = -std.math.inf(f64);
    var accum_centroid = math.Vec3{ 0, 0, 0 };
    var match_count: usize = 0;

    for (0..s.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[s.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_off];
            const face = t_arena.faces.items[face_id];

            if (face.surface.surface_type != .plane) continue;
            const plane = g_arena.planes.items[face.surface.index];

            var normal = math.normalize(math.cross(plane.u_axis, plane.v_axis));
            if (!face.forward) normal = math.scale(normal, -1.0);

            const alignment = math.dot(normal, norm_dir);
            if (1.0 - alignment <= tolerance) {
                var centroid = math.Vec3{ 0, 0, 0 };
                var v_count: f64 = 0;

                const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];
                var curr_he = loop.first_half_edge;
                while (true) {
                    const pt = t_arena.vertices.items[t_arena.half_edges.items[curr_he].start_vertex].point;
                    centroid[0] += pt[0];
                    centroid[1] += pt[1];
                    centroid[2] += pt[2];
                    v_count += 1.0;
                    curr_he = t_arena.half_edges.items[curr_he].next;
                    if (curr_he == loop.first_half_edge) break;
                }

                if (v_count > 0) {
                    centroid[0] /= v_count;
                    centroid[1] /= v_count;
                    centroid[2] /= v_count;
                }

                const depth = math.dot(centroid, norm_dir);
                if (depth > max_depth + tolerance) {
                    max_depth = depth;
                    accum_centroid = centroid;
                    match_count = 1;
                } else if (@abs(depth - max_depth) <= tolerance) {
                    accum_centroid[0] += centroid[0];
                    accum_centroid[1] += centroid[1];
                    accum_centroid[2] += centroid[2];
                    match_count += 1;
                }
            }
        }
    }

    if (match_count == 0) return null;

    var faces = try allocator.alloc(FaceData, 1);
    faces[0] = .{
        .index = 0,
        .normal = norm_dir,
        .centroid = .{
            accum_centroid[0] / @as(f64, @floatFromInt(match_count)),
            accum_centroid[1] / @as(f64, @floatFromInt(match_count)),
            accum_centroid[2] / @as(f64, @floatFromInt(match_count)),
        },
    };
    return faces;
}
