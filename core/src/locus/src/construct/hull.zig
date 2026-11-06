//! The convex hull of points (quickhull, as the first model had it: an initial tetrahedron
//! from extreme points, then each face's farthest outside point added, the visible faces
//! removed and the horizon joined to it), and the hull as a body: a polyhedron over the
//! points its faces use. Flat-faced solids only: a curved solid's hull from its vertices is
//! not its hull (the driver refuses it, `curved_hull`).

const std = @import("std");
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("primitives.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// How far outside a face a point must be to count as outside it, relative to the point
/// set's extent (within it, a point is on the face: the hull is sewn through such points).
const OUTSIDE: f64 = 1e-12;

const NONE: u32 = std.math.maxInt(u32);

const HalfEdge = struct {
    end: u32,
    opposite: u32 = NONE,
    face: u32,
    next: u32,
};

const Face = struct {
    normal: Vec3,
    distance: f64,
    first: u32,
    farthest_point: u32 = 0,
    farthest_dist: f64 = 0,
    visible: bool = false,
    disabled: bool = false,
    outside: std.ArrayList(u32) = .empty,
};

pub const Quickhull = struct {
    allocator: std.mem.Allocator,
    points: []const Vec3,
    half_edges: std.ArrayList(HalfEdge) = .empty,
    faces: std.ArrayList(Face) = .empty,
    /// The least distance that counts as outside a face.
    epsilon: f64,

    pub fn init(allocator: std.mem.Allocator, points: []const Vec3) Quickhull {
        var extent: f64 = 0;
        for (points) |p| extent = @max(extent, @max(@abs(p[0]), @max(@abs(p[1]), @abs(p[2]))));
        return .{ .allocator = allocator, .points = points, .epsilon = @max(extent, 1.0) * OUTSIDE };
    }

    pub fn deinit(self: *Quickhull) void {
        for (self.faces.items) |*f| f.outside.deinit(self.allocator);
        self.half_edges.deinit(self.allocator);
        self.faces.deinit(self.allocator);
    }

    fn height(normal: Vec3, distance: f64, p: Vec3) f64 {
        return vec.dot(normal, p) - distance;
    }

    fn addFace(self: *Quickhull, v0: u32, v1: u32, v2: u32) error{OutOfMemory}!u32 {
        const p0 = self.points[v0];
        const p1 = self.points[v1];
        const p2 = self.points[v2];
        const normal = vec.normalized(vec.cross(vec.sub(p1, p0), vec.sub(p2, p0))) orelse vec.X3;
        const face_index: u32 = @intCast(self.faces.items.len);
        const he: u32 = @intCast(self.half_edges.items.len);
        try self.half_edges.appendSlice(self.allocator, &.{
            .{ .end = v1, .face = face_index, .next = he + 1 },
            .{ .end = v2, .face = face_index, .next = he + 2 },
            .{ .end = v0, .face = face_index, .next = he },
        });
        try self.faces.append(self.allocator, .{ .normal = normal, .distance = vec.dot(normal, p0), .first = he });
        return face_index;
    }

    /// Pairs every live half-edge with its opposite by its vertices.
    fn stitch(self: *Quickhull) error{OutOfMemory}!void {
        var map = std.AutoHashMapUnmanaged(u64, u32).empty;
        defer map.deinit(self.allocator);
        for (self.half_edges.items, 0..) |*he, i| {
            he.opposite = NONE;
            if (self.faces.items[he.face].disabled) continue;
            const next = self.half_edges.items[he.next];
            const prev = self.half_edges.items[next.next];
            const a = prev.end;
            const b = he.end;
            const opposite_key = (@as(u64, b) << 32) | a;
            if (map.get(opposite_key)) |o| {
                he.opposite = o;
                self.half_edges.items[o].opposite = @intCast(i);
            } else {
                try map.put(self.allocator, (@as(u64, a) << 32) | b, @intCast(i));
            }
        }
    }

    fn assignOutside(self: *Quickhull, face: u32, point: u32) error{OutOfMemory}!void {
        const f = &self.faces.items[face];
        const d = height(f.normal, f.distance, self.points[point]);
        if (d <= self.epsilon) return;
        try f.outside.append(self.allocator, point);
        if (d > f.farthest_dist) {
            f.farthest_dist = d;
            f.farthest_point = point;
        }
    }

    /// The initial tetrahedron from the extreme points: the two farthest apart along x,
    /// the farthest from their line, the farthest from their plane.
    fn initialTetrahedron(self: *Quickhull) error{ OutOfMemory, Degenerate }!void {
        const pts = self.points;
        if (pts.len < 4) return error.Degenerate;
        var v0: u32 = 0;
        var v1: u32 = 0;
        for (pts, 0..) |p, i| {
            if (p[0] < pts[v0][0]) v0 = @intCast(i);
            if (p[0] > pts[v1][0]) v1 = @intCast(i);
        }
        if (v0 == v1) v1 = if (v0 == 0) 1 else 0;
        const dir = vec.normalized(vec.sub(pts[v1], pts[v0])) orelse return error.Degenerate;
        var v2: u32 = v0;
        var best: f64 = -1;
        for (pts, 0..) |p, i| {
            const d = vec.sub(p, pts[v0]);
            const off = vec.lengthSq(vec.sub(d, vec.scale(dir, vec.dot(d, dir))));
            if (off > best) {
                best = off;
                v2 = @intCast(i);
            }
        }
        const normal = vec.normalized(vec.cross(vec.sub(pts[v1], pts[v0]), vec.sub(pts[v2], pts[v0]))) orelse return error.Degenerate;
        const distance = vec.dot(normal, pts[v0]);
        var v3: u32 = v0;
        best = -1;
        for (pts, 0..) |p, i| {
            const d = @abs(height(normal, distance, p));
            if (d > best) {
                best = d;
                v3 = @intCast(i);
            }
        }
        if (best <= self.epsilon) return error.Degenerate; // all coplanar
        if (height(normal, distance, pts[v3]) < 0) std.mem.swap(u32, &v1, &v2);
        _ = try self.addFace(v0, v2, v1);
        _ = try self.addFace(v0, v3, v2);
        _ = try self.addFace(v0, v1, v3);
        _ = try self.addFace(v1, v2, v3);
        try self.stitch();
        for (0..pts.len) |i| {
            if (i == v0 or i == v1 or i == v2 or i == v3) continue;
            // To the face it is farthest outside of
            var far: ?u32 = null;
            var far_d: f64 = self.epsilon;
            for (self.faces.items, 0..) |f, fi| {
                const d = height(f.normal, f.distance, pts[i]);
                if (d > far_d) {
                    far_d = d;
                    far = @intCast(fi);
                }
            }
            if (far) |f| try self.assignOutside(f, @intCast(i));
        }
    }

    pub fn build(self: *Quickhull) error{ OutOfMemory, Degenerate }!void {
        try self.initialTetrahedron();
        var visible = std.ArrayList(u32).empty;
        defer visible.deinit(self.allocator);
        var horizon = std.ArrayList(u32).empty;
        defer horizon.deinit(self.allocator);
        var unassigned = std.ArrayList(u32).empty;
        defer unassigned.deinit(self.allocator);
        var queue = std.ArrayList(u32).empty;
        defer queue.deinit(self.allocator);
        // Each round adds one point and removes at least one face: bounded by the points
        var rounds: usize = 0;
        while (rounds <= self.points.len) : (rounds += 1) {
            // The face with the farthest outside point, by index for determinism
            var target: ?u32 = null;
            var far: f64 = -1;
            for (self.faces.items, 0..) |f, i| {
                if (!f.disabled and f.outside.items.len > 0 and f.farthest_dist > far) {
                    far = f.farthest_dist;
                    target = @intCast(i);
                }
            }
            const start = target orelse return;
            const eye = self.faces.items[start].farthest_point;
            const eye_pt = self.points[eye];
            visible.clearRetainingCapacity();
            horizon.clearRetainingCapacity();
            unassigned.clearRetainingCapacity();
            queue.clearRetainingCapacity();
            try queue.append(self.allocator, start);
            self.faces.items[start].visible = true;
            try visible.append(self.allocator, start);
            while (queue.pop()) |fi| {
                const f = self.faces.items[fi];
                var he = f.first;
                for (0..3) |_| {
                    const edge = self.half_edges.items[he];
                    if (edge.opposite != NONE) {
                        const other = self.half_edges.items[edge.opposite].face;
                        const of = &self.faces.items[other];
                        if (!of.disabled and !of.visible) {
                            if (height(of.normal, of.distance, eye_pt) > self.epsilon) {
                                of.visible = true;
                                try visible.append(self.allocator, other);
                                try queue.append(self.allocator, other);
                            } else {
                                try horizon.append(self.allocator, he);
                            }
                        }
                    }
                    he = edge.next;
                }
            }
            for (visible.items) |fi| {
                const f = &self.faces.items[fi];
                f.disabled = true;
                f.visible = false;
                for (f.outside.items) |p| if (p != eye) try unassigned.append(self.allocator, p);
                f.outside.clearRetainingCapacity();
            }
            for (horizon.items) |he| {
                const edge = self.half_edges.items[he];
                const next = self.half_edges.items[edge.next];
                const prev = self.half_edges.items[next.next];
                const new_face = try self.addFace(prev.end, edge.end, eye);
                for (unassigned.items) |p| try self.assignOutside(new_face, p);
            }
            try self.stitch();
        }
    }

    /// The hull's triangles, corners counter-clockwise seen from outside.
    pub fn triangles(self: *const Quickhull, allocator: std.mem.Allocator) error{OutOfMemory}![][3]u32 {
        var out = std.ArrayList([3]u32).empty;
        errdefer out.deinit(allocator);
        for (self.faces.items) |f| {
            if (f.disabled) continue;
            const e0 = self.half_edges.items[f.first];
            const e1 = self.half_edges.items[e0.next];
            const e2 = self.half_edges.items[e1.next];
            try out.append(allocator, .{ e2.end, e0.end, e1.end });
        }
        return out.toOwnedSlice(allocator);
    }
};

/// How parallel two triangles' normals must be, as `1 − cos`, to lie on one face of the
/// hull, and how close their planes.
const COPLANAR_ANGLE: f64 = 1e-9;

/// The hull's faces as convex polygons, corners counter-clockwise seen from outside: the
/// triangles grouped by plane, each group's boundary chained, and the points on the
/// boundary's edges (collinear with their neighbours) dropped. Quickhull keeps a point
/// that lies on a face or an edge of the final hull whenever it was outside an earlier
/// face, depending on the points' order; the polygons do not.
pub fn facets(allocator: std.mem.Allocator, points: []const Vec3, tris: []const [3]u32, epsilon: f64) error{OutOfMemory}![][]u32 {
    const Plane = struct { normal: Vec3, distance: f64, first: usize };
    var planes = std.ArrayList(Plane).empty;
    defer planes.deinit(allocator);
    const group_of = try allocator.alloc(usize, tris.len);
    defer allocator.free(group_of);
    for (tris, 0..) |t, i| {
        const n = vec.normalized(vec.cross(vec.sub(points[t[1]], points[t[0]]), vec.sub(points[t[2]], points[t[0]]))) orelse vec.X3;
        const d = vec.dot(n, points[t[0]]);
        group_of[i] = planes.items.len;
        for (planes.items, 0..) |pl, g| {
            if (1.0 - vec.dot(pl.normal, n) <= COPLANAR_ANGLE and @abs(pl.distance - d) <= epsilon) {
                group_of[i] = g;
                break;
            }
        }
        if (group_of[i] == planes.items.len) try planes.append(allocator, .{ .normal = n, .distance = d, .first = i });
    }
    var out = std.ArrayList([]u32).empty;
    errdefer {
        for (out.items) |f| allocator.free(f);
        out.deinit(allocator);
    }
    var successor = std.AutoHashMapUnmanaged(u32, u32).empty;
    defer successor.deinit(allocator);
    var reversed = std.AutoHashMapUnmanaged(u64, void).empty;
    defer reversed.deinit(allocator);
    var loop = std.ArrayList(u32).empty;
    defer loop.deinit(allocator);
    for (planes.items, 0..) |_, g| {
        // The group's boundary: its directed edges whose reverse is not in the group
        successor.clearRetainingCapacity();
        reversed.clearRetainingCapacity();
        for (tris, group_of) |t, tg| {
            if (tg != g) continue;
            for (0..3) |k| try reversed.put(allocator, key(t[(k + 1) % 3], t[k]), {});
        }
        var start: u32 = std.math.maxInt(u32);
        for (tris, group_of) |t, tg| {
            if (tg != g) continue;
            for (0..3) |k| {
                const a = t[k];
                const b = t[(k + 1) % 3];
                if (reversed.contains(key(a, b))) continue;
                try successor.put(allocator, a, b);
                start = @min(start, a);
            }
        }
        if (start == std.math.maxInt(u32)) continue;
        loop.clearRetainingCapacity();
        var v = start;
        var steps: usize = 0;
        while (steps <= successor.count()) : (steps += 1) {
            try loop.append(allocator, v);
            v = successor.get(v) orelse break;
            if (v == start) break;
        }
        // Drop the points collinear with their neighbours
        var corners = std.ArrayList(u32).empty;
        errdefer corners.deinit(allocator);
        for (loop.items, 0..) |c, i| {
            const prev = points[loop.items[(i + loop.items.len - 1) % loop.items.len]];
            const next = points[loop.items[(i + 1) % loop.items.len]];
            const turn = vec.length(vec.cross(vec.sub(points[c], prev), vec.sub(next, points[c])));
            if (turn > epsilon * (vec.distance(points[c], prev) + vec.distance(next, points[c]))) try corners.append(allocator, c);
        }
        if (corners.items.len < 3) {
            corners.deinit(allocator);
            continue;
        }
        try out.ensureUnusedCapacity(allocator, 1);
        out.appendAssumeCapacity(try corners.toOwnedSlice(allocator));
    }
    return out.toOwnedSlice(allocator);
}

fn key(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | b;
}

/// The convex hull of `points` as a solid: a polyhedron over the points its faces use, in
/// their order of first use, each face fanned from its first corner. Fewer than four
/// points, or all of them coplanar, is `error.Degenerate`.
pub fn hull(allocator: std.mem.Allocator, tol: Tolerance, points: []const Vec3, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "points", points.len);
    for (points) |p| for (p) |c| try diagnostics.input.finite(diag, "a point", c);
    var qh = Quickhull.init(allocator, points);
    defer qh.deinit();
    qh.build() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Degenerate => return diag.fail(error.Degenerate, .{ .code = .empty_input, .label = "the hull: fewer than four points off one plane", .measured = @floatFromInt(points.len) }),
    };
    const raw = try qh.triangles(allocator);
    defer allocator.free(raw);
    const polygons = try facets(allocator, points, raw, qh.epsilon);
    defer {
        for (polygons) |f| allocator.free(f);
        allocator.free(polygons);
    }
    var fans = std.ArrayList([3]u32).empty;
    defer fans.deinit(allocator);
    for (polygons) |poly| {
        for (1..poly.len - 1) |k| try fans.append(allocator, .{ poly[0], poly[k], poly[k + 1] });
    }
    const tris = fans.items;
    // Only the points the faces use, renumbered
    const corner_of = try allocator.alloc(u32, points.len);
    defer allocator.free(corner_of);
    @memset(corner_of, NONE);
    var corners = std.ArrayList(Vec3).empty;
    defer corners.deinit(allocator);
    for (tris) |*t| {
        for (t) |*c| {
            if (corner_of[c.*] == NONE) {
                corner_of[c.*] = @intCast(corners.items.len);
                try corners.append(allocator, points[c.*]);
            }
            c.* = corner_of[c.*];
        }
    }
    return primitives.polyhedron(allocator, tol, corners.items, tris, diag);
}
