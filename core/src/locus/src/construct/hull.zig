//! The convex hull of points (quickhull, as the first model had it: an initial tetrahedron
//! from extreme points, then each face's farthest outside point added, the visible faces
//! removed and the horizon joined to it), and the hull as a body: a face for each plane of
//! its triangles as the interner keeps them, over the points its faces use. Flat-faced
//! solids only: a curved solid's hull from its vertices is not its hull (the driver refuses
//! it, `curved_hull`).

const std = @import("std");
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("primitives.zig");
const sew = @import("sew.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const canonical = @import("../geometry/canonical.zig");
const types = @import("../topology/types.zig");
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

/// The convex hull of `points` as a solid, every decision of sameness the interner's (D28:
/// decided once): the points welded to its point records (the hull of those), each of
/// quickhull's triangles given its plane record and sense, the triangles of one record and
/// sense one face, bounded by their group's boundary (no fans: a group may be merged across a
/// crease within the zone and so not convex), and a boundary point between two of the
/// hull's faces on the line of its neighbours there, within the tolerance, dropped from
/// both (a point quickhull kept on an edge of the hull). The hull's own coplanarity test
/// grouped a flat tetrahedron's upper faces, 1.5e-5 apart at their far corners, as one,
/// while the interner gave them two records: its fans did not sew (2026-11-14). Fewer than
/// four points, or all of them within the zone of one plane, is `error.Degenerate`.
pub fn hull(allocator: std.mem.Allocator, tol: Tolerance, points: []const Vec3, diag: *Diagnostics) Error!Body {
    try diagnostics.input.nonEmpty(diag, "points", points.len);
    for (points) |p| for (p) |c| try diagnostics.input.finite(diag, "a point", c);
    var b = try primitives.Builder.init(allocator, tol, .solid, diag);
    defer b.deinit();
    errdefer b.body.deinit();
    // A hull thinner than the intersection tolerance somewhere (its points between the zone
    // and the tolerance of one plane: faces their own records, lying on each other) is
    // refused as any made solid is (`Builder.finish`, `overlap.refuseMade`)
    b.made = "faces of the hull, within its features nearer than the minimum feature size,";

    // The points as the interner keeps them, one record each
    var records: std.ArrayList(geometry.PointIndex) = .empty;
    defer records.deinit(allocator);
    var kept: std.ArrayList(Vec3) = .empty;
    defer kept.deinit(allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(allocator);
    for (points) |p| {
        const r = try b.point(p);
        if ((try seen.getOrPut(allocator, @backingInt(r))).found_existing) continue;
        try records.append(allocator, r);
        try kept.append(allocator, b.body.geometry.points.items[@backingInt(r)]);
    }
    var qh = Quickhull.init(allocator, kept.items);
    defer qh.deinit();
    qh.build() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Degenerate => return flat(diag, points.len),
    };
    const tris = try qh.triangles(allocator);
    defer allocator.free(tris);

    // Each triangle's plane record and sense: its group
    var groups: std.AutoArrayHashMapUnmanaged(Group, void) = .empty;
    defer groups.deinit(allocator);
    const group_of = try allocator.alloc(u32, tris.len);
    defer allocator.free(group_of);
    for (tris, group_of, 0..) |t, *g, i| {
        const p0 = kept.items[t[0]];
        const p1 = kept.items[t[1]];
        const p2 = kept.items[t[2]];
        const n = vec.normalized(vec.cross(vec.sub(p1, p0), vec.sub(p2, p0))) orelse return diag.fail(error.Degenerate, .{ .code = .face_without_loop, .label = "a flat triangle of the hull", .measured = @floatFromInt(i) });
        const x = vec.normalized(vec.sub(p1, p0)).?;
        const facing = try b.facingPlane(geometry.Frame.init(p0, x, n), &.{ p0, p1, p2 });
        const entry = try groups.getOrPut(allocator, .{ .plane = facing.surface.index, .same_sense = facing.same_sense });
        g.* = @intCast(entry.index);
    }
    // All within the zone of one plane: no solid
    var one_plane = true;
    for (groups.keys()) |key| one_plane = one_plane and key.plane == groups.keys()[0].plane;
    if (one_plane) return flat(diag, points.len);

    // Each group's boundary: its triangles' sides whose reverse is not in it
    var sides: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
    defer sides.deinit(allocator);
    for (tris, group_of) |t, g| for (0..3) |k| try sides.put(allocator, .{ t[k], t[(k + 1) % 3] }, g);
    var boundary: std.ArrayList(Side) = .empty;
    defer boundary.deinit(allocator);
    for (tris, group_of) |t, g| for (0..3) |k| {
        const a = t[k];
        const c = t[(k + 1) % 3];
        if (sides.get(.{ c, a })) |other| if (other == g) continue;
        try boundary.append(allocator, .{ .from = a, .to = c, .group = g });
    };
    const drop = try straightThrough(allocator, &b, kept.items, boundary.items, diag);
    defer allocator.free(drop);

    // Each group's cycles, the dropped points passed over, as faces
    const vertex_of = try allocator.alloc(types.VertexIndex, kept.items.len);
    defer allocator.free(vertex_of);
    @memset(vertex_of, .none);
    var specs: std.ArrayList(sew.FaceSpec) = .empty;
    defer specs.deinit(allocator);
    var loop_specs: std.ArrayList(sew.LoopSpec) = .empty;
    defer loop_specs.deinit(allocator);
    var edge_specs: std.ArrayList(sew.EdgeSpec) = .empty;
    defer edge_specs.deinit(allocator);
    // The faces' loops as ranges of `edge_specs`, set once it no longer grows
    var loop_ranges: std.ArrayList([2]u32) = .empty;
    defer loop_ranges.deinit(allocator);
    var face_loops: std.ArrayList([2]u32) = .empty;
    defer face_loops.deinit(allocator);
    var next: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer next.deinit(allocator);
    var cycle: std.ArrayList(u32) = .empty;
    defer cycle.deinit(allocator);
    var cycles: std.ArrayList([2]u32) = .empty;
    defer cycles.deinit(allocator);
    var points_of: std.ArrayList(u32) = .empty;
    defer points_of.deinit(allocator);
    for (groups.keys(), 0..) |key, g| {
        // The group's boundary as a successor map; a point with two successors is a group
        // touching itself, no face
        next.clearRetainingCapacity();
        for (boundary.items) |s| {
            if (s.group != g) continue;
            if ((try next.getOrPut(allocator, s.from)).found_existing) return diag.fail(error.Degenerate, .{ .code = .singular_vertex, .label = "a face of the hull touching itself" });
            next.putAssumeCapacity(s.from, s.to);
        }
        // Its cycles, from the lowest point not yet used, without the dropped points
        cycles.clearRetainingCapacity();
        points_of.clearRetainingCapacity();
        var starts: std.ArrayList(u32) = .empty;
        defer starts.deinit(allocator);
        var it = next.keyIterator();
        while (it.next()) |k| try starts.append(allocator, k.*);
        std.mem.sort(u32, starts.items, {}, std.sort.asc(u32));
        for (starts.items) |start| {
            if (drop[start] or next.get(start) == null) continue;
            cycle.clearRetainingCapacity();
            var v = start;
            const most = next.count();
            var steps: usize = 0;
            while (steps <= most) : (steps += 1) {
                if (!drop[v]) try cycle.append(allocator, v);
                const w = next.fetchRemove(v) orelse break;
                v = w.value;
                if (v == start) break;
            }
            if (v != start or cycle.items.len < 3) return diag.fail(error.Degenerate, .{ .code = .loop_not_closed, .label = "a face of the hull" });
            try cycles.append(allocator, .{ @intCast(points_of.items.len), @intCast(cycle.items.len) });
            try points_of.appendSlice(allocator, cycle.items);
        }
        // The outer cycle first: the one of the largest area about the face's outward normal
        const plane = b.body.geometry.planes.items[key.plane];
        const outward = if (key.same_sense) plane.frame.z else vec.neg(plane.frame.z);
        var outer: usize = 0;
        var largest = -std.math.inf(f64);
        for (cycles.items, 0..) |range, ci| {
            const area = vectorArea(kept.items, points_of.items[range[0]..][0..range[1]], outward);
            if (area > largest) {
                largest = area;
                outer = ci;
            }
        }
        std.mem.swap([2]u32, &cycles.items[0], &cycles.items[outer]);
        const first_loop: u32 = @intCast(loop_ranges.items.len);
        for (cycles.items) |range| {
            const ring = points_of.items[range[0]..][0..range[1]];
            const first_edge: u32 = @intCast(edge_specs.items.len);
            for (ring, 0..) |a, i| {
                const c = ring[(i + 1) % ring.len];
                for ([_]u32{ a, c }) |q| {
                    if (vertex_of[q] == .none) vertex_of[q] = try b.vertexAt(records.items[q]);
                }
                try edge_specs.append(allocator, try b.straight(vertex_of[a], vertex_of[c]));
            }
            try loop_ranges.append(allocator, .{ first_edge, @intCast(ring.len) });
        }
        try face_loops.append(allocator, .{ first_loop, @intCast(cycles.items.len) });
        var uv = geometry.Box2.empty;
        for (points_of.items) |q| {
            const l = plane.frame.toLocal(kept.items[q]);
            uv.grow(.{ l[0], l[1] });
        }
        try specs.append(allocator, .{ .surface = geometry.SurfaceRef.of(.plane, key.plane), .same_sense = key.same_sense, .loops = &.{}, .uv_box = uv });
    }
    for (loop_ranges.items) |range| try loop_specs.append(allocator, .{ .edges = edge_specs.items[range[0]..][0..range[1]] });
    for (specs.items, face_loops.items) |*spec, range| spec.loops = loop_specs.items[range[0]..][0..range[1]];
    return b.finish(specs.items, .outer);
}

/// A face of the hull: the plane record its triangles were given, and their sense on it.
const Group = struct { plane: u32, same_sense: bool };

/// A side of a group's boundary, from point `from` to `to` (indices of the welded points),
/// the way the group's triangles run it.
const Side = struct { from: u32, to: u32, group: u32 };

/// Which points lie on a straight run of the hull's boundary, to be dropped from both of
/// its faces: a point on exactly two boundary sides, one into it and one out of it in each
/// face it bounds, whose neighbours there and it lie on one line within the tolerance (the
/// interner's rule for lines, `canonical.sameLine`; at it to rounding, refused, D27).
fn straightThrough(allocator: std.mem.Allocator, b: *primitives.Builder, kept: []const Vec3, boundary: []const Side, diag: *Diagnostics) Error![]bool {
    const drop = try allocator.alloc(bool, kept.len);
    errdefer allocator.free(drop);
    @memset(drop, false);
    // Each point's neighbours along the boundary, either way
    var neighbours: std.AutoHashMapUnmanaged(u32, [3]u32) = .empty;
    defer neighbours.deinit(allocator);
    for (boundary) |s| for ([_][2]u32{ .{ s.from, s.to }, .{ s.to, s.from } }) |pair| {
        const entry = try neighbours.getOrPut(allocator, pair[0]);
        if (!entry.found_existing) entry.value_ptr.* = .{ NONE, NONE, NONE };
        const list = entry.value_ptr;
        if (list[0] == pair[1] or list[1] == pair[1]) continue;
        if (list[0] == NONE) list[0] = pair[1] else if (list[1] == NONE) list[1] = pair[1] else list[2] = pair[1];
    };
    var it = neighbours.iterator();
    while (it.next()) |entry| {
        const list = entry.value_ptr.*;
        if (list[1] == NONE or list[2] != NONE) continue;
        const p = kept[entry.key_ptr.*];
        const a = kept[list[0]];
        const c = kept[list[1]];
        const line = curves.Line.through(a, c) orelse continue;
        const item = curves.Line.through(a, p) orelse continue;
        switch (canonical.verdict(&canonical.sameLine(line, item, a, a, p, b.body.tol))) {
            .same => drop[entry.key_ptr.*] = true,
            .apart => {},
            .at_tolerance => |cmp| return diag.fail(error.Degenerate, .{ .code = .at_tolerance, .label = "a point of the hull on the line of its neighbours or not, the tolerance to rounding", .measured = cmp.measured, .threshold = cmp.limit }),
        }
    }
    return drop;
}

/// The area of the polygon `ring` (indices of `points`) about `normal`, from its first corner.
fn vectorArea(points: []const Vec3, ring: []const u32, normal: Vec3) f64 {
    var twice = vec.ZERO3;
    const from = points[ring[0]];
    for (ring[1 .. ring.len - 1], ring[2..]) |p, q| twice = vec.add(twice, vec.cross(vec.sub(points[p], from), vec.sub(points[q], from)));
    return vec.dot(twice, normal) / 2;
}

fn flat(diag: *Diagnostics, count: usize) Error {
    return diag.fail(error.Degenerate, .{ .code = .empty_input, .label = "the hull: fewer than four points off one plane", .measured = @floatFromInt(count) });
}
