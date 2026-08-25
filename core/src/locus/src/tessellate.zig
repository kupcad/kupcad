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

/// 2D Point-in-Polygon check for Ear-Clipping
fn isPointInTriangle2D(p: math.Vec2, a: math.Vec2, b: math.Vec2, c: math.Vec2) bool {
    const ax = c[0] - b[0];
    const ay = c[1] - b[1];
    const bx = a[0] - c[0];
    const by = a[1] - c[1];
    const cx = b[0] - a[0];
    const cy = b[1] - a[1];

    const apx = p[0] - a[0];
    const apy = p[1] - a[1];
    const bpx = p[0] - b[0];
    const bpy = p[1] - b[1];
    const cpx = p[0] - c[0];
    const cpy = p[1] - c[1];

    const aCrossBp = ax * bpy - ay * bpx;
    const cCrossAp = cx * apy - cy * apx;
    const bCrossCp = bx * cpy - by * cpx;

    return (aCrossBp >= 0.0) and (bCrossCp >= 0.0) and (cCrossAp >= 0.0);
}

/// Robust 2D Ear-Clipping Algorithm
pub fn clipEars(
    allocator: std.mem.Allocator,
    polygon: []const math.Vec2,
    out_triangles: *std.ArrayListUnmanaged([3]u32),
) !void {
    const n = polygon.len;
    if (n < 3) return;

    var indices = try allocator.alloc(u32, n);
    defer allocator.free(indices);
    for (0..n) |i| indices[i] = @intCast(i);

    var count = n;
    var curr: usize = 0;

    while (count > 2) {
        var ear_found = false;

        for (0..count) |_| {
            const prev = (curr + count - 1) % count;
            const next = (curr + 1) % count;

            const i_prev = indices[prev];
            const i_curr = indices[curr];
            const i_next = indices[next];

            const a = polygon[i_prev];
            const b = polygon[i_curr];
            const c = polygon[i_next];

            // 1. Check if the vertex is convex (forms a CCW angle)
            const cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);

            if (cross > 1e-9) {
                // 2. Verify no other remaining vertex lies inside this triangle
                var is_empty = true;
                for (0..count) |j| {
                    if (j == prev or j == curr or j == next) continue;
                    const p = polygon[indices[j]];
                    if (isPointInTriangle2D(p, a, b, c)) {
                        is_empty = false;
                        break;
                    }
                }

                if (is_empty) {
                    try out_triangles.append(allocator, .{ i_prev, i_curr, i_next });

                    // Cut the ear out of the array
                    for (curr..count - 1) |k| {
                        indices[k] = indices[k + 1];
                    }
                    count -= 1;
                    ear_found = true;
                    break;
                }
            }

            curr = (curr + 1) % count;
        }

        if (!ear_found) return error.TessellationFailed;
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

            // Extract Outer Boundary (Loop 0)
            const outer_loop_id = t_arena.face_loops.items[face.loops_start];
            const outer_loop = t_arena.loops.items[outer_loop_id];

            var face_verts = std.ArrayListUnmanaged(u32).empty;
            defer face_verts.deinit(allocator);

            // Traverse circular Half-Edge list
            var current_he = outer_loop.first_half_edge;
            while (true) {
                const he = t_arena.half_edges.items[current_he];
                try face_verts.append(allocator, he.start_vertex);

                current_he = he.next;
                if (current_he == outer_loop.first_half_edge) break;
            }

            if (face_verts.items.len < 3) continue;

            // 4. Project 3D vertices into 2D UV Space
            var poly2d = try allocator.alloc(math.Vec2, face_verts.items.len);
            defer allocator.free(poly2d);

            for (face_verts.items, 0..) |v_id, i| {
                const pt = t_arena.vertices.items[v_id].point;
                poly2d[i] = g_arena.surfaceProject(face.surface, pt);
            }

            // 5. Triangulate (Ear-Clipping with Triangle Fan Fallback)
            var local_triangles = std.ArrayListUnmanaged([3]u32).empty;
            defer local_triangles.deinit(allocator);

            clipEars(allocator, poly2d, &local_triangles) catch {};

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
