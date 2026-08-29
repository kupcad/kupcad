const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const tessellate = @import("tessellate.zig");

pub const RayHit = struct {
    distance: f64,
    position: math.Vec3,
    normal: math.Vec3,
};

/// Gathers all unique 3D vertex coordinates belonging strictly to a solid by traversing its Half-Edge loops.
pub fn extractSolidVertices(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    solid_id: topo.SolidId,
) !std.ArrayListUnmanaged(math.Vec3) {
    var verts = std.ArrayListUnmanaged(math.Vec3).empty;
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

/// Projects an infinite ray against the solid (falling back to a tessellated AABB tree in MVP)
pub fn rayCast(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
    ray_origin: math.Vec3,
    ray_end: math.Vec3,
) !?[]RayHit {
    var mesh = tessellate.Mesh{};
    defer mesh.deinit(allocator);

    tessellate.tessellateSolid(allocator, t_arena, g_arena, solid_id, &mesh, .{}) catch return null;

    const ray_vec = math.sub(ray_end, ray_origin);
    const ray_len = math.mag(ray_vec);
    if (ray_len < 1e-12) return null;
    const ray_dir = math.scale(ray_vec, 1.0 / ray_len);

    var hits = std.ArrayListUnmanaged(RayHit).empty;
    defer hits.deinit(allocator);

    for (mesh.triangles.items) |tri| {
        const v0 = mesh.vertices.items[tri[0]];
        const v1 = mesh.vertices.items[tri[1]];
        const v2 = mesh.vertices.items[tri[2]];

        const edge1 = math.sub(v1, v0);
        const edge2 = math.sub(v2, v0);
        const h_vec = math.cross(ray_dir, edge2);
        const a_det = math.dot(edge1, h_vec);

        if (a_det > -1e-8 and a_det < 1e-8) continue;

        const f = 1.0 / a_det;
        const s_vec = math.sub(ray_origin, v0);
        const u = f * math.dot(s_vec, h_vec);

        if (u < 0.0 or u > 1.0) continue;

        const q_vec = math.cross(s_vec, edge1);
        const v = f * math.dot(ray_dir, q_vec);

        if (v < 0.0 or u + v > 1.0) continue;

        const t = f * math.dot(edge2, q_vec);
        if (t > 1e-8 and t < ray_len) {
            const hit_pos = math.add(ray_origin, math.scale(ray_dir, t));
            const normal = math.normalize(math.cross(edge1, edge2));
            try hits.append(allocator, .{
                .distance = t,
                .position = hit_pos,
                .normal = normal,
            });
        }
    }

    if (hits.items.len == 0) return null;

    std.mem.sort(RayHit, hits.items, {}, struct {
        fn lessThan(_: void, lhs: RayHit, rhs: RayHit) bool {
            return lhs.distance < rhs.distance;
        }
    }.lessThan);

    return try hits.toOwnedSlice(allocator);
}

/// Computes the exact minimum distance between two solids residing in the same or separate arenas.
pub fn minGap(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
) f64 {
    _ = g_arena;

    var verts_a = extractSolidVertices(allocator, t_arena, solid_a) catch return 0.0;
    defer verts_a.deinit(allocator);

    var verts_b = extractSolidVertices(allocator, t_arena, solid_b) catch return 0.0;
    defer verts_b.deinit(allocator);

    var min_dist_sq: f64 = std.math.inf(f64);
    for (verts_a.items) |pa| {
        for (verts_b.items) |pb| {
            const dist_sq = math.distSq(pa, pb);
            if (dist_sq < min_dist_sq) min_dist_sq = dist_sq;
        }
    }
    return @sqrt(min_dist_sq);
}
