//! The boolean's first phase (docs/architecture.md §7.4 steps 0–2, KNOWLEDGE §7; OCCT's
//! `BOPAlgo_PaveFiller`): every place two planar solids touch, found once, in order of
//! dimension, before any face is split. Its tables are the next phase's input:
//!
//! - the merged vertices: both operands' vertices, a vertex of `b` within the
//!   intersection tolerance of one of `a` merged with it (the two points' enclosing ball:
//!   its centre, its radius the vertex's gap), then the points where an edge crosses an
//!   edge or a face of the other operand, each welded to a merged vertex within the
//!   tolerance when there is one;
//! - each edge's paves: the merged vertices on it in order from its start to its end, its
//!   own ends among them (its pave blocks are the pieces between consecutive paves; a
//!   piece both operands have, two collinear edges overlapping, is the same pair of
//!   vertices in both, a common block);
//! - each merged vertex's faces: the faces of both operands whose closure it lies on;
//! - each face's section segments: the pieces of the other operand's faces lying in it,
//!   as pairs of merged vertices, which the imprint adds to the face;
//! - the pairs of faces lying in one plane, whose coincident parts the classification
//!   decides by their normals.
//!
//! The order is OCCT's: vertex–vertex, vertex–edge, edge–edge, vertex–face, edge–face,
//! then face–face. A point made by edge–edge or edge–face is tried against every edge
//! of both operands (the lower stages again), so a crossing on a third edge splits it too.
//! Face–face makes no point: two faces of crossing planes share a set of their line whose
//! ends are where one face's boundary crosses the other face, all of which the earlier
//! stages made; the merged vertices both faces lie on are sorted along the line and each
//! gap between two is kept when its middle lies in both faces (§9.1's planar meet, on the
//! merged vertices). Planar faces with straight edges only (curved operands are M5's).

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const grid = @import("../spatial/grid.zig");
const bvh_mod = @import("../spatial/bvh.zig");
const bbox = @import("../measure/bbox.zig");
const in_face = @import("../query/in_face.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const Body = body_mod.Body;
const Box3 = geometry.Box3;
const Bvh = bvh_mod.Bvh;
const Frame = geometry.Frame;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// No merged vertex.
pub const NONE: u32 = std.math.maxInt(u32);

/// Where a boolean is: the interference classes of this phase in their order, then the
/// later phases. A refusal is reported with the stage it came from (the result report's
/// `failed_in`), and the findings of this phase name their class in their label.
pub const Stage = enum {
    /// The operands' own checks (solids, planar faces), before any interference.
    operands,
    vertex_vertex,
    vertex_edge,
    edge_edge,
    vertex_face,
    edge_face,
    face_face,
    imprint,
    classify,
    assemble,
    simplify,
    check,
};

/// A face of an operand: 0 for `a`, 1 for `b`.
pub const FaceRef = struct {
    operand: u1,
    face: u32,

    fn lessThan(x: FaceRef, y: FaceRef) bool {
        return x.operand < y.operand or (x.operand == y.operand and x.face < y.face);
    }
};

/// A merged vertex on an edge, at `s` from its start (0) to its end (1).
pub const Pave = struct {
    vertex: u32,
    s: f64,

    fn lessThan(_: void, x: Pave, y: Pave) bool {
        return x.s < y.s;
    }
};

/// A piece both operands' edges have: its merged vertices (the smaller first), and the
/// edge of `a` and the edge of `b` it is a piece of.
pub const CommonBlock = struct {
    vertices: [2]u32,
    edges: [2]u32,
};

/// A merged vertex lying on a face.
const Incidence = struct {
    face: FaceRef,
    vertex: u32,

    fn lessThan(_: void, x: Incidence, y: Incidence) bool {
        if (x.face.operand != y.face.operand or x.face.face != y.face.face) return x.face.lessThan(y.face);
        return x.vertex < y.vertex;
    }
};

pub const Paves = struct {
    allocator: std.mem.Allocator,
    tol: Tolerance,
    operands: [2]*const Body,
    /// The merged vertices: their points, gaps, and which operands' vertices they hold
    /// (bit 0: `a`'s, bit 1: `b`'s; none for a crossing point).
    points: std.ArrayList(Vec3) = .empty,
    gaps: std.ArrayList(f64) = .empty,
    owners: std.ArrayList(u2) = .empty,
    welder: grid.PointWelder,
    /// Each operand's vertex as a merged vertex (`NONE` for a tombstone).
    vertex_of: [2][]u32 = .{ &.{}, &.{} },
    /// Each operand's edge's paves, by `s`, its ends first and last.
    edge_paves: [2][]std.ArrayList(Pave) = .{ &.{}, &.{} },
    /// The faces of both operands each merged vertex lies on, as sorted pairs.
    incidences: std.ArrayList(Incidence) = .empty,
    /// Each operand's face's section segments (the smaller vertex first).
    sections: [2][]std.ArrayList([2]u32) = .{ &.{}, &.{} },
    /// The pairs of faces (of `a`, of `b`) lying in one plane.
    coplanar: std.ArrayList([2]u32) = .empty,
    /// The common blocks: pieces of an edge of `a` and an edge of `b` between the same two
    /// merged vertices, the operands' edges overlapping there (one edge of the result).
    common: std.ArrayList(CommonBlock) = .empty,

    pub fn deinit(self: *Paves) void {
        const a = self.allocator;
        self.points.deinit(a);
        self.gaps.deinit(a);
        self.owners.deinit(a);
        self.welder.deinit(a);
        for (0..2) |k| {
            a.free(self.vertex_of[k]);
            for (self.edge_paves[k]) |*list| list.deinit(a);
            a.free(self.edge_paves[k]);
            for (self.sections[k]) |*list| list.deinit(a);
            a.free(self.sections[k]);
        }
        self.incidences.deinit(a);
        self.coplanar.deinit(a);
        self.common.deinit(a);
        self.* = undefined;
    }

    pub fn point(self: *const Paves, v: u32) Vec3 {
        return self.points.items[v];
    }

    /// The merged vertices on face `face` of `operand`, in increasing order.
    pub fn verticesOn(self: *const Paves, operand: u1, face: u32, out: *std.ArrayList(u32)) Error!void {
        out.clearRetainingCapacity();
        const key: FaceRef = .{ .operand = operand, .face = face };
        const items = self.incidences.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (items[mid].face.lessThan(key)) lo = mid + 1 else hi = mid;
        }
        while (lo < items.len and items[lo].face.operand == operand and items[lo].face.face == face) : (lo += 1) {
            try out.append(self.allocator, items[lo].vertex);
        }
    }

    /// Whether the operands met nowhere: no vertex of one merged with or lying on the
    /// other, no edge crossing, no face pair coplanar or cut. Then each operand's shells
    /// lie wholly inside or outside the other (the containment table, §7.4 step 0).
    pub fn apart(self: *const Paves) bool {
        if (self.coplanar.items.len > 0 or self.common.items.len > 0) return false;
        for (self.owners.items) |o| if (o != 1 and o != 2) return false;
        for (self.incidences.items) |inc| {
            const o = self.owners.items[inc.vertex];
            if (o != @as(u2, 1) << inc.face.operand) return false;
        }
        for (0..2) |k| {
            for (self.edge_paves[k]) |list| if (list.items.len > 2) return false;
            for (self.sections[k]) |list| if (list.items.len > 0) return false;
        }
        return true;
    }

    /// The faces of the other operand that face `face` of `operand` lies in one plane with.
    pub fn coplanarWith(self: *const Paves, operand: u1, face: u32, out: *std.ArrayList(u32)) Error!void {
        out.clearRetainingCapacity();
        for (self.coplanar.items) |pair| {
            if (pair[operand] == face) try out.append(self.allocator, pair[1 - operand]);
        }
    }
};

/// The paves of `a` and `b` (solids with planar faces and straight edges) at `tol`;
/// `stage` follows the interference classes as they are found, so a refusal's is there.
pub fn run(allocator: std.mem.Allocator, a: *const Body, b: *const Body, tol: Tolerance, options: diagnostics.Options, diag: *Diagnostics, stage: *Stage) Error!Paves {
    var p: Paves = .{ .allocator = allocator, .tol = tol, .operands = .{ a, b }, .welder = grid.PointWelder.init(tol.xsect) };
    errdefer p.deinit();
    for (0..2) |k| {
        const body = p.operands[k];
        p.vertex_of[k] = try allocator.alloc(u32, body.vertices.items.len);
        @memset(p.vertex_of[k], NONE);
        p.edge_paves[k] = try allocator.alloc(std.ArrayList(Pave), body.edges.items.len);
        @memset(p.edge_paves[k], .empty);
        p.sections[k] = try allocator.alloc(std.ArrayList([2]u32), body.faces.items.len);
        @memset(p.sections[k], .empty);
    }
    var filler: Filler = .{ .p = &p, .allocator = allocator, .options = options, .diag = diag, .stage = stage };
    defer filler.deinit();
    stage.* = .vertex_vertex;
    try filler.vertexVertex();
    try filler.buildTrees();
    try options.checkCancel();
    stage.* = .vertex_edge;
    try filler.vertexEdge();
    stage.* = .edge_edge;
    try filler.edgeEdge();
    try options.checkCancel();
    stage.* = .vertex_face;
    try filler.vertexFace();
    stage.* = .edge_face;
    try filler.edgeFace();
    try options.checkCancel();
    stage.* = .face_face;
    try filler.collectIncidences();
    try filler.commonBlocks();
    try filler.faceFace();
    for (0..2) |k| for (p.sections[k]) |*list| sortUnique([2]u32, list, lessPair);
    return p;
}

const Filler = struct {
    p: *Paves,
    allocator: std.mem.Allocator,
    options: diagnostics.Options,
    diag: *Diagnostics,
    stage: *Stage,
    /// Per operand: its live edges and faces, and a tree over each's box grown by the
    /// intersection tolerance.
    edges: [2][]types.EdgeIndex = .{ &.{}, &.{} },
    faces: [2][]types.FaceIndex = .{ &.{}, &.{} },
    edge_tree: [2]Bvh = .{ .{}, .{} },
    face_tree: [2]Bvh = .{ .{}, .{} },
    /// Vertex–face and edge–face incidences found before they are collected.
    found: std.ArrayList(Incidence) = .empty,

    fn deinit(self: *Filler) void {
        for (0..2) |k| {
            self.allocator.free(self.edges[k]);
            self.allocator.free(self.faces[k]);
            self.edge_tree[k].deinit(self.allocator);
            self.face_tree[k].deinit(self.allocator);
        }
        self.found.deinit(self.allocator);
    }

    fn body(self: *const Filler, k: usize) *const Body {
        return self.p.operands[k];
    }

    // --- vertex–vertex ---

    /// Every vertex of `a` a merged vertex of its own; each of `b`'s merged with the first
    /// of `a`'s within the tolerance, else one of its own. Merged vertices take the centre
    /// of their points' box, their gap reaching the furthest.
    fn vertexVertex(self: *Filler) Error!void {
        const p = self.p;
        const a = self.body(0);
        // The vertex of `a` each of its merged vertices holds
        var a_vertex: std.ArrayList(types.VertexIndex) = .empty;
        defer a_vertex.deinit(self.allocator);
        for (a.vertices.items, 0..) |v, i| {
            if (v.tombstone) continue;
            p.vertex_of[0][i] = try self.addPoint(a.point(types.VertexIndex.of(i)), v.gap, 1);
            try a_vertex.append(self.allocator, types.VertexIndex.of(i));
        }
        const from_a: u32 = @intCast(p.points.items.len);
        const b = self.body(1);
        // The points each merged vertex of `a` took from `b`, to place it once all are in
        var taken: std.ArrayList([2]u32) = .empty;
        defer taken.deinit(self.allocator);
        for (b.vertices.items, 0..) |v, i| {
            if (v.tombstone) continue;
            const q = b.point(types.VertexIndex.of(i));
            if (try self.find(q)) |found| if (found < from_a) {
                p.vertex_of[1][i] = found;
                p.owners.items[found] |= 2;
                try taken.append(self.allocator, .{ found, @intCast(i) });
                continue;
            };
            p.vertex_of[1][i] = try self.addPoint(q, v.gap, 2);
        }
        // Each merged vertex at the centre of its points' box
        std.mem.sort([2]u32, taken.items, {}, lessPair);
        var start: usize = 0;
        while (start < taken.items.len) {
            const m = taken.items[start][0];
            var end = start;
            while (end < taken.items.len and taken.items[end][0] == m) end += 1;
            const own_index = a_vertex.items[m];
            const own = a.vertex(own_index);
            var box = Box3.ofPoint(a.point(own_index));
            for (taken.items[start..end]) |t| box.grow(b.point(types.VertexIndex.of(t[1])));
            const centre = box.center();
            var gap = vec.distance(centre, a.point(own_index)) + own.gap;
            for (taken.items[start..end]) |t| {
                const q = types.VertexIndex.of(t[1]);
                gap = @max(gap, vec.distance(centre, b.point(q)) + b.vertex(q).gap);
            }
            p.points.items[m] = centre;
            p.gaps.items[m] = gap;
            start = end;
        }
        // The welder holds the moved points
        p.welder.deinit(self.allocator);
        p.welder = grid.PointWelder.init(p.tol.xsect);
        for (0..p.points.items.len) |i| try self.register(@intCast(i));
    }

    fn addPoint(self: *Filler, q: Vec3, gap: f64, owners: u2) Error!u32 {
        const p = self.p;
        const index: u32 = @intCast(p.points.items.len);
        try p.points.append(self.allocator, q);
        try p.gaps.append(self.allocator, gap);
        try p.owners.append(self.allocator, owners);
        try self.register(index);
        return index;
    }

    /// The first merged vertex within the tolerance of `q`.
    fn find(self: *Filler, q: Vec3) Error!?u32 {
        return self.p.welder.find(self.p.points.items, q) catch |e| return welderError(self.diag, e);
    }

    fn register(self: *Filler, i: u32) Error!void {
        self.p.welder.add(self.allocator, self.p.points.items, i) catch |e| return welderError(self.diag, e);
    }

    /// The merged vertex at `q`: the first within the tolerance, else a new one.
    fn weld(self: *Filler, q: Vec3, gap: f64) Error!u32 {
        if (try self.find(q)) |found| return found;
        return self.addPoint(q, gap, 0);
    }

    // --- the trees and each edge's ends ---

    fn buildTrees(self: *Filler) Error!void {
        const p = self.p;
        const xsect = p.tol.xsect;
        for (0..2) |k| {
            const body_k = self.body(k);
            var edges: std.ArrayList(types.EdgeIndex) = .empty;
            defer edges.deinit(self.allocator);
            var boxes: std.ArrayList(Box3) = .empty;
            defer boxes.deinit(self.allocator);
            for (body_k.edges.items, 0..) |e, i| {
                if (e.flags.tombstone or e.coedge == .none) continue;
                const s = p.vertex_of[k][@backingInt(e.start)];
                const t = p.vertex_of[k][@backingInt(e.end)];
                try p.edge_paves[k][i].append(self.allocator, .{ .vertex = s, .s = 0 });
                try p.edge_paves[k][i].append(self.allocator, .{ .vertex = t, .s = 1 });
                try edges.append(self.allocator, types.EdgeIndex.of(i));
                var box = Box3.ofPoint(p.point(s));
                box.grow(p.point(t));
                try boxes.append(self.allocator, box.inflated(xsect + @max(p.gaps.items[s], p.gaps.items[t])));
            }
            self.edges[k] = try edges.toOwnedSlice(self.allocator);
            self.edge_tree[k] = try Bvh.build(self.allocator, boxes.items);

            var faces: std.ArrayList(types.FaceIndex) = .empty;
            defer faces.deinit(self.allocator);
            boxes.clearRetainingCapacity();
            var shells = traverse.Shells.init(body_k);
            while (shells.next() catch return corrupt(self.diag)) |s| {
                var it = traverse.Faces.init(body_k, s);
                while (it.next() catch return corrupt(self.diag)) |f| {
                    try faces.append(self.allocator, f);
                    const box = bbox.faceBounds(body_k, f) catch return corrupt(self.diag);
                    try boxes.append(self.allocator, box.inflated(2 * xsect));
                }
            }
            self.faces[k] = try faces.toOwnedSlice(self.allocator);
            self.face_tree[k] = try Bvh.build(self.allocator, boxes.items);
        }
    }

    /// Edge `e` of operand `k` as its merged ends.
    fn ends(self: *const Filler, k: usize, e: types.EdgeIndex) [2]u32 {
        const edge = self.body(k).edge(e);
        return .{ self.p.vertex_of[k][@backingInt(edge.start)], self.p.vertex_of[k][@backingInt(edge.end)] };
    }

    fn hasPave(self: *const Filler, k: usize, e: types.EdgeIndex, v: u32) bool {
        for (self.p.edge_paves[k][@backingInt(e)].items) |pave| if (pave.vertex == v) return true;
        return false;
    }

    /// Where `q` lies along edge `e` of operand `k`: its parameter from start (0) to end
    /// (1) and its distance from the edge's segment, when its foot is inside the edge's
    /// shrunk range (OCCT's `IntTools_ShrunkRange`): beyond the intersection tolerance and
    /// the end's gap from either end, where the end's ball does not already hold it.
    /// `splittable` is false for an edge whose shrunk range is shorter than twice the
    /// tolerance: a pave there would leave a piece too short to be an edge.
    fn along(self: *const Filler, k: usize, e: types.EdgeIndex, q: Vec3) ?Along {
        const v = self.ends(k, e);
        const p0 = self.p.point(v[0]);
        const p1 = self.p.point(v[1]);
        const d = vec.sub(p1, p0);
        const len_sq = vec.lengthSq(d);
        if (len_sq == 0) return null;
        const s = vec.dot(vec.sub(q, p0), d) / len_sq;
        const len = @sqrt(len_sq);
        const xsect = self.p.tol.xsect;
        const lo = xsect + self.p.gaps.items[v[0]];
        const hi = len - (xsect + self.p.gaps.items[v[1]]);
        if (s * len <= lo or s * len >= hi) return null;
        return .{ .s = s, .distance = vec.distance(q, vec.addScaled(p0, d, s)), .splittable = hi - lo >= 2 * xsect };
    }

    const Along = struct { s: f64, distance: f64, splittable: bool };

    /// Merged vertex `v` as a pave of edge `e` of operand `k` at `at`; `TooSmallEdge`,
    /// naming the edge, when the edge cannot be split.
    fn addPave(self: *Filler, k: usize, e: types.EdgeIndex, v: u32, at: Along) Error!void {
        if (!at.splittable) return self.diag.fail(error.TooSmallEdge, .{ .code = .edge_too_short, .entity = .of(.edge, @backingInt(e)), .label = tooSmallLabel(k, self.stage.*), .measured = vec.distance(self.p.point(self.ends(k, e)[0]), self.p.point(self.ends(k, e)[1])), .threshold = 4 * self.p.tol.xsect });
        try self.p.edge_paves[k][@backingInt(e)].append(self.allocator, .{ .vertex = v, .s = at.s });
    }

    // --- vertex–edge ---

    /// Every merged vertex holding no vertex of an operand, against that operand's edges.
    fn vertexEdge(self: *Filler) Error!void {
        const count = self.p.points.items.len;
        for (0..count) |v| {
            const owners = self.p.owners.items[v];
            for (0..2) |k| {
                if (owners & (@as(u2, 1) << @intCast(k)) != 0) continue;
                try self.onEdges(k, @intCast(v), null);
            }
        }
    }

    /// Merged vertex `v` as a pave of every edge of operand `k` it lies on (within the
    /// tolerance and its gap), but `skip`.
    fn onEdges(self: *Filler, k: usize, v: u32, skip: ?types.EdgeIndex) Error!void {
        const q = self.p.point(v);
        const Collect = struct {
            out: [64]u32 = undefined,
            count: usize = 0,
            fn visit(c: *@This(), item: u32) bool {
                if (c.count == c.out.len) return false;
                c.out[c.count] = item;
                c.count += 1;
                return true;
            }
        };
        var collect: Collect = .{};
        self.edge_tree[k].query(Box3.ofPoint(q), &collect, Collect.visit);
        if (collect.count == collect.out.len) return self.diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "edges near one vertex", .measured = @floatFromInt(collect.count) });
        std.mem.sort(u32, collect.out[0..collect.count], {}, std.sort.asc(u32));
        for (collect.out[0..collect.count]) |item| {
            const e = self.edges[k][item];
            if (skip != null and skip.? == e) continue;
            if (self.hasPave(k, e, v)) continue;
            const at = self.along(k, e, q) orelse continue;
            if (at.distance > self.p.tol.xsect + self.p.gaps.items[v]) continue;
            try self.addPave(k, e, v, at);
        }
    }

    // --- edge–edge ---

    /// Every pair of edges of `a` and `b` crossing within the tolerance, away from their
    /// ends (an end on the other edge is vertex–edge's; collinear overlaps are made of
    /// those), gives a merged vertex on both, tried against every other edge too.
    fn edgeEdge(self: *Filler) Error!void {
        var pairs = try self.overlapping(&self.edge_tree[0], &self.edge_tree[1]);
        defer pairs.deinit(self.allocator);
        for (pairs.items) |pair| {
            const ea = self.edges[0][pair[0]];
            const eb = self.edges[1][pair[1]];
            const va = self.ends(0, ea);
            const vb = self.ends(1, eb);
            const p0 = self.p.point(va[0]);
            const d0 = vec.sub(self.p.point(va[1]), p0);
            const q0 = self.p.point(vb[0]);
            const d1 = vec.sub(self.p.point(vb[1]), q0);
            const closest = closestOnLines(p0, d0, q0, d1) orelse continue;
            const c0 = vec.addScaled(p0, d0, closest[0]);
            const c1 = vec.addScaled(q0, d1, closest[1]);
            const gap = vec.distance(c0, c1);
            if (gap > self.p.tol.xsect) continue;
            const mid = vec.lerp(c0, c1, 0.5);
            // Away from both edges' ends: an end there is vertex–edge's or vertex–vertex's
            if (self.along(0, ea, mid) == null or self.along(1, eb, mid) == null) continue;
            const v = try self.weld(mid, gap / 2);
            for ([2]usize{ 0, 1 }, [2]types.EdgeIndex{ ea, eb }) |k, e| {
                if (self.hasPave(k, e, v)) continue;
                const at = self.along(k, e, self.p.point(v)) orelse continue;
                try self.addPave(k, e, v, at);
            }
            try self.onEdges(0, v, ea);
            try self.onEdges(1, v, eb);
        }
    }

    /// The pairs of items of two trees whose boxes overlap, sorted.
    fn overlapping(self: *Filler, x: *const Bvh, y: *const Bvh) Error!std.ArrayList([2]u32) {
        const Collect = struct {
            allocator: std.mem.Allocator,
            out: std.ArrayList([2]u32) = .empty,
            failed: bool = false,
            fn visit(c: *@This(), i: u32, j: u32) bool {
                c.out.append(c.allocator, .{ i, j }) catch {
                    c.failed = true;
                    return false;
                };
                return true;
            }
        };
        var collect: Collect = .{ .allocator = self.allocator };
        errdefer collect.out.deinit(self.allocator);
        x.queryPairs(y, &collect, Collect.visit);
        if (collect.failed) return error.OutOfMemory;
        std.mem.sort([2]u32, collect.out.items, {}, lessPair);
        return collect.out;
    }

    // --- vertex–face ---

    /// Every merged vertex holding a vertex of one operand, against the other's faces: on
    /// a face's plane within the tolerance and inside it, it lies on the face.
    fn vertexFace(self: *Filler) Error!void {
        const count = self.p.points.items.len;
        for (0..count) |v| {
            const owners = self.p.owners.items[v];
            if (owners == 0 or owners == 3) continue;
            const k: usize = if (owners == 1) 1 else 0;
            try self.onFaces(k, @intCast(v));
        }
    }

    fn onFaces(self: *Filler, k: usize, v: u32) Error!void {
        const q = self.p.point(v);
        const Collect = struct {
            out: [64]u32 = undefined,
            count: usize = 0,
            fn visit(c: *@This(), item: u32) bool {
                if (c.count == c.out.len) return false;
                c.out[c.count] = item;
                c.count += 1;
                return true;
            }
        };
        var collect: Collect = .{};
        self.face_tree[k].query(Box3.ofPoint(q), &collect, Collect.visit);
        if (collect.count == collect.out.len) return self.diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "faces near one vertex", .measured = @floatFromInt(collect.count) });
        for (collect.out[0..collect.count]) |item| {
            const f = self.faces[k][item];
            const frame = planar_faces.frameOf(self.body(k), f).?;
            if (@abs(planar_faces.planeOf(frame).height(q)) > self.p.tol.xsect + self.p.gaps.items[v]) continue;
            if (try planar_faces.place(self.body(k), f, q, self.p.tol, self.diag) == .outside) continue;
            try self.found.append(self.allocator, .{ .face = .{ .operand = @intCast(k), .face = @backingInt(f) }, .vertex = v });
        }
    }

    // --- edge–face ---

    /// Every edge of one operand crossing a face of the other, its ends on either side of
    /// the face's plane beyond the tolerance (an end on the plane is vertex–face's): the
    /// crossing, inside the face or on its boundary, a merged vertex on the edge and the
    /// face (one on the face's boundary tried against the other operand's edges, where
    /// edge–edge should have found it).
    fn edgeFace(self: *Filler) Error!void {
        for (0..2) |k| {
            const other = 1 - k;
            var pairs = try self.overlapping(&self.edge_tree[k], &self.face_tree[other]);
            defer pairs.deinit(self.allocator);
            for (pairs.items) |pair| {
                const e = self.edges[k][pair[0]];
                const f = self.faces[other][pair[1]];
                const v = self.ends(k, e);
                const p0 = self.p.point(v[0]);
                const p1 = self.p.point(v[1]);
                const plane = planar_faces.planeOf(planar_faces.frameOf(self.body(other), f).?);
                const h0 = plane.height(p0);
                const h1 = plane.height(p1);
                const xsect = self.p.tol.xsect;
                if (@abs(h0) <= xsect or @abs(h1) <= xsect or (h0 < 0) == (h1 < 0)) continue;
                const q = vec.lerp(p0, p1, h0 / (h0 - h1));
                const place = try planar_faces.place(self.body(other), f, q, self.p.tol, self.diag);
                if (place == .outside) continue;
                const before = self.p.points.items.len;
                const w = try self.weld(q, 0);
                if (!self.hasPave(k, e, w)) {
                    if (self.along(k, e, self.p.point(w))) |at| try self.addPave(k, e, w, at);
                }
                try self.found.append(self.allocator, .{ .face = .{ .operand = @intCast(other), .face = @backingInt(f) }, .vertex = w });
                if (place == .boundary and self.p.points.items.len > before) try self.onEdges(other, w, null);
            }
        }
    }

    // --- incidences ---

    /// Each face's merged vertices: its edges' paves, and what vertex–face and edge–face
    /// found; each edge's paves sorted.
    fn collectIncidences(self: *Filler) Error!void {
        const p = self.p;
        for (0..2) |k| {
            for (p.edge_paves[k]) |*list| std.mem.sort(Pave, list.items, {}, Pave.lessThan);
            const body_k = self.body(k);
            for (self.faces[k]) |f| {
                var loops = traverse.Loops.init(body_k, f);
                while (loops.next() catch return corrupt(self.diag)) |l| {
                    var it = traverse.Coedges.init(body_k, l);
                    while (it.next() catch return corrupt(self.diag)) |c| {
                        for (p.edge_paves[k][@backingInt(body_k.coedge(c).edge)].items) |pave| {
                            try p.incidences.append(self.allocator, .{ .face = .{ .operand = @intCast(k), .face = @backingInt(f) }, .vertex = pave.vertex });
                        }
                    }
                }
            }
        }
        try p.incidences.appendSlice(self.allocator, self.found.items);
        sortUnique(Incidence, &p.incidences, Incidence.lessThan);
    }

    // --- common blocks ---

    /// The pave blocks of `a`'s edges and `b`'s between the same two merged vertices.
    fn commonBlocks(self: *Filler) Error!void {
        const p = self.p;
        var of_a: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
        defer of_a.deinit(self.allocator);
        for (self.edges[0]) |e| {
            const list = p.edge_paves[0][@backingInt(e)].items;
            for (list[0 .. list.len - 1], list[1..]) |x, y| try of_a.put(self.allocator, .{ @min(x.vertex, y.vertex), @max(x.vertex, y.vertex) }, @backingInt(e));
        }
        for (self.edges[1]) |e| {
            const list = p.edge_paves[1][@backingInt(e)].items;
            for (list[0 .. list.len - 1], list[1..]) |x, y| {
                const key: [2]u32 = .{ @min(x.vertex, y.vertex), @max(x.vertex, y.vertex) };
                const ea = of_a.get(key) orelse continue;
                try p.common.append(self.allocator, .{ .vertices = key, .edges = .{ ea, @backingInt(e) } });
            }
        }
    }

    // --- face–face ---

    /// Every pair of faces of `a` and `b`: lying in one plane, recorded, and each one's
    /// pave blocks inside the other a section segment of it; else the merged vertices both
    /// lie on, sorted along their planes' line, each gap whose middle is in both faces a
    /// section segment of each face it is inside of.
    fn faceFace(self: *Filler) Error!void {
        const p = self.p;
        var pairs = try self.overlapping(&self.face_tree[0], &self.face_tree[1]);
        defer pairs.deinit(self.allocator);
        var on_a: std.ArrayList(u32) = .empty;
        defer on_a.deinit(self.allocator);
        var on_b: std.ArrayList(u32) = .empty;
        defer on_b.deinit(self.allocator);
        var both: std.ArrayList(u32) = .empty;
        defer both.deinit(self.allocator);
        for (pairs.items) |pair| {
            try self.options.checkCancel();
            const fa = self.faces[0][pair[0]];
            const fb = self.faces[1][pair[1]];
            const frame_a = planar_faces.frameOf(self.body(0), fa).?;
            const frame_b = planar_faces.frameOf(self.body(1), fb).?;
            if (try self.liesIn(0, fa, frame_b) or try self.liesIn(1, fb, frame_a)) {
                try p.coplanar.append(self.allocator, .{ @backingInt(fa), @backingInt(fb) });
                try self.blocksInside(1, fb, 0, fa);
                try self.blocksInside(0, fa, 1, fb);
                continue;
            }
            // Parallel and a hair apart: not one plane, but the result will have faces as
            // thin as the hair (OCCT's BadPositioning)
            if (p.tol.parallel(frame_a.z, frame_b.z)) {
                const apart = try self.planeGap(0, fa, frame_b);
                if (apart <= NEARLY_COPLANAR * p.tol.xsect) try self.diag.warn(.{ .code = .nearly_coplanar, .entity = .of(.face, @backingInt(fa)), .measured = apart, .threshold = p.tol.xsect });
            }
            const line = vec.normalized(vec.cross(frame_a.z, frame_b.z)) orelse continue;
            try p.verticesOn(0, @backingInt(fa), &on_a);
            try p.verticesOn(1, @backingInt(fb), &on_b);
            both.clearRetainingCapacity();
            var i: usize = 0;
            var j: usize = 0;
            while (i < on_a.items.len and j < on_b.items.len) {
                if (on_a.items[i] == on_b.items[j]) {
                    try both.append(self.allocator, on_a.items[i]);
                    i += 1;
                    j += 1;
                } else if (on_a.items[i] < on_b.items[j]) i += 1 else j += 1;
            }
            if (both.items.len < 2) continue;
            const Order = struct {
                points: []const Vec3,
                line: Vec3,
                fn lessThan(o: @This(), x: u32, y: u32) bool {
                    const sx = vec.dot(o.points[x], o.line);
                    const sy = vec.dot(o.points[y], o.line);
                    return sx < sy or (sx == sy and x < y);
                }
            };
            std.mem.sort(u32, both.items, Order{ .points = p.points.items, .line = line }, Order.lessThan);
            for (both.items[0 .. both.items.len - 1], both.items[1..]) |u, w| {
                const mid = vec.lerp(p.point(u), p.point(w), 0.5);
                const in_a = try planar_faces.place(self.body(0), fa, mid, p.tol, self.diag);
                if (in_a == .outside) continue;
                const in_b = try planar_faces.place(self.body(1), fb, mid, p.tol, self.diag);
                if (in_b == .outside) continue;
                const segment = .{ @min(u, w), @max(u, w) };
                if (in_a == .inside) try p.sections[0][@backingInt(fa)].append(self.allocator, segment);
                if (in_b == .inside) try p.sections[1][@backingInt(fb)].append(self.allocator, segment);
            }
        }
    }

    /// The furthest any vertex of face `f` of operand `k` lies from the plane of `frame`.
    fn planeGap(self: *const Filler, k: usize, f: types.FaceIndex, frame: Frame) Error!f64 {
        const p = self.p;
        const plane = planar_faces.planeOf(frame);
        const body_k = self.body(k);
        var apart: f64 = 0;
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| apart = @max(apart, @abs(plane.height(p.point(p.vertex_of[k][@backingInt(body_k.coedgeStart(c))]))));
        }
        return apart;
    }

    /// Whether every vertex of face `f` of operand `k` lies on the plane of `frame` within
    /// the tolerance and its gap.
    fn liesIn(self: *const Filler, k: usize, f: types.FaceIndex, frame: Frame) Error!bool {
        const p = self.p;
        const plane = planar_faces.planeOf(frame);
        const body_k = self.body(k);
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const v = p.vertex_of[k][@backingInt(body_k.coedgeStart(c))];
                if (@abs(plane.height(p.point(v))) > p.tol.xsect + p.gaps.items[v]) return false;
            }
        }
        return true;
    }

    /// Each pave block of face `f` of operand `k` whose middle is inside face `g` of
    /// operand `other` (one plane): a section segment of `g`.
    fn blocksInside(self: *Filler, k: usize, f: types.FaceIndex, other: usize, g: types.FaceIndex) Error!void {
        const p = self.p;
        const body_k = self.body(k);
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const list = p.edge_paves[k][@backingInt(body_k.coedge(c).edge)].items;
                for (list[0 .. list.len - 1], list[1..]) |x, y| {
                    const mid = vec.lerp(p.point(x.vertex), p.point(y.vertex), 0.5);
                    if (try planar_faces.place(self.body(other), g, mid, p.tol, self.diag) != .inside) continue;
                    try p.sections[other][@backingInt(g)].append(self.allocator, .{ @min(x.vertex, y.vertex), @max(x.vertex, y.vertex) });
                }
            }
        }
    }
};

/// The parameters along two lines `p + s·d` and `q + u·e` of their closest points; null
/// when they are parallel.
fn closestOnLines(p: Vec3, d: Vec3, q: Vec3, e: Vec3) ?[2]f64 {
    const r = vec.sub(p, q);
    const a = vec.dot(d, d);
    const b = vec.dot(d, e);
    const c = vec.dot(e, e);
    const f = vec.dot(e, r);
    const g = vec.dot(d, r);
    const denom = a * c - b * b;
    // Parallel: the cross product's square against the lengths' (sin² of the angle)
    if (denom <= PARALLEL * a * c) return null;
    return .{ (b * f - c * g) / denom, (a * f - b * g) / denom };
}

/// How many intersection tolerances apart two parallel faces of the operands may lie for
/// the warning that the result will have faces that thin.
const NEARLY_COPLANAR: f64 = 100;

/// The squared sine of the angle under which two edges count as parallel for edge–edge:
/// their crossing, if any, lies along an overlap that vertex–edge already split.
const PARALLEL: f64 = 1e-20;

fn lessPair(_: void, x: [2]u32, y: [2]u32) bool {
    return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
}

fn sortUnique(comptime T: type, list: *std.ArrayList(T), comptime lessThan: fn (void, T, T) bool) void {
    std.mem.sort(T, list.items, {}, lessThan);
    var kept: usize = 0;
    for (list.items) |item| {
        if (kept > 0 and !lessThan({}, list.items[kept - 1], item)) continue;
        list.items[kept] = item;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
}

/// What a refusal of an edge too short to split says, naming the operand and the
/// interference class that would have split it.
fn tooSmallLabel(k: usize, stage: Stage) []const u8 {
    return switch (stage) {
        .vertex_edge => if (k == 0) "an edge of the first operand, too short to split at a vertex of the second on it (vertex–edge)" else "an edge of the second operand, too short to split at a vertex of the first on it (vertex–edge)",
        .edge_edge => if (k == 0) "an edge of the first operand, too short to split where an edge of the second crosses it (edge–edge)" else "an edge of the second operand, too short to split where an edge of the first crosses it (edge–edge)",
        else => if (k == 0) "an edge of the first operand, too short to split where it crosses a face of the second (edge–face)" else "an edge of the second operand, too short to split where it crosses a face of the first (edge–face)",
    };
}

fn welderError(diag: *Diagnostics, err: grid.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.OutOfRange => diag.fail(error.InvalidInput, .{ .code = .too_large_for_tolerance, .label = "a vertex" }),
    };
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "an operand" });
}
