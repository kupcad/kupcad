const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

// A Half-Edge data structure optimized purely for Quickhull generation
pub const HalfEdge = struct {
    end_vertex: u32,
    opp_edge: u32 = std.math.maxInt(u32),
    face: u32,
    next_edge: u32,
    disabled: bool = false,
};

pub const HullFace = struct {
    plane_normal: Vec3,
    plane_distance: f64,
    first_half_edge: u32,

    farthest_point: u32 = 0,
    farthest_dist: f64 = 0.0,
    visible: bool = false,
    disabled: bool = false,

    points_outside: std.ArrayListUnmanaged(u32) = .empty,
};

pub const QuickhullBuilder = struct {
    allocator: std.mem.Allocator,
    vertices: []const Vec3,

    half_edges: std.ArrayListUnmanaged(HalfEdge) = .empty,
    faces: std.ArrayListUnmanaged(HullFace) = .empty,

    pub fn init(allocator: std.mem.Allocator, points: []const Vec3) QuickhullBuilder {
        return .{
            .allocator = allocator,
            .vertices = points,
        };
    }

    pub fn deinit(self: *QuickhullBuilder) void {
        for (self.faces.items) |*f| {
            f.points_outside.deinit(self.allocator);
        }
        self.half_edges.deinit(self.allocator);
        self.faces.deinit(self.allocator);
    }

    inline fn distToPlane(normal: Vec3, dist: f64, pt: Vec3) f64 {
        return math.dot(normal, pt) - dist;
    }

    fn addFace(self: *QuickhullBuilder, v0: u32, v1: u32, v2: u32) !u32 {
        const p0 = self.vertices[@as(usize, @intCast(v0))];
        const p1 = self.vertices[@as(usize, @intCast(v1))];
        const p2 = self.vertices[@as(usize, @intCast(v2))];

        var normal = math.normalize(math.cross(math.sub(p1, p0), math.sub(p2, p0)));
        if (math.magSq(normal) < math.MATH_EPSILON) normal = .{ 1, 0, 0 };
        const dist = math.dot(normal, p0);

        const face_idx: u32 = @intCast(self.faces.items.len);
        const he_idx: u32 = @intCast(self.half_edges.items.len);

        try self.half_edges.appendSlice(self.allocator, &[_]HalfEdge{
            .{ .end_vertex = v1, .face = face_idx, .next_edge = he_idx + 1 },
            .{ .end_vertex = v2, .face = face_idx, .next_edge = he_idx + 2 },
            .{ .end_vertex = v0, .face = face_idx, .next_edge = he_idx + 0 },
        });

        try self.faces.append(self.allocator, .{
            .plane_normal = normal,
            .plane_distance = dist,
            .first_half_edge = he_idx,
        });

        return face_idx;
    }

    /// Dynamically rebuilds the twin-edge pointers for the entire active graph.
    /// This saves us from writing highly complex manual stitching logic.
    fn stitchHalfEdges(self: *QuickhullBuilder) !void {
        var map = std.AutoHashMap(u64, u32).init(self.allocator);
        defer map.deinit();

        for (self.half_edges.items, 0..) |*he, i| {
            he.opp_edge = std.math.maxInt(u32); // Reset
            if (self.faces.items[@as(usize, @intCast(he.face))].disabled) continue;

            const next_he = self.half_edges.items[@as(usize, @intCast(he.next_edge))];
            const prev_he = self.half_edges.items[@as(usize, @intCast(next_he.next_edge))];
            const p0 = prev_he.end_vertex;
            const p1 = he.end_vertex;

            // Generate unique keys for edge A->B and its twin B->A
            const key = (@as(u64, p0) << 32) | @as(u64, p1);
            const opp_key = (@as(u64, p1) << 32) | @as(u64, p0);

            if (map.get(opp_key)) |opp_idx| {
                he.opp_edge = opp_idx;
                self.half_edges.items[@as(usize, @intCast(opp_idx))].opp_edge = @intCast(i);
            } else {
                try map.put(key, @intCast(i));
            }
        }
    }

    /// Finds extreme points to form the robust initial tetrahedron
    pub fn buildInitialTetrahedron(self: *QuickhullBuilder) !void {
        if (self.vertices.len < 4) return error.NotEnoughPoints;

        // 1. Find the two points furthest apart on the X axis
        var v0: u32 = 0;
        var v1: u32 = 0;
        var min_x: f64 = std.math.inf(f64);
        var max_x: f64 = -std.math.inf(f64);

        for (self.vertices, 0..) |v, i| {
            if (v[0] < min_x) {
                min_x = v[0];
                v0 = @intCast(i);
            }
            if (v[0] > max_x) {
                max_x = v[0];
                v1 = @intCast(i);
            }
        }

        if (v0 == v1) {
            for (self.vertices, 0..) |_, i| {
                if (i != v0) {
                    v1 = @intCast(i);
                    break;
                }
            }
        }

        // 2. Find v2 furthest from the line v0-v1
        var max_d_line: f64 = -1.0;
        var v2: u32 = v0;
        const p0 = self.vertices[@as(usize, @intCast(v0))];
        const p1 = self.vertices[@as(usize, @intCast(v1))];

        var dir = math.sub(p1, p0);
        const len = math.mag(dir);
        if (len > math.MATH_EPSILON) {
            dir = math.scale(dir, 1.0 / len);
        } else {
            dir = .{ 1, 0, 0 };
        }

        for (self.vertices, 0..) |pt, i| {
            const d_vec = math.sub(pt, p0);
            const proj_len = math.dot(d_vec, dir);
            const proj_vec = math.scale(dir, proj_len);
            const perp_vec = math.sub(d_vec, proj_vec);
            const dist_sq = math.magSq(perp_vec);
            if (dist_sq > max_d_line) {
                max_d_line = dist_sq;
                v2 = @intCast(i);
            }
        }

        // 3. Find v3 furthest from the plane v0-v1-v2
        var max_d_plane: f64 = -1.0;
        var v3: u32 = v0;
        const p2 = self.vertices[@as(usize, @intCast(v2))];
        var normal = math.normalize(math.cross(math.sub(p1, p0), math.sub(p2, p0)));
        if (math.magSq(normal) < math.MATH_EPSILON) normal = .{ 0, 0, 1 };
        const d_plane = math.dot(normal, p0);

        for (self.vertices, 0..) |pt, i| {
            const dist = @abs(distToPlane(normal, d_plane, pt));
            if (dist > max_d_plane) {
                max_d_plane = dist;
                v3 = @intCast(i);
            }
        }

        // 4. Ensure proper winding (if v3 is on the negative side of the plane, swap to point normals outward)
        if (distToPlane(normal, d_plane, self.vertices[@as(usize, @intCast(v3))]) < 0) {
            std.mem.swap(u32, &v1, &v2);
        }

        // 5. Build the 4 outward-facing faces
        _ = try self.addFace(v0, v2, v1);
        _ = try self.addFace(v0, v3, v2);
        _ = try self.addFace(v0, v1, v3);
        _ = try self.addFace(v1, v2, v3);

        // Dynamically wire the initial opposite edges
        try self.stitchHalfEdges();

        // 6. Assign all remaining points to the outside sets
        for (0..self.vertices.len) |i| {
            if (i == v0 or i == v1 or i == v2 or i == v3) continue;
            const pt = self.vertices[i];

            var max_dist: f64 = math.MATH_EPSILON;
            var max_face: ?u32 = null;

            for (self.faces.items, 0..) |face, f_idx| {
                if (face.disabled) continue;
                const dist = distToPlane(face.plane_normal, face.plane_distance, pt);
                if (dist > max_dist) {
                    max_dist = dist;
                    max_face = @intCast(f_idx);
                }
            }

            if (max_face) |f_idx| {
                try self.faces.items[@as(usize, @intCast(f_idx))].points_outside.append(self.allocator, @intCast(i));
                if (max_dist > self.faces.items[@as(usize, @intCast(f_idx))].farthest_dist) {
                    self.faces.items[@as(usize, @intCast(f_idx))].farthest_dist = max_dist;
                    self.faces.items[@as(usize, @intCast(f_idx))].farthest_point = @intCast(i);
                }
            }
        }
    }

    pub fn buildHull(self: *QuickhullBuilder) !void {
        try self.buildInitialTetrahedron();

        var visible_faces: std.ArrayListUnmanaged(u32) = .empty;
        defer visible_faces.deinit(self.allocator);

        var horizon_edges: std.ArrayListUnmanaged(u32) = .empty;
        defer horizon_edges.deinit(self.allocator);

        var unassigned_points: std.ArrayListUnmanaged(u32) = .empty;
        defer unassigned_points.deinit(self.allocator);

        while (true) {
            var target_face: ?u32 = null;
            var max_dist: f64 = -1.0;
            var eye_pt_idx: u32 = 0;

            for (self.faces.items, 0..) |face, i| {
                if (!face.disabled and face.points_outside.items.len > 0 and face.farthest_dist > max_dist) {
                    max_dist = face.farthest_dist;
                    target_face = @intCast(i);
                    eye_pt_idx = face.farthest_point;
                }
            }

            if (target_face == null) break;

            visible_faces.clearRetainingCapacity();
            horizon_edges.clearRetainingCapacity();
            unassigned_points.clearRetainingCapacity();

            const eye_pt = self.vertices[@as(usize, @intCast(eye_pt_idx))];

            var search_queue: std.ArrayListUnmanaged(u32) = .empty;
            defer search_queue.deinit(self.allocator);

            try search_queue.append(self.allocator, target_face.?);
            self.faces.items[@as(usize, @intCast(target_face.?))].visible = true;
            try visible_faces.append(self.allocator, target_face.?);

            // BFS Traversal
            while (search_queue.items.len > 0) {
                const curr_f_u32 = search_queue.items[search_queue.items.len - 1];
                search_queue.shrinkRetainingCapacity(search_queue.items.len - 1);

                const face = self.faces.items[@as(usize, @intCast(curr_f_u32))];

                var he_curr = face.first_half_edge;
                for (0..3) |_| {
                    const he = self.half_edges.items[@as(usize, @intCast(he_curr))];
                    const opp_he_idx = he.opp_edge;

                    if (opp_he_idx != std.math.maxInt(u32)) {
                        const opp_he = self.half_edges.items[@as(usize, @intCast(opp_he_idx))];
                        var opp_face = &self.faces.items[@as(usize, @intCast(opp_he.face))];

                        if (!opp_face.disabled and !opp_face.visible) {
                            if (distToPlane(opp_face.plane_normal, opp_face.plane_distance, eye_pt) > math.MATH_EPSILON) {
                                opp_face.visible = true;
                                try visible_faces.append(self.allocator, opp_he.face);
                                try search_queue.append(self.allocator, opp_he.face);
                            } else {
                                try horizon_edges.append(self.allocator, he_curr);
                            }
                        }
                    }
                    he_curr = he.next_edge;
                }
            }

            for (visible_faces.items) |f_idx| {
                var f = &self.faces.items[@as(usize, @intCast(f_idx))];
                f.disabled = true;
                f.visible = false;
                for (f.points_outside.items) |p_idx| {
                    if (p_idx != eye_pt_idx) {
                        try unassigned_points.append(self.allocator, p_idx);
                    }
                }
                f.points_outside.deinit(self.allocator);
                f.points_outside = .empty;
            }

            for (horizon_edges.items) |he_idx| {
                const he = self.half_edges.items[@as(usize, @intCast(he_idx))];
                const p1_idx = he.end_vertex;
                const next_he = self.half_edges.items[@as(usize, @intCast(he.next_edge))];
                const prev_he = self.half_edges.items[@as(usize, @intCast(next_he.next_edge))];
                const p0_idx = prev_he.end_vertex;

                // FIX: Corrected winding order to p0 -> p1 -> eye so normals point outward
                const new_face_idx = try self.addFace(p0_idx, p1_idx, eye_pt_idx);

                for (unassigned_points.items) |p_idx| {
                    const pt = self.vertices[@as(usize, @intCast(p_idx))];
                    const nf = &self.faces.items[@as(usize, @intCast(new_face_idx))];
                    const dist = distToPlane(nf.plane_normal, nf.plane_distance, pt);

                    if (dist > math.MATH_EPSILON) {
                        try nf.points_outside.append(self.allocator, p_idx);
                        if (dist > nf.farthest_dist) {
                            nf.farthest_dist = dist;
                            nf.farthest_point = p_idx;
                        }
                    }
                }
            }

            // Stitch all the newly added faces back into the BFS graph
            try self.stitchHalfEdges();
        }
    }
};
