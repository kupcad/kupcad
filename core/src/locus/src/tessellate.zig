const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

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

/// Exact Point-in-Triangle test used by the Earcut triangulator
fn pointInTriangleExact(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64) bool {
    const c1 = (cx - bx) * (py - by) - (cy - by) * (px - bx);
    const c2 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx);
    const c3 = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    return (c1 >= 0 and c2 >= 0 and c3 >= 0) or (c1 <= 0 and c2 <= 0 and c3 <= 0);
}

/// Robust 2D Polygon Triangulation using a flat-array Earcut approach.
pub fn triangulatePolygon(
    allocator: std.mem.Allocator,
    pts: []const math.Vec2,
    out_triangles: *std.ArrayListUnmanaged([3]u32),
) !void {
    const n = pts.len;
    if (n < 3) return;

    var indices = try allocator.alloc(u32, n);
    defer allocator.free(indices);
    for (0..n) |i| indices[i] = @intCast(i);

    var remaining = n;
    while (remaining > 2) {
        var ear_found = false;

        for (0..remaining) |i| {
            const prev_idx = (i + remaining - 1) % remaining;
            const next_idx = (i + 1) % remaining;

            const i_prev = indices[prev_idx];
            const i_curr = indices[i];
            const i_next = indices[next_idx];

            const a = pts[i_prev];
            const b = pts[i_curr];
            const c = pts[i_next];

            const cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
            if (cross <= 1e-9) continue;

            var is_ear = true;
            for (0..remaining) |j| {
                if (j == prev_idx or j == i or j == next_idx) continue;
                const p = pts[indices[j]];
                if (pointInTriangleExact(p[0], p[1], a[0], a[1], b[0], b[1], c[0], c[1])) {
                    is_ear = false;
                    break;
                }
            }

            if (is_ear) {
                try out_triangles.append(allocator, .{ i_prev, i_curr, i_next });
                std.mem.copyForwards(u32, indices[i .. remaining - 1], indices[i + 1 .. remaining]);
                remaining -= 1;
                ear_found = true;
                break;
            }
        }

        if (!ear_found) {
            for (1..remaining - 1) |i| {
                try out_triangles.append(allocator, .{ indices[0], indices[i], indices[i + 1] });
            }
            break;
        }
    }
}

/// Traverses a Solid's Half-Edge graph and tessellates all of its faces into a 3D Mesh.
pub fn tessellateSolid(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    g_arena: *const geom.GeometryArena,
    solid_id: topo.SolidId,
    out_mesh: *Mesh,
    config: anytype,
) !void {
    _ = config;
    const solid = t_arena.solids.items[solid_id];

    // 1. Copy topological vertices to mesh output
    for (t_arena.vertices.items) |v| {
        try out_mesh.vertices.append(allocator, v.point);
        try out_mesh.normals.append(allocator, .{ 0, 0, 1 }); // Default normal
    }

    // 2. Traverse Shells
    for (0..solid.shells_len) |s_offset| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_offset];
        const shell = t_arena.shells.items[shell_id];

        // 3. Traverse Faces
        for (0..shell.faces_len) |f_offset| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_offset];
            const face = t_arena.faces.items[face_id];
            if (face.loops_len == 0) continue;

            // Extract all loops for the face
            var loops_verts = std.ArrayListUnmanaged([]u32).empty;
            defer {
                for (loops_verts.items) |l| allocator.free(l);
                loops_verts.deinit(allocator);
            }

            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];
                var lv = std.ArrayListUnmanaged(u32).empty;
                var current_he = loop.first_half_edge;
                while (true) {
                    const he = t_arena.half_edges.items[current_he];
                    try lv.append(allocator, he.start_vertex);
                    current_he = he.next;
                    if (current_he == loop.first_half_edge) break;
                }
                try loops_verts.append(allocator, try lv.toOwnedSlice(allocator));
            }

            var face_verts = std.ArrayListUnmanaged(u32).empty;
            defer face_verts.deinit(allocator);

            if (loops_verts.items.len > 0) {
                try face_verts.appendSlice(allocator, loops_verts.items[0]);

                // Stitch holes directly into the outer boundary loop using shortest-bridge algorithm
                for (loops_verts.items[1..]) |hole| {
                    if (hole.len == 0) continue;
                    var min_dist: f64 = std.math.inf(f64);
                    var best_idx: usize = 0;
                    const p_hole = t_arena.vertices.items[hole[0]].point;

                    for (face_verts.items, 0..) |v_out, i| {
                        const p_out = t_arena.vertices.items[v_out].point;
                        const d = math.distSq(p_hole, p_out);
                        if (d < min_dist) {
                            min_dist = d;
                            best_idx = i;
                        }
                    }

                    var new_verts = std.ArrayListUnmanaged(u32).empty;
                    try new_verts.appendSlice(allocator, face_verts.items[0 .. best_idx + 1]);
                    try new_verts.appendSlice(allocator, hole);
                    try new_verts.append(allocator, hole[0]); // Return trip start
                    try new_verts.append(allocator, face_verts.items[best_idx]); // Return trip end
                    if (best_idx + 1 < face_verts.items.len) {
                        try new_verts.appendSlice(allocator, face_verts.items[best_idx + 1 ..]);
                    }

                    face_verts.deinit(allocator);
                    face_verts = new_verts;
                }
            }

            if (face_verts.items.len < 3) continue;

            // 4. Project 3D vertices into 2D UV Space
            var poly2d = try allocator.alloc(math.Vec2, face_verts.items.len);
            defer allocator.free(poly2d);

            for (face_verts.items, 0..) |v_id, i| {
                const pt = t_arena.vertices.items[v_id].point;
                poly2d[i] = g_arena.surfaceProject(face.surface, pt);
            }

            // 5. Triangulate (Flat-Array Ear-Clipping with Triangle Fan Fallback)
            var local_triangles = std.ArrayListUnmanaged([3]u32).empty;
            defer local_triangles.deinit(allocator);

            triangulatePolygon(allocator, poly2d, &local_triangles) catch {};

            if (local_triangles.items.len == 0) {
                var i: usize = 1;
                while (i + 1 < face_verts.items.len) : (i += 1) {
                    try local_triangles.append(allocator, .{ 0, @intCast(i), @intCast(i + 1) });
                }
            }

            // 6. Map local triangle indices to global 3D Vertices
            for (local_triangles.items) |tri| {
                try out_mesh.triangles.append(allocator, .{
                    face_verts.items[tri[0]],
                    face_verts.items[tri[1]],
                    face_verts.items[tri[2]],
                });
            }
        }
    }
}
