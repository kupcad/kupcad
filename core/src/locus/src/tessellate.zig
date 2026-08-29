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

const Node = struct {
    i: u32,
    x: f64,
    y: f64,
    prev: *Node,
    next: *Node,
};

fn pointInTriangle(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64, cx: f64, cy: f64) bool {
    const c1 = (cx - bx) * (py - by) - (cy - by) * (px - bx);
    const c2 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx);
    const c3 = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    return (c1 >= 0 and c2 >= 0 and c3 >= 0) or (c1 <= 0 and c2 <= 0 and c3 <= 0);
}

fn isEar(node: *const Node) bool {
    const a = node.prev;
    const b = node;
    const c = node.next;

    // Must be convex (CCW orientation)
    const cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (cross <= 1e-9) return false;

    // Check if any other remaining node lies inside triangle ABC
    var p = c.next;
    while (p != a) {
        if (pointInTriangle(p.x, p.y, a.x, a.y, b.x, b.y, c.x, c.y)) return false;
        p = p.next;
    }
    return true;
}

/// Robust 2D Polygon Triangulation using doubly-linked reflex/convex node ear-clipping
pub fn triangulatePolygon(
    allocator: std.mem.Allocator,
    pts: []const math.Vec2,
    out_triangles: *std.ArrayListUnmanaged([3]u32),
) !void {
    const n = pts.len;
    if (n < 3) return;

    // Allocate continuous arena memory for linked list nodes
    var nodes = try allocator.alloc(Node, n);
    defer allocator.free(nodes);

    for (0..n) |i| {
        nodes[i] = .{
            .i = @intCast(i),
            .x = pts[i][0],
            .y = pts[i][1],
            .prev = undefined,
            .next = undefined,
        };
    }

    // Link circular doubly-linked list
    for (0..n) |i| {
        nodes[i].prev = &nodes[(i + n - 1) % n];
        nodes[i].next = &nodes[(i + 1) % n];
    }

    var head: *Node = &nodes[0];
    var stop_node: *Node = head;
    var remaining = n;

    while (remaining > 2) {
        var ear_found = false;
        var curr: *Node = head;

        while (true) {
            if (isEar(curr)) {
                // Emit triangle
                try out_triangles.append(allocator, .{ curr.prev.i, curr.i, curr.next.i });

                // Unlink current ear node from circular list
                curr.prev.next = curr.next;
                curr.next.prev = curr.prev;

                head = curr.next;
                stop_node = head;
                remaining -= 1;
                ear_found = true;
                break;
            }

            curr = curr.next;
            if (curr == stop_node) break;
        }

        // Fallback for self-intersecting or complex polygons: triangle fan
        if (!ear_found) {
            var curr_fan = head.next;
            while (curr_fan.next != head) {
                try out_triangles.append(allocator, .{ head.i, curr_fan.i, curr_fan.next.i });
                curr_fan = curr_fan.next;
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

            // 5. Triangulate (Doubly-Linked Ear-Clipping with Triangle Fan Fallback)
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
