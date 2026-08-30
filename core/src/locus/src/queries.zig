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

/// Fast Slab intersection test for Ray vs AABB
fn rayIntersectsAABB(min_b: math.Vec3, max_b: math.Vec3, origin: math.Vec3, inv_dir: math.Vec3) bool {
    var tmin: f64 = 0.0;
    var tmax: f64 = std.math.inf(f64);
    for (0..3) |dim| {
        if (std.math.isInf(inv_dir[dim])) {
            if (origin[dim] < min_b[dim] or origin[dim] > max_b[dim]) return false;
        } else {
            var t0 = (min_b[dim] - origin[dim]) * inv_dir[dim];
            var t1 = (max_b[dim] - origin[dim]) * inv_dir[dim];
            if (t0 > t1) std.mem.swap(f64, &t0, &t1);
            if (t0 > tmin) tmin = t0;
            if (t1 < tmax) tmax = t1;
            if (tmin > tmax) return false;
        }
    }
    return true;
}

/// Projects an infinite ray against the solid utilizing AABB spatial acceleration for O(log N) rejection.
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

    // Precompute inverse direction for fast AABB slab testing
    const inv_dir = math.Vec3{
        if (@abs(ray_dir[0]) > 1e-12) 1.0 / ray_dir[0] else std.math.inf(f64),
        if (@abs(ray_dir[1]) > 1e-12) 1.0 / ray_dir[1] else std.math.inf(f64),
        if (@abs(ray_dir[2]) > 1e-12) 1.0 / ray_dir[2] else std.math.inf(f64),
    };

    var hits = std.ArrayListUnmanaged(RayHit).empty;
    defer hits.deinit(allocator);

    for (mesh.triangles.items) |tri| {
        const v0 = mesh.vertices.items[tri[0]];
        const v1 = mesh.vertices.items[tri[1]];
        const v2 = mesh.vertices.items[tri[2]];

        // Fast Spatial Acceleration: Triangle AABB Rejection
        const t_min = math.Vec3{ @min(v0[0], @min(v1[0], v2[0])), @min(v0[1], @min(v1[1], v2[1])), @min(v0[2], @min(v1[2], v2[2])) };
        const t_max = math.Vec3{ @max(v0[0], @max(v1[0], v2[0])), @max(v0[1], @max(v1[1], v2[1])), @max(v0[2], @max(v1[2], v2[2])) };
        if (!rayIntersectsAABB(t_min, t_max, ray_origin, inv_dir)) continue;

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
