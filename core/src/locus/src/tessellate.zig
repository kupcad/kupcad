const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");
const eigen = @import("eigen.zig");

pub const Mesh = struct {
    vertices: std.ArrayListUnmanaged(math.Vec3) = .empty,
    normals: std.ArrayListUnmanaged(math.Vec3) = .empty,
    triangles: std.ArrayListUnmanaged([3]u32) = .empty,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.normals.deinit(allocator);
        self.triangles.deinit(allocator);
    }
};

const Edge = struct { v1: u32, v2: u32 };

fn isBoundaryEdge(u: u32, v: u32, loops_indices: []const []u32) bool {
    for (loops_indices) |loop| {
        for (0..loop.len) |i| {
            const a = loop[i];
            const b = loop[(i + 1) % loop.len];
            if ((u == a and v == b) or (u == b and v == a)) return true;
        }
    }
    return false;
}

/// Recovers lost physical boundary edges by mathematically flipping intersecting diagonals.
fn recoverBoundaries(pts: []const math.Vec2, loops_indices: []const []u32, tris: *std.ArrayListUnmanaged([3]u32)) void {
    for (loops_indices) |loop| {
        for (0..loop.len) |i| {
            const u = loop[i];
            const v = loop[(i + 1) % loop.len];
            if (u == v) continue;

            var edge_exists = false;
            var edge_iters: usize = 0;

            // Strictly bound iterations to prevent infinite flip-flops on degenerate geometry
            while (!edge_exists and edge_iters < 100) : (edge_iters += 1) {
                edge_exists = false;
                for (tris.items) |t| {
                    if ((t[0] == u and t[1] == v) or (t[1] == u and t[0] == v) or
                        (t[1] == u and t[2] == v) or (t[2] == u and t[1] == v) or
                        (t[2] == u and t[0] == v) or (t[0] == u and t[2] == v))
                    {
                        edge_exists = true;
                        break;
                    }
                }
                if (edge_exists) break;

                var flipped = false;
                for (0..tris.items.len) |t1_idx| {
                    for (t1_idx + 1..tris.items.len) |t2_idx| {
                        const t1 = tris.items[t1_idx];
                        const t2 = tris.items[t2_idx];

                        var shared: [2]u32 = undefined;
                        var s_count: usize = 0;
                        var p1: u32 = std.math.maxInt(u32);
                        for (0..3) |k| {
                            const v1 = t1[k];
                            var is_shared = false;
                            for (0..3) |l| {
                                if (v1 == t2[l]) {
                                    if (s_count < 2) shared[s_count] = v1;
                                    s_count += 1;
                                    is_shared = true;
                                    break;
                                }
                            }
                            if (!is_shared) p1 = v1;
                        }

                        if (s_count != 2) continue;

                        var p2: u32 = std.math.maxInt(u32);
                        for (0..3) |l| {
                            const v2 = t2[l];
                            if (v2 != shared[0] and v2 != shared[1]) {
                                p2 = v2;
                                break;
                            }
                        }

                        const a = pts[shared[0]];
                        const b = pts[shared[1]];
                        const c = pts[u];
                        const d = pts[v];

                        const o1 = eigen.orient2D(a, b, c);
                        const o2 = eigen.orient2D(a, b, d);
                        const o3 = eigen.orient2D(c, d, a);
                        const o4 = eigen.orient2D(c, d, b);

                        // Strict intersection check
                        if (o1 * o2 < -1e-9 and o3 * o4 < -1e-9) {
                            // Ensure the quad is strictly convex before flipping to prevent overlaps
                            const c1 = eigen.orient2D(pts[p1], pts[p2], pts[shared[0]]);
                            const c2 = eigen.orient2D(pts[p1], pts[p2], pts[shared[1]]);
                            if (c1 * c2 < -1e-9) {
                                var new_t1 = [3]u32{ p1, p2, shared[0] };
                                if (eigen.orient2D(pts[new_t1[0]], pts[new_t1[1]], pts[new_t1[2]]) <= 0.0) {
                                    new_t1 = [3]u32{ p1, shared[0], p2 };
                                }
                                var new_t2 = [3]u32{ p1, p2, shared[1] };
                                if (eigen.orient2D(pts[new_t2[0]], pts[new_t2[1]], pts[new_t2[2]]) <= 0.0) {
                                    new_t2 = [3]u32{ p1, shared[1], p2 };
                                }
                                tris.items[t1_idx] = new_t1;
                                tris.items[t2_idx] = new_t2;
                                flipped = true;
                                break;
                            }
                        }
                    }
                    if (flipped) break;
                }
                if (!flipped) break; // No flippable edge found, avoid infinite loop
            }
        }
    }
}

pub fn optimizeDelaunay(pts: []const math.Vec2, loops_indices: []const []u32, triangles: []([3]u32)) void {
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) { // Bounded to 2 passes for O(1) time
        var flipped = false;
        for (0..triangles.len) |i| {
            for (i + 1..triangles.len) |j| {
                const t1 = triangles[i];
                const t2 = triangles[j];

                var shared: [2]u32 = undefined;
                var s_count: usize = 0;
                var p1: u32 = std.math.maxInt(u32);
                for (0..3) |k| {
                    const v1 = t1[k];
                    var is_shared = false;
                    for (0..3) |l| {
                        if (v1 == t2[l]) {
                            if (s_count < 2) shared[s_count] = v1;
                            s_count += 1;
                            is_shared = true;
                            break;
                        }
                    }
                    if (!is_shared) p1 = v1;
                }

                if (s_count != 2) continue;
                if (isBoundaryEdge(shared[0], shared[1], loops_indices)) continue; // Protect walls

                var p2: u32 = std.math.maxInt(u32);
                for (0..3) |l| {
                    const v2 = t2[l];
                    if (v2 != shared[0] and v2 != shared[1]) {
                        p2 = v2;
                        break;
                    }
                }

                const vA = shared[0];
                const vB = shared[1];

                const o1 = eigen.orient2D(pts[p1], pts[p2], pts[vA]);
                const o2 = eigen.orient2D(pts[p1], pts[p2], pts[vB]);
                if (o1 * o2 >= 0.0) continue;

                if (eigen.inCircle(pts[t1[0]], pts[t1[1]], pts[t1[2]], pts[p2]) > 1e-9) {
                    var new_t1 = [3]u32{ p1, p2, vA };
                    if (eigen.orient2D(pts[new_t1[0]], pts[new_t1[1]], pts[new_t1[2]]) <= 0.0) {
                        new_t1 = [3]u32{ p1, vA, p2 };
                    }
                    var new_t2 = [3]u32{ p1, p2, vB };
                    if (eigen.orient2D(pts[new_t2[0]], pts[new_t2[1]], pts[new_t2[2]]) <= 0.0) {
                        new_t2 = [3]u32{ p1, vB, p2 };
                    }
                    triangles[i] = new_t1;
                    triangles[j] = new_t2;
                    flipped = true;
                }
            }
        }
        if (!flipped) break;
    }
}

pub fn delaunayTriangulate(
    allocator: std.mem.Allocator,
    pts: *std.ArrayListUnmanaged(math.Vec2),
    out_triangles: *std.ArrayListUnmanaged([3]u32),
) !void {
    if (pts.items.len < 3) return;

    var min_b = math.Vec2{ std.math.inf(f64), std.math.inf(f64) };
    var max_b = math.Vec2{ -std.math.inf(f64), -std.math.inf(f64) };
    for (pts.items) |p| {
        min_b[0] = @min(min_b[0], p[0]);
        min_b[1] = @min(min_b[1], p[1]);
        max_b[0] = @max(max_b[0], p[0]);
        max_b[1] = @max(max_b[1], p[1]);
    }
    const dx = max_b[0] - min_b[0];
    const dy = max_b[1] - min_b[1];
    const delta_max = @max(dx, dy) * 100.0 + 10.0;
    const mid_x = (min_b[0] + max_b[0]) / 2.0;
    const mid_y = (min_b[1] + max_b[1]) / 2.0;

    const original_len = pts.items.len;

    const st_v1 = @as(u32, @intCast(pts.items.len));
    try pts.append(allocator, .{ mid_x - delta_max, mid_y - delta_max });
    const st_v2 = @as(u32, @intCast(pts.items.len));
    try pts.append(allocator, .{ mid_x + delta_max, mid_y - delta_max });
    const st_v3 = @as(u32, @intCast(pts.items.len));
    try pts.append(allocator, .{ mid_x, mid_y + delta_max });

    try out_triangles.append(allocator, .{ st_v1, st_v2, st_v3 });

    var bad_triangles = std.ArrayListUnmanaged(usize).empty;
    defer bad_triangles.deinit(allocator);
    var polygon = std.ArrayListUnmanaged(Edge).empty;
    defer polygon.deinit(allocator);

    for (0..original_len) |p_idx| {
        const pt = pts.items[p_idx];
        bad_triangles.clearRetainingCapacity();
        polygon.clearRetainingCapacity();

        for (out_triangles.items, 0..) |tri, t_idx| {
            const a = pts.items[tri[0]];
            const b = pts.items[tri[1]];
            const c = pts.items[tri[2]];
            if (eigen.inCircle(a, b, c, pt) > 1e-9) {
                try bad_triangles.append(allocator, t_idx);
            }
        }

        for (bad_triangles.items) |t_idx| {
            const tri = out_triangles.items[t_idx];
            const edges = [_]Edge{
                .{ .v1 = tri[0], .v2 = tri[1] },
                .{ .v1 = tri[1], .v2 = tri[2] },
                .{ .v1 = tri[2], .v2 = tri[0] },
            };

            for (edges) |edge| {
                var is_shared = false;
                for (bad_triangles.items) |other_t_idx| {
                    if (t_idx == other_t_idx) continue;
                    const otri = out_triangles.items[other_t_idx];
                    const oedges = [_]Edge{
                        .{ .v1 = otri[0], .v2 = otri[1] },
                        .{ .v1 = otri[1], .v2 = otri[2] },
                        .{ .v1 = otri[2], .v2 = otri[0] },
                    };
                    for (oedges) |oe| {
                        if ((edge.v1 == oe.v1 and edge.v2 == oe.v2) or
                            (edge.v1 == oe.v2 and edge.v2 == oe.v1))
                        {
                            is_shared = true;
                            break;
                        }
                    }
                    if (is_shared) break;
                }
                if (!is_shared) try polygon.append(allocator, edge);
            }
        }

        var i: usize = out_triangles.items.len;
        while (i > 0) {
            i -= 1;
            var is_bad = false;
            for (bad_triangles.items) |b_idx| {
                if (i == b_idx) {
                    is_bad = true;
                    break;
                }
            }
            if (is_bad) _ = out_triangles.swapRemove(i);
        }

        const p_u32 = @as(u32, @intCast(p_idx));
        for (polygon.items) |edge| {
            const a = pts.items[edge.v1];
            const b = pts.items[edge.v2];
            const o = eigen.orient2D(a, b, pt);

            if (o > 1e-9) {
                try out_triangles.append(allocator, .{ edge.v1, edge.v2, p_u32 });
            } else if (o < -1e-9) {
                try out_triangles.append(allocator, .{ edge.v2, edge.v1, p_u32 });
            } else {
                // Fallback for perfectly collinear insertions
                try out_triangles.append(allocator, .{ edge.v1, edge.v2, p_u32 });
            }
        }
    }
}

pub fn tessellateSolid(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
    out_mesh: *Mesh,
    config: anytype,
) !void {
    _ = g_arena;
    _ = config;

    const solid = t_arena.solids.items[solid_id];

    for (t_arena.vertices.items) |v| {
        try out_mesh.vertices.append(allocator, v.point);
        try out_mesh.normals.append(allocator, .{ 0, 0, 1 });
    }

    for (0..solid.shells_len) |s_offset| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_offset];
        const shell = t_arena.shells.items[shell_id];

        for (0..shell.faces_len) |f_offset| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_offset];
            const face = t_arena.faces.items[face_id];
            if (face.loops_len == 0) continue;

            var loops_verts = std.ArrayListUnmanaged([]u32).empty;
            defer {
                for (loops_verts.items) |l| allocator.free(l);
                loops_verts.deinit(allocator);
            }

            var face_verts = std.ArrayListUnmanaged(u32).empty;
            defer face_verts.deinit(allocator);

            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];
                var lv = std.ArrayListUnmanaged(u32).empty;
                var current_he = loop.first_half_edge;
                while (true) {
                    const he = t_arena.half_edges.items[current_he];
                    try lv.append(allocator, he.start_vertex);
                    try face_verts.append(allocator, he.start_vertex);
                    current_he = he.next;
                    if (current_he == loop.first_half_edge) break;
                }
                try loops_verts.append(allocator, try lv.toOwnedSlice(allocator));
            }

            if (face_verts.items.len < 3) continue;

            // Newell's Method Projection
            var loop_nx: f64 = 0;
            var loop_ny: f64 = 0;
            var loop_nz: f64 = 0;
            const outer_loop = loops_verts.items[0];
            for (0..outer_loop.len) |i| {
                const p1 = t_arena.vertices.items[outer_loop[i]].point;
                const p2 = t_arena.vertices.items[outer_loop[(i + 1) % outer_loop.len]].point;
                loop_nx += (p1[1] - p2[1]) * (p1[2] + p2[2]);
                loop_ny += (p1[2] - p2[2]) * (p1[0] + p2[0]);
                loop_nz += (p1[0] - p2[0]) * (p1[1] + p2[1]);
            }

            const mag2 = loop_nx * loop_nx + loop_ny * loop_ny + loop_nz * loop_nz;
            var normal = math.Vec3{ 0, 0, 1 };

            if (mag2 > 1e-12) {
                const inv = 1.0 / @sqrt(mag2);
                normal = .{ loop_nx * inv, loop_ny * inv, loop_nz * inv };
            } else {
                var pts_3d = try allocator.alloc(math.Vec3, outer_loop.len);
                defer allocator.free(pts_3d);
                for (outer_loop, 0..) |v_id, i| pts_3d[i] = t_arena.vertices.items[v_id].point;
                normal = eigen.pcaNormal(pts_3d);
            }

            var u_axis = math.Vec3{ 1, 0, 0 };
            if (@abs(normal[0]) > 0.9) u_axis = .{ 0, 1, 0 };
            const v_axis = math.normalize(math.cross(normal, u_axis));
            u_axis = math.normalize(math.cross(v_axis, normal));

            // Deduplication Engine (Filters coincident points from Boolean seams)
            var unique_pts = std.ArrayListUnmanaged(math.Vec2).empty;
            defer unique_pts.deinit(allocator);
            var unique_to_global = std.ArrayListUnmanaged(u32).empty;
            defer unique_to_global.deinit(allocator);

            var loops_indices = std.ArrayListUnmanaged([]u32).empty;
            defer {
                for (loops_indices.items) |l| allocator.free(l);
                loops_indices.deinit(allocator);
            }

            const origin = t_arena.vertices.items[outer_loop[0]].point;

            for (loops_verts.items) |loop| {
                var l_idx = try allocator.alloc(u32, loop.len);
                for (loop, 0..) |v_id, i| {
                    const pt = t_arena.vertices.items[v_id].point;
                    const vec = math.sub(pt, origin);
                    const p2d = math.Vec2{ math.dot(vec, u_axis), math.dot(vec, v_axis) };

                    var found: ?u32 = null;
                    for (unique_pts.items, 0..) |up, j| {
                        const dx = p2d[0] - up[0];
                        const dy = p2d[1] - up[1];
                        if ((dx * dx + dy * dy) < 1e-10) {
                            found = @intCast(j);
                            break;
                        }
                    }

                    if (found) |idx| {
                        l_idx[i] = idx;
                    } else {
                        l_idx[i] = @intCast(unique_pts.items.len);
                        try unique_pts.append(allocator, p2d);
                        try unique_to_global.append(allocator, v_id);
                    }
                }
                try loops_indices.append(allocator, l_idx);
            }

            const num_original_pts = unique_pts.items.len;

            var local_triangles = std.ArrayListUnmanaged([3]u32).empty;
            defer local_triangles.deinit(allocator);

            try delaunayTriangulate(allocator, &unique_pts, &local_triangles);
            recoverBoundaries(unique_pts.items, loops_indices.items, &local_triangles);
            optimizeDelaunay(unique_pts.items, loops_indices.items, local_triangles.items);

            // 1. Calculate 2D projection parity to guarantee outward 3D normals
            var area2d: f64 = 0.0;
            const outer_idx = loops_indices.items[0];
            for (0..outer_idx.len) |i| {
                const p1 = unique_pts.items[outer_idx[i]];
                const p2 = unique_pts.items[outer_idx[(i + 1) % outer_idx.len]];
                area2d += (p1[0] * p2[1] - p2[0] * p1[1]);
            }
            // If area < 0, the 2D plane is upside-down relative to the 3D half-edges.
            const needs_flip = area2d < 0.0;

            // 2. Winding Rule Filter
            var boundaries2d = std.ArrayListUnmanaged([]math.Vec2).empty;
            defer {
                for (boundaries2d.items) |b| allocator.free(b);
                boundaries2d.deinit(allocator);
            }

            for (loops_indices.items) |l_idx| {
                var b2d = try allocator.alloc(math.Vec2, l_idx.len);
                for (l_idx, 0..) |idx, k| b2d[k] = unique_pts.items[idx];
                try boundaries2d.append(allocator, b2d);
            }

            for (local_triangles.items) |tri| {
                if (tri[0] >= num_original_pts or tri[1] >= num_original_pts or tri[2] >= num_original_pts) continue;

                const p0 = unique_pts.items[tri[0]];
                const p1 = unique_pts.items[tri[1]];
                const p2 = unique_pts.items[tri[2]];

                const centroid = math.Vec2{
                    (p0[0] + p1[0] + p2[0]) / 3.0,
                    (p0[1] + p1[1] + p2[1]) / 3.0,
                };

                var winding: i32 = 0;
                for (boundaries2d.items) |boundary| {
                    var j: usize = boundary.len - 1;
                    for (0..boundary.len) |i| {
                        const pi = boundary[i];
                        const pj = boundary[j];
                        if (pj[1] <= centroid[1]) {
                            if (pi[1] > centroid[1]) {
                                if (eigen.orient2D(pj, pi, centroid) > 0.0) winding += 1;
                            }
                        } else {
                            if (pi[1] <= centroid[1]) {
                                if (eigen.orient2D(pj, pi, centroid) < 0.0) winding -= 1;
                            }
                        }
                        j = i;
                    }
                }

                // Use Even-Odd rule to correctly cull holes regardless of CW/CCW contour winding
                if (@abs(winding) % 2 != 0) {
                    if (!needs_flip) {
                        try out_mesh.triangles.append(allocator, .{
                            unique_to_global.items[tri[0]],
                            unique_to_global.items[tri[1]],
                            unique_to_global.items[tri[2]],
                        });
                    } else {
                        try out_mesh.triangles.append(allocator, .{
                            unique_to_global.items[tri[0]],
                            unique_to_global.items[tri[2]],
                            unique_to_global.items[tri[1]],
                        });
                    }
                }
            }
        }
    }
}
