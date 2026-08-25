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

    // Quickhull state
    farthest_point: u32 = 0,
    farthest_dist: f64 = 0.0,
    visible: bool = false,
    disabled: bool = false,

    // Indices of points outside this face
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

    /// Computes the signed distance from a point to a plane.
    inline fn distToPlane(normal: Vec3, dist: f64, pt: Vec3) f64 {
        return math.dot(normal, pt) - dist;
    }

    /// Creates a new face and its 3 half-edges. Does NOT stitch twin half-edges.
    fn addFace(self: *QuickhullBuilder, v0: u32, v1: u32, v2: u32) !u32 {
        const p0 = self.vertices[@as(usize, @intCast(v0))];
        const p1 = self.vertices[@as(usize, @intCast(v1))];
        const p2 = self.vertices[@as(usize, @intCast(v2))];

        // Compute plane normal and distance
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

    /// Links two half edges together as opposites
    fn linkOpposites(self: *QuickhullBuilder, h1: u32, h2: u32) void {
        self.half_edges.items[@as(usize, @intCast(h1))].opp_edge = h2;
        self.half_edges.items[@as(usize, @intCast(h2))].opp_edge = h1;
    }

    /// Finds extreme points to form the initial tetrahedron
    pub fn buildInitialTetrahedron(self: *QuickhullBuilder) !void {
        if (self.vertices.len < 4) return error.NotEnoughPoints;

        var extrema = [_]u32{0} ** 6;
        var vals = [_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64) };

        for (self.vertices, 0..) |v, i| {
            const idx: u32 = @intCast(i);
            if (v[0] < vals[0]) {
                vals[0] = v[0];
                extrema[0] = idx;
            }
            if (v[0] > vals[1]) {
                vals[1] = v[0];
                extrema[1] = idx;
            }
            if (v[1] < vals[2]) {
                vals[2] = v[1];
                extrema[2] = idx;
            }
            if (v[1] > vals[3]) {
                vals[3] = v[1];
                extrema[3] = idx;
            }
            if (v[2] < vals[4]) {
                vals[4] = v[2];
                extrema[4] = idx;
            }
            if (v[2] > vals[5]) {
                vals[5] = v[2];
                extrema[5] = idx;
            }
        }

        const v0: u32 = 0;
        const v1: u32 = 1;
        const v2: u32 = 2;
        const v3: u32 = 3;

        // Corrected winding orders so all normals point OUTWARD
        _ = try self.addFace(v0, v2, v1); // F0: Bottom (XY plane, normal -Z)
        _ = try self.addFace(v0, v3, v2); // F1: Back (YZ plane, normal -X)
        _ = try self.addFace(v0, v1, v3); // F2: Left (XZ plane, normal -Y)
        _ = try self.addFace(v1, v2, v3); // F3: Slanted (normal +X, +Y, +Z)

        // Mapped the new opposite half-edges mathematically
        self.linkOpposites(0, 5); // v0->v2 opposite v2->v0
        self.linkOpposites(1, 9); // v2->v1 opposite v1->v2
        self.linkOpposites(2, 6); // v1->v0 opposite v0->v1
        self.linkOpposites(3, 8); // v0->v3 opposite v3->v0
        self.linkOpposites(4, 10); // v3->v2 opposite v2->v3
        self.linkOpposites(7, 11); // v1->v3 opposite v3->v1

        for (0..self.vertices.len) |i| {
            if (i == v0 or i == v1 or i == v2 or i == v3) continue;
            // ... (keep the rest of the function the same)
            const pt = self.vertices[i];

            var max_dist: f64 = math.MATH_EPSILON;
            var max_face: ?u32 = null;

            for (self.faces.items, 0..) |face, f_idx| {
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

    /// The core Quickhull generation loop with BFS Horizon Expansion
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

            while (search_queue.items.len > 0) {
                // Safely fetch and shrink bypassing pop() variations
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

                const new_face_idx = try self.addFace(p1_idx, p0_idx, eye_pt_idx);

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
        }
    }
};
