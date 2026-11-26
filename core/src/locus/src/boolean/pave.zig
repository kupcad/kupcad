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
//!
//! Where one operand comes within the tolerance of two of the other's features that do not
//! meet there, no decision of the tolerance is consistent (the minimum feature size,
//! architecture §3), and the paves refuse it (`below_feature_size`): at a merged vertex,
//! within reach of two faces that meet nowhere near it (`featureSize`); and at a face, two
//! faces of the other operand in its plane but not in one (`coplanarTogether`), two
//! pieces they leave on it within the tolerance of each other in its plane where they share
//! no merged vertex, or one within it of the face's own boundary where the paves did not
//! join them (`sectionsApart`), and two faces of the other facing apart and parallel
//! to it, both within the tolerance of one point of it, whether they meet or not (a thin
//! feature or a knife edge it lies along, `sandwiched`); and at two faces of the operands
//! parallel within the angular tolerance and not in one plane, the line of the merged
//! vertices both hold, within the tolerance of both planes where they are farther than it
//! from each other (`hingedWithin`). Two features of one operand nearer than twice the
//! tolerance where they do not meet are refused before the paves (`pipeline.featureSize`);
//! these are what the operands bring about together past that: a merged vertex reaches by
//! its gap too (up to the zone), and a face of one operand probes the other's pair, two
//! faces meeting at an edge among them.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const canonical = @import("../geometry/canonical.zig");
const curves = @import("../geometry/curves.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const grid = @import("../spatial/grid.zig");
const bvh_mod = @import("../spatial/bvh.zig");
const bbox = @import("../topology/bbox.zig");
const in_face = @import("../query/in_face.zig");
const face_edges = @import("../query/face_edges.zig");
const planar_faces = @import("../intersect/planar_faces.zig");
const pointBefore = planar_faces.pointBefore;
const overlap = @import("../query/overlap.zig");
const incidence = @import("../geometry/incidence.zig");
const curve_surface = @import("../intersect/curve_surface.zig");
const predicates = @import("../math/predicates.zig");
const Body = body_mod.Body;
const Box3 = geometry.Box3;
const Bvh = bvh_mod.Bvh;
const Frame = geometry.Frame;
const Plane = curve_surface.Plane;
const Verdict = canonical.Verdict;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The most corners a convex polygon clipped for `Filler.sandwiched` holds: a box clipped
/// by four half-planes and three triangles' nine, each adding a corner at most.
const MAX_CLIPPED = 64;
/// How many intersection tolerances apart two parallel faces of the operands may lie for
/// the warning that the result will have faces that thin.
const NEARLY_COPLANAR: f64 = 100;

/// The squared sine of the angle under which two edges count as parallel for edge–edge:
/// their crossing, if any, lies along an overlap that vertex–edge already split.
const PARALLEL: f64 = 1e-20;

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

/// The interference classes, in the order they run (OCCT's): what each pave, merge,
/// incidence or section is found by.
pub const INTERFERENCES = [_]Stage{ .vertex_vertex, .vertex_edge, .edge_edge, .vertex_face, .edge_face, .face_face };

/// The index of interference class `stage` in `INTERFERENCES`.
pub fn interferenceIndex(stage: Stage) usize {
    return for (INTERFERENCES, 0..) |s, i| {
        if (s == stage) break i;
    } else unreachable;
}

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

/// A merged vertex strictly inside face `face` of `operand`.
pub const Touch = struct {
    operand: u1,
    face: u32,
    vertex: u32,

    fn lessThan(_: void, x: Touch, y: Touch) bool {
        if (x.operand != y.operand) return x.operand < y.operand;
        if (x.face != y.face) return x.face < y.face;
        return x.vertex < y.vertex;
    }
};

/// A merged vertex lying on a face.
const Incidence = struct {
    face: FaceRef,
    vertex: u32,

    fn lessThan(_: void, x: Incidence, y: Incidence) bool {
        if (x.face.operand != y.face.operand or x.face.face != y.face.face) return x.face.lessThan(y.face);
        return x.vertex < y.vertex;
    }

    /// Whether sorted `items` hold `key`.
    fn in(items: []const Incidence, key: Incidence) bool {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (lessThan({}, items[mid], key)) lo = mid + 1 else hi = mid;
        }
        return lo < items.len and !lessThan({}, key, items[lo]);
    }
};

/// The scratch of `Filler.sandwiched`: a face's triangles and two others', in its plane.
const Sandwich = struct {
    f: std.ArrayList([3]Vec2) = .empty,
    g1: std.ArrayList([3]Vec2) = .empty,
    g2: std.ArrayList([3]Vec2) = .empty,

    fn deinit(self: *Sandwich, allocator: std.mem.Allocator) void {
        self.f.deinit(allocator);
        self.g1.deinit(allocator);
        self.g2.deinit(allocator);
    }
};

/// A convex polygon in a plane, counter-clockwise, clipped by half-planes (Sutherland and
/// Hodgman).
const Convex = struct {
    points: [MAX_CLIPPED]Vec2 = undefined,
    len: usize = 0,

    /// The part where `n · q ≤ c`.
    fn clip(self: Convex, n: Vec2, c: f64) Convex {
        var out: Convex = .{};
        for (0..self.len) |i| {
            const a = self.points[i];
            const b = self.points[(i + 1) % self.len];
            const sa = c - vec.dot2(n, a);
            const sb = c - vec.dot2(n, b);
            if (sa >= 0) out.push(a);
            if ((sa >= 0) != (sb >= 0)) out.push(vec.addScaled2(a, vec.sub2(b, a), sa / (sa - sb)));
        }
        return out;
    }

    /// The part inside triangle `t` (counter-clockwise): left of each of its sides.
    fn clipTriangle(self: Convex, t: [3]Vec2) Convex {
        var out = self;
        for (0..3) |i| {
            const a = t[i];
            const d = vec.sub2(t[(i + 1) % 3], a);
            const n: Vec2 = .{ d[1], -d[0] };
            out = out.clip(n, vec.dot2(n, a));
        }
        return out;
    }

    fn push(self: *Convex, q: Vec2) void {
        std.debug.assert(self.len < MAX_CLIPPED);
        self.points[self.len] = q;
        self.len += 1;
    }

    /// Its area, about its first corner.
    fn area(self: Convex) f64 {
        if (self.len < 3) return 0;
        var twice: f64 = 0;
        for (1..self.len - 1) |i| twice += vec.cross2(vec.sub2(self.points[i], self.points[0]), vec.sub2(self.points[i + 1], self.points[0]));
        return twice / 2;
    }

    /// How wide it is: its area over half its perimeter, a strip's width (the measure the
    /// checker holds a face's against the zone, `check`'s slivers); 0 for none.
    fn width(self: Convex) f64 {
        const a = self.area();
        if (!(a > 0)) return 0;
        var around: f64 = 0;
        for (0..self.len) |i| around += vec.length2(vec.sub2(self.points[(i + 1) % self.len], self.points[i]));
        return a / (around / 2);
    }
};

/// `Filler.knifeBlocks`'s scratch: each face's spans of a block's feet inside it, and the
/// ends of the stretches within both.
const Stretch = struct {
    within: [2]std.ArrayList([2]f64) = .{ .empty, .empty },
    ends: std.ArrayList(f64) = .empty,

    fn deinit(self: *Stretch, allocator: std.mem.Allocator) void {
        for (&self.within) |*list| list.deinit(allocator);
        self.ends.deinit(allocator);
    }
};

/// The faces of one operand whose grown boxes hold a point, from its face tree: at most
/// as many as `items` holds, a query that fills it being refused (`limit_exceeded`).
const NearFaces = struct {
    items: [64]u32 = undefined,
    count: usize = 0,

    fn visit(c: *NearFaces, item: u32) bool {
        if (c.count == c.items.len) return false;
        c.items[c.count] = item;
        c.count += 1;
        return true;
    }
};

/// An edge or a face of operand `k`: what made an intersection point (`Filler.weld`).
const Feature = union(enum) {
    edge: struct { k: usize, e: types.EdgeIndex },
    face: struct { k: usize, f: types.FaceIndex },

    fn operand(self: Feature) usize {
        return switch (self) {
            inline else => |x| x.k,
        };
    }

    fn entity(self: Feature) diagnostics.EntityRef {
        return switch (self) {
            .edge => |x| .of(.edge, @backingInt(x.e)),
            .face => |x| .of(.face, @backingInt(x.f)),
        };
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
    /// Each merged vertex's largest distance from an operand's edge it is a pave of, a face
    /// it was found on, or a section line it ends a segment of: how far the result's vertex
    /// may be from the geometry it is put on (the report's `max_gap` takes it, with the
    /// balls' gaps).
    reach: std.ArrayList(f64) = .empty,
    owners: std.ArrayList(u2) = .empty,
    welder: grid.PointWelder,
    /// The decisions of "on" at the tolerance, for coordinates the operands' size
    /// (`geometry/incidence.zig`): a distance within rounding of its limit is the limit to
    /// rounding, which one computation finds within it and another beyond (the solids
    /// fuzzer's finds of 2026-11-13, an operand moved by the tolerance exactly), refused
    /// (`Filler.within`, `at_tolerance`).
    decide: incidence.Decider,
    /// The widest band of those decisions: what a search reaches beyond a limit.
    rounding: f64,
    /// Each operand's vertex as a merged vertex (`NONE` for a tombstone).
    vertex_of: [2][]u32 = .{ &.{}, &.{} },
    /// Each operand's edge's paves, by `s`, its ends first and last.
    edge_paves: [2][]std.ArrayList(Pave) = .{ &.{}, &.{} },
    /// The faces of both operands each merged vertex lies on, as sorted pairs.
    incidences: std.ArrayList(Incidence) = .empty,
    /// Of those, the ones on a face's boundary (a pave of one of its edges), sorted: what
    /// the paves decided lies on the boundary, which later decisions defer to.
    boundary: std.ArrayList(Incidence) = .empty,
    /// Each operand's face's section segments (the smaller vertex first).
    sections: [2][]std.ArrayList([2]u32) = .{ &.{}, &.{} },
    /// Each section segment's line: through its two merged vertices, which lie within the
    /// tolerance of both faces, so the whole segment does, however shallow the angle the
    /// faces meet at (the band within the tolerance of both is wide there, and the planes'
    /// own line can lie far from a vertex in it: a vertex 1.9e-5 off a face the other meets
    /// at 5° is 2.2e-4 from it). Collinear segments join again in `simplify` (D28).
    section_lines: std.ArrayList(curves.Line) = .empty,
    /// Each section segment's line in `section_lines`.
    section_line_of: std.AutoHashMapUnmanaged([2]u32, u32) = .empty,
    /// The pairs of faces (of `a`, of `b`) lying in one plane.
    coplanar: std.ArrayList([2]u32) = .empty,
    /// The merged vertices strictly inside a face of an operand, a vertex of the other
    /// (vertex–face) or crossings of its edges (edge–face), sorted: where the operands
    /// touch at a point, unless the face's imprint puts the vertex on an edge (the other
    /// operand passing through the face there). Assembly refuses a result that keeps such
    /// a point inside one solid, a pinch no edge records.
    touches: std.ArrayList(Touch) = .empty,
    /// The common blocks: pieces of an edge of `a` and an edge of `b` between the same two
    /// merged vertices, the operands' edges overlapping there (one edge of the result).
    common: std.ArrayList(CommonBlock) = .empty,
    /// How many interferences each class found (`INTERFERENCES`' order): vertices merged,
    /// paves added, vertices found on faces, sections added; the result report's.
    found: [INTERFERENCES.len]u32 = @splat(0),

    pub fn deinit(self: *Paves) void {
        const a = self.allocator;
        self.points.deinit(a);
        self.gaps.deinit(a);
        self.reach.deinit(a);
        self.owners.deinit(a);
        self.welder.deinit(a);
        for (0..2) |k| {
            a.free(self.vertex_of[k]);
            for (self.edge_paves[k]) |*list| list.deinit(a);
            a.free(self.edge_paves[k]);
            for (self.sections[k]) |*list| list.deinit(a);
            a.free(self.sections[k]);
        }
        self.section_lines.deinit(a);
        self.section_line_of.deinit(a);
        self.incidences.deinit(a);
        self.boundary.deinit(a);
        self.coplanar.deinit(a);
        self.common.deinit(a);
        self.touches.deinit(a);
        self.* = undefined;
    }

    pub fn point(self: *const Paves, v: u32) Vec3 {
        return self.points.items[v];
    }

    /// Whether merged vertex `v` is on `plane`, within its reach of it (the tolerance and
    /// its gap): the verdict, not yet taken. A decision over several vertices combines
    /// theirs first (`canonical.both`: one clearly off the plane decides, whatever the
    /// others) and refuses once, so it does not hang on which vertex was asked first.
    pub fn onPlane(self: *const Paves, plane: Plane, v: u32) Verdict {
        return self.decide.onPlane(plane.height(self.point(v)), self.gaps.items[v]);
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

    /// Whether face `face` of `operand` and face `other_face` of the other operand lie in
    /// one plane, as the paves decided it (`coplanar`).
    pub fn inOnePlane(self: *const Paves, operand: u1, face: u32, other_face: u32) bool {
        for (self.coplanar.items) |pair| {
            if (pair[operand] == face and pair[1 - operand] == other_face) return true;
        }
        return false;
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
    const decide: incidence.Decider = .{ .tol = tol, .scale = try scaleOf(a, b, diag) };
    const rounding = decide.band();
    var p: Paves = .{ .allocator = allocator, .tol = tol, .operands = .{ a, b }, .decide = decide, .rounding = rounding, .welder = grid.PointWelder.initWithMargin(tol.xsect, rounding) };
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
    // Every reach is fixed from here on: a later class adds merged vertices, never grows
    // one's gap, so a decision taken holds whatever comes after it, and D27's band need be
    // only the rounding (Segal's 1986 band was as wide as the largest vertex tolerance,
    // which grew after decisions were taken; research/consistent-tolerances.md)
    const fixed = if (std.debug.runtime_safety) try allocator.dupe(f64, p.gaps.items) else &[_]f64{};
    defer if (std.debug.runtime_safety) allocator.free(fixed);
    defer if (std.debug.runtime_safety) std.debug.assert(std.mem.eql(f64, fixed, p.gaps.items[0..fixed.len]));
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
    try filler.featureSize();
    try filler.knifeBlocks();
    try filler.commonBlocks();
    try filler.faceFace();
    try filler.nearlyCoplanar();
    for (0..2) |k| for (p.sections[k]) |*list| sortUnique([2]u32, list, lessPair);
    try filler.coplanarTogether();
    try filler.sectionsApart();
    try filler.sandwiched();
    return p;
}

/// A pair of edges of the two operands and their lines' nearest points (`edgeEdge`): the
/// parameters along each, the distance between them and the point halfway.
const Crossing = struct {
    ea: types.EdgeIndex,
    eb: types.EdgeIndex,
    closest: [2]f64,
    gap: f64,
    mid: Vec3,

    /// Nearer first; the sort (a block sort, stable) keeps pairs as near in their order.
    fn nearer(_: void, x: Crossing, y: Crossing) bool {
        return x.gap < y.gap;
    }
};

/// An edge of operand `k` whose ends lie either side of the plane of face `f` of the
/// other, for edge–face: `steep` is the sine of the angle the edge crosses the plane at.
const Piercing = struct {
    k: usize,
    e: types.EdgeIndex,
    f: types.FaceIndex,
    steep: f64,

    /// Steeper first; the sort (a block sort, stable) keeps crossings as steep in their
    /// order.
    fn steeper(_: void, x: Piercing, y: Piercing) bool {
        return x.steep > y.steep;
    }
};

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
    /// Each face's box, not grown (the near-coplanar warning grows them by its own reach).
    face_boxes: [2][]Box3 = .{ &.{}, &.{} },
    /// Vertex–face and edge–face incidences found before they are collected.
    found: std.ArrayList(Incidence) = .empty,
    /// Each face's edges in trees, built the first time `placeIn` asks of a face with many
    /// (`face_edges.INDEXED_AT_LEAST`); null for a face scanned edge by edge.
    indexed: [2]std.AutoHashMapUnmanaged(u32, ?face_edges.FaceEdges) = .{ .empty, .empty },

    fn deinit(self: *Filler) void {
        for (&self.indexed) |*map| {
            var it = map.valueIterator();
            while (it.next()) |entry| if (entry.*) |*index| index.deinit(self.allocator);
            map.deinit(self.allocator);
        }
        for (0..2) |k| {
            self.allocator.free(self.edges[k]);
            self.allocator.free(self.faces[k]);
            self.edge_tree[k].deinit(self.allocator);
            self.face_tree[k].deinit(self.allocator);
            self.allocator.free(self.face_boxes[k]);
        }
        self.found.deinit(self.allocator);
    }

    fn body(self: *const Filler, k: usize) *const Body {
        return self.p.operands[k];
    }

    // --- vertex–vertex ---

    /// Every vertex of `a` a merged vertex of its own; each of `b`'s merged with the first
    /// of `a`'s within the tolerance and both their gaps (the sum of tolerances every other
    /// class reaches by, and the overlap rules: research/consistent-tolerances.md's gapped
    /// corner, 2.3e-5 under another with a gap of 6.4e-6 at a tolerance of 2e-5, was left
    /// unmerged and then found on that corner's edges at its end), else one of its own.
    /// Merged vertices take the centre of their points' box, their gap reaching the
    /// furthest.
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
        // `a`'s points in a grid wide enough for the tolerance and two gaps, each at most the
        // zone (a ball past it is refused below)
        var near = grid.Grid.init(2 * (p.tol.xsect + p.tol.zone + p.rounding));
        defer near.deinit(self.allocator);
        for (p.points.items, 0..) |q, i| near.insert(self.allocator, @intCast(i), q) catch |e| return welderError(self.diag, e);
        const b = self.body(1);
        // The points each merged vertex of `a` took from `b`, to place it once all are in
        var taken: std.ArrayList([2]u32) = .empty;
        defer taken.deinit(self.allocator);
        for (b.vertices.items, 0..) |v, i| {
            if (v.tombstone) continue;
            const q = b.point(types.VertexIndex.of(i));
            if (try self.mergedWith(&near, q, v.gap)) |found| {
                p.vertex_of[1][i] = found;
                p.owners.items[found] |= 2;
                try taken.append(self.allocator, .{ found, @intCast(i) });
                self.tally();
                continue;
            }
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
            // The ball is the result's vertex's gap, which the zone bounds (§6): vertices
            // merged from gaps a chain recorded, or two exactly the tolerance apart (half of
            // it is the zone, and the centre's rounding is past it), are refused here, the
            // vertex named, never a result the checker then fails (2026-11-13)
            if (gap > p.tol.zone) return self.diag.fail(error.Degenerate, .{ .code = .gap_too_large, .entity = .of(.vertex, @backingInt(own_index)), .label = "vertex–vertex: the first operand's vertex merged with the second's", .measured = gap, .threshold = p.tol.zone });
            p.points.items[m] = centre;
            p.gaps.items[m] = gap;
            start = end;
        }
        // The welder holds the moved points
        p.welder.deinit(self.allocator);
        p.welder = grid.PointWelder.initWithMargin(p.tol.xsect, p.rounding);
        for (0..p.points.items.len) |i| try self.register(@intCast(i));
    }

    /// The first of `a`'s merged vertices (all of them in `near`) within the intersection
    /// tolerance and both gaps of `q`, a vertex of `b` with gap `gap`; one at that reach to
    /// rounding is refused (D27).
    fn mergedWith(self: *Filler, near: *const grid.Grid, q: Vec3, gap: f64) Error!?u32 {
        const p = self.p;
        const Search = struct {
            p: *const Paves,
            q: Vec3,
            gap: f64,
            best: u32 = NONE,
            at: u32 = NONE,
            fn visit(s: *@This(), i: u32) bool {
                switch (s.p.decide.merged(vec.distance(s.p.points.items[i], s.q), s.p.gaps.items[i], s.gap)) {
                    .same => s.best = @min(s.best, i),
                    .at_tolerance => s.at = @min(s.at, i),
                    .apart => {},
                }
                return true;
            }
        };
        var search: Search = .{ .p = p, .q = q, .gap = gap };
        near.query(q, p.tol.xsect + p.tol.zone + p.rounding, &search, Search.visit) catch |e| return welderError(self.diag, e);
        if (search.at != NONE) return self.atTolerance(vec.distance(p.points.items[search.at], q), p.tol.xsect + p.gaps.items[search.at] + gap, .of(.vertex, search.at));
        return if (search.best == NONE) null else search.best;
    }

    fn addPoint(self: *Filler, q: Vec3, gap: f64, owners: u2) Error!u32 {
        const p = self.p;
        const index: u32 = @intCast(p.points.items.len);
        try p.points.append(self.allocator, q);
        try p.gaps.append(self.allocator, gap);
        try p.reach.append(self.allocator, 0);
        try p.owners.append(self.allocator, owners);
        try self.register(index);
        return index;
    }

    /// The first merged vertex within the tolerance of `q`.
    fn find(self: *Filler, q: Vec3) Error!?u32 {
        const points = self.p.points.items;
        if (self.p.welder.atRadius(points, q) catch |e| return welderError(self.diag, e)) |at| {
            return self.atTolerance(vec.distance(points[at], q), self.p.tol.xsect, .of(.vertex, at));
        }
        return self.p.welder.find(points, q) catch |e| return welderError(self.diag, e);
    }

    /// `d ≤ limit`: a decision of the tolerance, `limit` the intersection tolerance (and a
    /// gap). A `d` within rounding of `limit` either way is the tolerance to rounding, which
    /// one computation of a configuration finds within and another beyond, so the
    /// operands' topology would disagree with itself: refused (`at_tolerance`), naming
    /// `entity`, as a merged vertex past the zone is.
    fn within(self: *Filler, d: f64, limit: f64, entity: diagnostics.EntityRef) Error!bool {
        return self.settle(self.p.decide.within(d, limit), entity);
    }

    /// A decision's verdict taken: the same holds, apart does not, at the tolerance is
    /// refused naming `entity`. The one place a verdict refuses; a decision of several
    /// parts combines their verdicts first (`canonical.either`, `canonical.both`) and
    /// settles once, so its outcome does not hang on which part was asked first.
    fn settle(self: *Filler, verdict: Verdict, entity: diagnostics.EntityRef) Error!bool {
        return switch (verdict) {
            .same => true,
            .apart => false,
            .at_tolerance => |c| self.atTolerance(c.measured, c.limit, entity),
        };
    }

    /// Whether merged vertex `v` is on `plane`, within its reach of it (`entity` named
    /// when at it to rounding).
    fn onPlane(self: *Filler, plane: Plane, v: u32, entity: diagnostics.EntityRef) Error!bool {
        return self.settle(self.planeVerdict(plane, v), entity);
    }

    /// `onPlane`'s verdict, not yet taken.
    fn planeVerdict(self: *const Filler, plane: Plane, v: u32) Verdict {
        return self.p.onPlane(plane, v);
    }

    /// Merged vertex `v`'s reach: the intersection tolerance and its gap.
    fn reachOf(self: *const Filler, v: u32) f64 {
        return incidence.reach(self.p.tol, self.p.gaps.items[v]);
    }

    /// Edge `e` of operand `k`'s gap: its merged ends' larger (`incidence.edgeGap`), within
    /// which the edge lies of the segment between their points.
    fn edgeGapOf(self: *const Filler, k: usize, e: types.EdgeIndex) f64 {
        const v = self.ends(k, e);
        return incidence.edgeGap(self.p.gaps.items[v[0]], self.p.gaps.items[v[1]]);
    }

    fn atTolerance(self: *Filler, d: f64, limit: f64, entity: diagnostics.EntityRef) Error {
        return self.diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = entity, .label = stageLabel(self.stage.*), .measured = d, .threshold = limit });
    }

    fn register(self: *Filler, i: u32) Error!void {
        self.p.welder.add(self.allocator, self.p.points.items, i) catch |e| return welderError(self.diag, e);
    }

    /// The merged vertex at `q`, a point an intersection of the two features `made_on` made
    /// (edge–edge, edge–face) with gap `gap`: the first within the tolerance, else a new
    /// one. A merged vertex already there stands for the point only within its reach (the
    /// tolerance and its gap) of each of the features, the reach vertex–edge and
    /// vertex–face decide "on" by: one beyond the reach of a feature was made by others
    /// within the tolerance of the point, which come within twice the tolerance of the
    /// feature where they do not meet it. Refused (`below_feature_size`), naming the
    /// feature, never a pave the feature's own reach denies. The solids fuzzer
    /// (2026-11-14): a hull's edge 1.9e-5 from a plate's top edge and 1.8e-6 from its
    /// bottom one, 2.5e-5 below, at a tolerance of 2e-5: the top crossing welded to the
    /// bottom one's vertex, the top edge's piece ending 2.56e-5 off its line. A new one
    /// whose gap would pass the zone is refused (`gap_too_large`), as vertex–vertex refuses
    /// a ball past it: two edges meet within the tolerance and their gaps
    /// (`incidence.Decider.edgesMeet`), and their crossing halfway can lie farther than the
    /// zone from both (the edge-case matrix, 2026-11-16: a box's corners 5e-5 under its
    /// top, its edge 2.3e-4 under another box's at a tolerance of 2e-4, welded a vertex
    /// 1.15e-4 from each, the union past the zone).
    fn weld(self: *Filler, q: Vec3, gap: f64, made_on: [2]Feature) Error!u32 {
        const found = try self.find(q) orelse {
            if (gap > self.p.tol.zone) return self.diag.fail(error.Degenerate, .{ .code = .gap_too_large, .entity = made_on[0].entity(), .label = stageLabel(self.stage.*), .measured = gap, .threshold = self.p.tol.zone });
            return self.addPoint(q, gap, 0);
        };
        const reach = self.reachOf(found);
        for (made_on) |feature| {
            const beyond = try self.beyondReach(found, reach, feature) orelse continue;
            const first = feature.operand() == 0;
            return self.diag.fail(error.Degenerate, .{
                .code = .below_feature_size,
                .entity = feature.entity(),
                .label = switch (feature) {
                    .edge => if (first) "an edge of the first operand and the vertex its crossing merged with," else "an edge of the second operand and the vertex its crossing merged with,",
                    .face => if (first) "a face of the first operand and the vertex its crossing merged with," else "a face of the second operand and the vertex its crossing merged with,",
                },
                .measured = beyond,
                .threshold = reach,
            });
        }
        return found;
    }

    /// How far merged vertex `v` lies from `feature` when beyond `reach` of it, as
    /// vertex–edge and vertex–face decide (a face: its plane, then its boundary for a
    /// vertex outside it); null within reach.
    fn beyondReach(self: *Filler, v: u32, reach: f64, feature: Feature) Error!?f64 {
        const point = self.p.point(v);
        switch (feature) {
            .edge => |e| {
                const distance = self.edgeDistance(e.k, e.e, point);
                return if (try self.within(distance, reach + self.edgeGapOf(e.k, e.e), feature.entity())) null else distance;
            },
            .face => |f| {
                const operand = self.body(f.k);
                const plane = planar_faces.planeOf(planar_faces.frameOf(operand, f.f).?);
                // Beyond the plane or outside the face settles it whatever the other, as
                // `placeOnFace` decides; at the plane's reach to rounding inside, refused
                const height = @abs(plane.height(point));
                const verdict = self.p.decide.within(height, reach);
                if (verdict == .apart) return height;
                if (try self.placeIn(f.k, f.f, point, v) == .outside) return try in_face.boundaryDistance(operand, f.f, vec.addScaled(point, plane.n, -plane.height(point)), self.diag);
                _ = try self.settle(verdict, feature.entity());
                return null;
            },
        }
    }

    /// How far `q` lies from edge `e` of operand `k`, the segment between its merged ends.
    fn edgeDistance(self: *const Filler, k: usize, e: types.EdgeIndex, q: Vec3) f64 {
        const v = self.ends(k, e);
        const p0 = self.p.point(v[0]);
        const d = vec.sub(self.p.point(v[1]), p0);
        const len_sq = vec.lengthSq(d);
        const s = if (len_sq == 0) 0 else std.math.clamp(vec.dot(vec.sub(q, p0), d) / len_sq, 0, 1);
        return vec.distance(q, vec.addScaled(p0, d, s));
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
            var plain: std.ArrayList(Box3) = .empty;
            defer plain.deinit(self.allocator);
            boxes.clearRetainingCapacity();
            var shells = traverse.Shells.init(body_k);
            while (shells.next() catch return corrupt(self.diag)) |s| {
                var it = traverse.Faces.init(body_k, s);
                while (it.next() catch return corrupt(self.diag)) |f| {
                    try faces.append(self.allocator, f);
                    const box = bbox.faceBounds(body_k, f) catch return corrupt(self.diag);
                    try plain.append(self.allocator, box);
                    try boxes.append(self.allocator, box.inflated(2 * xsect));
                }
            }
            self.faces[k] = try faces.toOwnedSlice(self.allocator);
            self.face_boxes[k] = try plain.toOwnedSlice(self.allocator);
            self.face_tree[k] = try Bvh.build(self.allocator, boxes.items);
        }
    }

    /// Edge `e` of operand `k` as its merged ends.
    fn ends(self: *const Filler, k: usize, e: types.EdgeIndex) [2]u32 {
        const edge = self.body(k).edge(e);
        return .{ self.p.vertex_of[k][@backingInt(edge.start)], self.p.vertex_of[k][@backingInt(edge.end)] };
    }

    /// Where `q` lies against face `f` of operand `k`, decided as the paves decide: a merged
    /// vertex `v` that is a pave of one of the face's edges is on its boundary (vertex–edge
    /// decided it); else on the boundary within the intersection tolerance (and `v`'s gap)
    /// of it, at it to rounding refused (D27), and otherwise inside or outside by the
    /// face's winding. `planar_faces.place` decided this again at the zone, so a vertex
    /// between the zone and the tolerance of an edge was the edge's pave and "inside" the
    /// face, a touch (the research review, 2026-11-14: one decision, one place).
    fn placeIn(self: *Filler, k: usize, f: types.FaceIndex, q: Vec3, v: ?u32) Error!in_face.Place {
        return switch (try self.placedIn(k, f, q, v)) {
            .inside => .inside,
            .outside => .outside,
            .boundary => .boundary,
            .at_tolerance => |c| self.atTolerance(c.measured, c.limit, .of(.face, @backingInt(f))),
        };
    }

    /// `placeIn`'s answer not yet taken: at the tolerance a verdict, for a decision of two
    /// faces to settle together (`placeInBoth`).
    fn placedIn(self: *Filler, k: usize, f: types.FaceIndex, q: Vec3, v: ?u32) Error!in_face.Placed {
        if (v) |m| if (self.paveOfFace(k, f, m)) return .boundary;
        return in_face.placeWithin(self.p.decide, self.body(k), f, q, if (v) |m| self.p.gaps.items[m] else 0, try self.edgesOf(k, f), self.diag);
    }

    /// Where `q` lies against face `fa` of the first operand and face `fb` of the second,
    /// or null when it is outside either: outside one settles it whatever the other, at the
    /// tolerance too, so the two are asked before either refuses and the answer is the same
    /// whichever operand comes first (Kleene's strong "and", as `canonical.both`). A section
    /// segment's middle lay outside a hull's face and the tolerance to rounding from an edge
    /// of a wall's: the hull first, it was no part of where the two meet; the wall first,
    /// the union was refused `at_tolerance` (the ReleaseSafe session on e83d2a0e, dl,
    /// 2026-11-22).
    /// `own` the faces whose own pave block `q` is the middle of: on that face's boundary by
    /// the paves' record, not measured (`ownBlock`).
    fn placeInBoth(self: *Filler, fa: types.FaceIndex, fb: types.FaceIndex, q: Vec3, own: [2]bool) Error!?[2]in_face.Place {
        const placed = [2]in_face.Placed{
            if (own[0]) .boundary else try self.placedIn(0, fa, q, null),
            if (own[1]) .boundary else try self.placedIn(1, fb, q, null),
        };
        if (placed[0] == .outside or placed[1] == .outside) return null;
        var places: [2]in_face.Place = undefined;
        for (placed, [2]types.FaceIndex{ fa, fb }, &places) |one, f, *place| place.* = switch (one) {
            .inside => .inside,
            .boundary => .boundary,
            .outside => unreachable,
            .at_tolerance => |c| return self.atTolerance(c.measured, c.limit, .of(.face, @backingInt(f))),
        };
        return places;
    }

    /// Where merged vertex `v` lies on face `f` of operand `k` (`plane` its plane): null
    /// when beyond its reach of the plane or outside the face, either settling it whatever
    /// the other; else its place (`placeIn`). At its reach of the plane to rounding it is
    /// refused only where the height decides, inside the face or on its boundary. One
    /// decision for vertex–face, edge–face's paves and the feature-size rule: each asked the
    /// plane first and refused a vertex at its reach of it over the notch of an L-shaped
    /// face, outside it (step 1 of closing M4, order symmetry).
    fn placeOnFace(self: *Filler, k: usize, f: types.FaceIndex, plane: Plane, v: u32) Error!?in_face.Place {
        const at = try self.faceVerdict(k, f, plane, v);
        return if (try self.settle(at.on, .of(.face, @backingInt(f)))) at.place else null;
    }

    /// `placeOnFace`'s verdict, not yet taken (a decision of several vertices combines
    /// theirs first, `canonical.either`), with the place where it is not apart.
    fn faceVerdict(self: *Filler, k: usize, f: types.FaceIndex, plane: Plane, v: u32) Error!struct { on: Verdict, place: in_face.Place } {
        const height = self.planeVerdict(plane, v);
        if (height == .apart) return .{ .on = .apart, .place = .outside };
        const place = try self.placeIn(k, f, self.p.point(v), v);
        return .{ .on = if (place == .outside) .apart else height, .place = place };
    }

    /// Face `f` of operand `k`'s edges in trees, when it has many; built on first asking.
    /// Their reach is the farthest `placeIn` asks: the tolerance, a gap (the zone at most)
    /// and D27's band.
    fn edgesOf(self: *Filler, k: usize, f: types.FaceIndex) Error!?*const face_edges.FaceEdges {
        const entry = try self.indexed[k].getOrPut(self.allocator, @backingInt(f));
        if (!entry.found_existing) {
            entry.value_ptr.* = null;
            var count: usize = 0;
            var loops = traverse.Loops.init(self.body(k), f);
            while (loops.next() catch return corrupt(self.diag)) |l| {
                var it = traverse.Coedges.init(self.body(k), l);
                while (it.next() catch return corrupt(self.diag)) |_| count += 1;
            }
            if (count >= face_edges.INDEXED_AT_LEAST) {
                const p = self.p;
                entry.value_ptr.* = try face_edges.FaceEdges.build(self.allocator, self.body(k), f, p.tol.xsect + p.tol.zone + p.rounding, self.diag);
            }
        }
        return if (entry.value_ptr.*) |*index| index else null;
    }

    /// Whether merged vertex `v` is a pave of an edge of face `f` of operand `k`.
    fn paveOfFace(self: *const Filler, k: usize, f: types.FaceIndex, v: u32) bool {
        const operand = self.body(k);
        var loops = traverse.Loops.init(operand, f);
        while (loops.next() catch null) |l| {
            if (operand.loop(l).vertex != .none and self.p.vertex_of[k][@backingInt(operand.loop(l).vertex)] == v) return true;
            var it = traverse.Coedges.init(operand, l);
            while (it.next() catch null) |c| if (self.hasPave(k, operand.coedge(c).edge, v)) return true;
        }
        return false;
    }

    /// Whether edge `ea` of the first operand and edge `eb` of the second have a merged
    /// vertex among both their paves (their ends among them).
    fn sharePave(self: *const Filler, ea: types.EdgeIndex, eb: types.EdgeIndex) bool {
        for (self.p.edge_paves[0][@backingInt(ea)].items) |pave| if (self.hasPave(1, eb, pave.vertex)) return true;
        return false;
    }

    fn hasPave(self: *const Filler, k: usize, e: types.EdgeIndex, v: u32) bool {
        for (self.p.edge_paves[k][@backingInt(e)].items) |pave| if (pave.vertex == v) return true;
        return false;
    }

    /// Where `q` lies along edge `e` of operand `k` (null for an edge of no length): its
    /// parameter from start (0) to end (1), its distance from the edge's line, and whether
    /// its foot is in an end's strip, outside the edge's shrunk range (OCCT's
    /// `IntTools_ShrunkRange`): within the intersection tolerance and the end's gap of
    /// either end, where the end's ball holds it. `short` is whether the shrunk range is
    /// shorter than twice the tolerance: a pave there would leave a piece too short to be
    /// an edge. Both are distances decided as every distance here is (D27): a foot at a
    /// strip's bound to rounding was a pave or the strip's refusal by the rounding a
    /// placement moved (the 10K session on 6007ab01, 2026-11-18: a hull's corner 1e-17
    /// from the bound of a box edge's strip).
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
        const hi = xsect + self.p.gaps.items[v[1]];
        return .{
            .s = s,
            .distance = vec.distance(q, vec.addScaled(p0, d, s)),
            .strip = canonical.either(self.p.decide.within(s * len, lo), self.p.decide.within((1 - s) * len, hi)),
            .short = self.p.decide.within(len - lo - hi, 2 * xsect),
        };
    }

    const Along = struct { s: f64, distance: f64, strip: Verdict, short: Verdict };

    /// Whether `at`, a point on edge `e` (within its reach of it), is in an end's strip;
    /// refused at a strip's bound to rounding, where a pave and the strip's refusal hang on
    /// the rounding.
    fn inStrip(self: *Filler, at: Along, e: types.EdgeIndex) Error!bool {
        return self.settle(at.strip, .of(.edge, @backingInt(e)));
    }

    /// Merged vertex `v`, not an end of edge `e` of operand `k`, within the tolerance and
    /// its gap of the edge with its foot in an end's strip (`along`'s, where the end's ball
    /// keeps the edge from being split): too near the end to split the edge at, too far
    /// from it to be it. Refused (`TooSmallEdge`, as an edge too short to split; OCCT
    /// validates its pave blocks after splitting), never skipped: the faces about the edge
    /// would meet it where the edge has no vertex (a tetrahedron's apex 1.5e-5 up a box's
    /// edge from its end and 1.5e-5 off it, at a tolerance of 2e-5: a fragment's loop split
    /// where the interferences found no point).
    fn endStrip(self: *Filler, k: usize, e: types.EdgeIndex, v: u32) Error!void {
        const at_ends = self.ends(k, e);
        if (v == at_ends[0] or v == at_ends[1]) return;
        return self.stripAt(k, e, self.p.point(v), self.reachOf(v));
    }

    /// `endStrip` for a point `q` reaching `reach`, not yet a merged vertex: refused when
    /// within its reach and the edge's gap of edge `e` of operand `k` with its foot in an
    /// end's strip.
    fn stripAt(self: *Filler, k: usize, e: types.EdgeIndex, q: Vec3, reach: f64) Error!void {
        const at_ends = self.ends(k, e);
        const p0 = self.p.point(at_ends[0]);
        const d = vec.sub(self.p.point(at_ends[1]), p0);
        const len_sq = vec.lengthSq(d);
        if (len_sq == 0) return;
        const s = vec.dot(vec.sub(q, p0), d) / len_sq;
        if (s < 0 or s > 1) return;
        const off = vec.distance(q, vec.addScaled(p0, d, s));
        if (!try self.within(off, reach + self.edgeGapOf(k, e), .of(.edge, @backingInt(e)))) return;
        const len = @sqrt(len_sq);
        return self.diag.fail(error.TooSmallEdge, .{ .code = .edge_too_short, .entity = .of(.edge, @backingInt(e)), .label = tooSmallLabel(k, self.stage.*), .measured = @min(s, 1 - s) * len, .threshold = self.p.tol.xsect });
    }

    /// Merged vertex `v` as a pave of edge `e` of operand `k` at `at`; `TooSmallEdge`,
    /// naming the edge, when the edge cannot be split.
    fn addPave(self: *Filler, k: usize, e: types.EdgeIndex, v: u32, at: Along) Error!void {
        if (try self.settle(at.short, .of(.edge, @backingInt(e)))) return self.diag.fail(error.TooSmallEdge, .{ .code = .edge_too_short, .entity = .of(.edge, @backingInt(e)), .label = tooSmallLabel(k, self.stage.*), .measured = vec.distance(self.p.point(self.ends(k, e)[0]), self.p.point(self.ends(k, e)[1])), .threshold = 4 * self.p.tol.xsect });
        try self.p.edge_paves[k][@backingInt(e)].append(self.allocator, .{ .vertex = v, .s = at.s });
        self.p.reach.items[v] = @max(self.p.reach.items[v], at.distance);
        self.tally();
    }

    /// One interference of the class under way found.
    fn tally(self: *Filler) void {
        self.p.found[interferenceIndex(self.stage.*)] += 1;
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
    /// tolerance, its gap and the edge's: `incidence.Decider.onEdge`), but `skip`.
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
        // The trees' boxes are grown by the tolerance; the vertex reaches by its gap too
        self.edge_tree[k].query(Box3.ofPoint(q).inflated(self.p.gaps.items[v]), &collect, Collect.visit);
        if (collect.count == collect.out.len) return self.diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "edges near one vertex", .measured = @floatFromInt(collect.count) });
        std.mem.sort(u32, collect.out[0..collect.count], {}, std.sort.asc(u32));
        for (collect.out[0..collect.count]) |item| {
            const e = self.edges[k][item];
            if (skip != null and skip.? == e) continue;
            if (self.hasPave(k, e, v)) continue;
            const at = self.along(k, e, q) orelse continue;
            // In an end's strip `endStrip` asks whether the vertex is on the edge; elsewhere
            // it is asked first, so that only a vertex on the edge is refused at a strip's
            // bound
            if (at.strip != .same and !try self.within(at.distance, self.reachOf(v) + self.edgeGapOf(k, e), .of(.edge, @backingInt(e)))) continue;
            if (try self.inStrip(at, e)) try self.endStrip(k, e, v) else try self.addPave(k, e, v, at);
        }
    }

    // --- edge–edge ---

    /// Every pair of edges of `a` and `b` crossing within the tolerance and both edges'
    /// gaps (`incidence.Decider.edgesMeet`: by the tolerance alone, a box's edge between
    /// corners with gaps of 3.5e-5, its face in another's plane by those gaps, was apart
    /// from an edge of that face crossing it 2.15e-4 off at a tolerance of 2e-4, and the
    /// crossing was put on the face beside it, not on the edge: the 10K session,
    /// 2026-11-16), away from their ends, gives a merged vertex on both, tried against
    /// every other edge too. Two
    /// straight edges meet once: a pave both already have (an end on the other edge,
    /// vertex–edge's; ends merged, vertex–vertex's; an earlier crossing) is where they
    /// meet, however far the computed crossing is from it, as edge–face takes a pave the
    /// edge has on the face. At a shallow angle two edges stay within the tolerance of
    /// each other along a stretch many times it (`xsect / sin θ`), and a second vertex
    /// there made the faces about them meet twice (the solids fuzzer, 2026-11-16: a box's
    /// corner on a plate's edge, the box's edge along it at 0.007 rad, crossing it again
    /// 0.0044 on; the result's faces passed through each other). A crossing in an end's
    /// strip is then one the end does not stand for (the two would share it): refused as
    /// `endStrip` refuses it, never skipped, which left the place to whichever of
    /// edge–face's crossings came first (the locus fuzzer, the same day: a hull's corner
    /// 2.2e-4 from a plate's edge, its edge passing the plate's 9.8e-5 away 2e-4 from the
    /// corner, made one way round and refused the other). The pairs are taken nearest
    /// first (by the distance between their lines; pairs as near in their order): which
    /// crossing becomes the merged vertex, and which others then share it, is the nearest
    /// meeting's, the least uncertain, never the edges' numbering. In the numbering's
    /// order a near miss came first and stood for the meeting: a tetrahedron's apex
    /// 2.5e-5 from a hull's edge, one of its edges crossing that edge exactly and two
    /// others passing it 6.9e-6 and 1.6e-5 away; the exact crossing first, the others
    /// shared its vertex and the union was made, the two near misses first (the solids
    /// mirrored, the hull's edges numbered otherwise), two vertices 2.24e-5 apart and the
    /// union refused `below_feature_size` (cg's family, cj, 2026-11-22). OCCT merges the
    /// new vertices whose tolerances meet into one at their box's centre
    /// (`BOPAlgo_PaveFiller::TreatNewVertices`), growing its tolerance; with the
    /// tolerance fixed that vertex's gap passed the zone, and both refused.
    fn edgeEdge(self: *Filler) Error!void {
        var pairs = try self.overlapping(&self.edge_tree[0], &self.edge_tree[1]);
        defer pairs.deinit(self.allocator);
        // Each pair's lines' nearest points, then the pairs taken nearest first
        var candidates: std.ArrayList(Crossing) = .empty;
        defer candidates.deinit(self.allocator);
        try candidates.ensureTotalCapacity(self.allocator, pairs.items.len);
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
            candidates.appendAssumeCapacity(.{ .ea = ea, .eb = eb, .closest = closest, .gap = vec.distance(c0, c1), .mid = vec.lerp(c0, c1, 0.5) });
        }
        std.mem.sort(Crossing, candidates.items, {}, Crossing.nearer);
        for (candidates.items) |candidate| {
            const ea = candidate.ea;
            const eb = candidate.eb;
            if (self.sharePave(ea, eb)) continue;
            const closest = candidate.closest;
            const gap = candidate.gap;
            const mid = candidate.mid;
            const at_a = self.along(0, ea, mid) orelse continue;
            const at_b = self.along(1, eb, mid) orelse continue;
            const off = closest[0] < 0 or closest[0] > 1 or closest[1] < 0 or closest[1] > 1;
            // Off either segment the lines' crossing is no meeting whatever its gap (where
            // an end is near the other edge, vertex–edge decided it), so its gap is not
            // asked: at the tolerance to rounding 99 units past a box's edge, it refused a
            // union the box's edge lay inside (the 10K session on 0fce3ff4, at)
            if (canonical.either(at_a.strip, at_b.strip) != .apart and off) continue;
            if (!try self.within(gap, self.p.tol.xsect + self.edgeGapOf(0, ea) + self.edgeGapOf(1, eb), .of(.edge, @backingInt(ea)))) continue;
            // On both segments: in an end's strip refused
            const reach = incidence.reach(self.p.tol, gap / 2);
            var in_strip = false;
            for ([2]usize{ 0, 1 }, [2]types.EdgeIndex{ ea, eb }, [2]Along{ at_a, at_b }) |k, e, at| {
                if (!try self.inStrip(at, e)) continue;
                try self.stripAt(k, e, mid, reach);
                in_strip = true;
            }
            if (in_strip) continue;
            const v = try self.weld(mid, gap / 2, .{ .{ .edge = .{ .k = 0, .e = ea } }, .{ .edge = .{ .k = 1, .e = eb } } });
            for ([2]usize{ 0, 1 }, [2]types.EdgeIndex{ ea, eb }) |k, e| {
                if (self.hasPave(k, e, v)) continue;
                const at = self.along(k, e, self.p.point(v)) orelse continue;
                if (try self.inStrip(at, e)) continue;
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
        const near = try self.facesNear(k, q, self.p.gaps.items[v]);
        for (near.items[0..near.count]) |item| {
            const f = self.faces[k][item];
            const frame = planar_faces.frameOf(self.body(k), f).?;
            const place = try self.placeOnFace(k, f, planar_faces.planeOf(frame), v) orelse continue;
            self.p.reach.items[v] = @max(self.p.reach.items[v], @abs(planar_faces.planeOf(frame).height(q)));
            try self.foundOn(k, f, v, place);
        }
    }

    /// Merged vertex `v` found on face `f` of operand `k` at `place` (inside it or on its
    /// boundary): an incidence, and strictly inside the face a touch (`Paves.touches`),
    /// whichever stage found it. A vertex of the other operand there, or crossings of its
    /// edges merged into one there: a tetrahedron's tip just over the intersection
    /// tolerance (2e-4) past a box's top, its three edges' crossings one merged vertex and
    /// no section on the top, left the difference's pocket touching the top at that point
    /// (the 10K session on 600148f2).
    fn foundOn(self: *Filler, k: usize, f: types.FaceIndex, v: u32, place: in_face.Place) Error!void {
        try self.found.append(self.allocator, .{ .face = .{ .operand = @intCast(k), .face = @backingInt(f) }, .vertex = v });
        self.tally();
        if (place == .inside) try self.p.touches.append(self.allocator, .{ .operand = @intCast(k), .face = @backingInt(f), .vertex = v });
    }

    /// The faces of operand `k` whose boxes, grown by the tolerance, are within `gap` of
    /// `q` (a vertex reaches by its gap beyond the tolerance: a box grown by the tolerance
    /// alone held a vertex or not by the face's turn, and a rigid move changed a decision).
    fn facesNear(self: *Filler, k: usize, q: Vec3, gap: f64) Error!NearFaces {
        var near: NearFaces = .{};
        self.face_tree[k].query(Box3.ofPoint(q).inflated(gap), &near, NearFaces.visit);
        if (near.count == near.items.len) return self.diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "faces near one vertex", .measured = @floatFromInt(near.count) });
        return near;
    }

    /// Every merged vertex against the faces of either operand near it (the minimum feature
    /// size, architecture §3; Hoffmann p.117: tests within a tolerance are not transitive).
    /// A vertex within the intersection tolerance and its gap of two faces of one operand,
    /// each inside it or on its boundary, must be within that reach of where the two meet,
    /// an edge or a vertex of both: else the two faces come within the tolerance of each
    /// other away from where they meet, features closer than twice the tolerance, and no
    /// decision of the tolerance makes them consistent. Refused (`below_feature_size`). The
    /// solids fuzzer (2026-11-14): a hull's wedge 42° open at its edge, the edge 3e-4 under
    /// a plate's bottom at an intersection tolerance of 2e-4, the plate's edge crossing one
    /// side 1.87e-4 from the other's plane (on one side, inside the other: the sections of
    /// the two ran through one vertex the tolerance from where either truly crosses, or the
    /// result had a vertex on a face it does not touch); and a box's corner 1e-5 from a
    /// plate's front and 2e-4 less a hair from its side, near the boundary of each in its
    /// own plane but 2.0025e-4 from the edge between them (the faces' imprints disagreed).
    /// So too a vertex inside a face by its distance from the face's boundary but within
    /// reach of the boundary by its foot on the face's plane: the face's imprint, in that
    /// plane, has it on the boundary (the box's corner 1e-5 from the plate's side's edge
    /// there, and its edge imprinted on the side then welded onto that edge).
    fn featureSize(self: *Filler) Error!void {
        const p = self.p;
        for (0..p.points.items.len) |i| {
            const v: u32 = @intCast(i);
            const q = p.point(v);
            const reach = self.reachOf(v);
            for (0..2) |k| {
                const near = try self.facesNear(k, q, p.gaps.items[v]);
                var on: [near.items.len]types.FaceIndex = undefined;
                var count: usize = 0;
                for (near.items[0..near.count]) |item| {
                    const f = self.faces[k][item];
                    const place = try self.placeOnFace(k, f, planar_faces.planeOf(planar_faces.frameOf(self.body(k), f).?), v) orelse continue;
                    if (place == .inside) {
                        const plane = planar_faces.planeOf(planar_faces.frameOf(self.body(k), f).?);
                        const foot = vec.addScaled(q, plane.n, -plane.height(q));
                        const from_foot = try in_face.boundaryDistance(self.body(k), f, foot, self.diag);
                        if (try self.within(from_foot, reach, .of(.face, @backingInt(f)))) return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = .of(.face, @backingInt(f)), .label = if (k == 0) "a vertex inside a face of the first operand, and the face's boundary by the vertex's foot on its plane," else "a vertex inside a face of the second operand, and the face's boundary by the vertex's foot on its plane,", .measured = from_foot, .threshold = reach });
                    }
                    on[count] = f;
                    count += 1;
                }
                for (on[0..count], 0..) |a, x| for (on[x + 1 .. count]) |b| {
                    if (try self.meetAt(k, a, b, v)) continue;
                    return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = .of(.face, @backingInt(b)), .label = if (k == 0) "two faces of the first operand within reach of one vertex," else "two faces of the second operand within reach of one vertex,", .threshold = reach });
                };
            }
        }
    }

    /// Every pave block against the knife pairs of the other operand near it: two faces
    /// parallel within the angular tolerance and facing apart (`knifePair`, `sandwiched`'s
    /// pair), the material between them thinner than twice the tolerance over a band as
    /// wide as their small angle makes it. `featureSize` asks it of merged vertices, and a
    /// block can pass it with both ends clear while its middle runs inside the band. The
    /// stretch of the block within its reach of both planes, its feet inside both faces,
    /// must end within that reach of where the two meet (an edge or a vertex of both):
    /// beyond it the block lies within the tolerance of both away from where they meet, and
    /// no decision of the tolerance makes the two consistent (the minimum feature size;
    /// the 10K session on a5301ce8, 2026-11-18: a hull's bottom edge through a flat
    /// tetrahedron 2.1 tolerances thick at its middle, its faces meeting at 6e-5 rad, the
    /// edge within the tolerance of its bottom and, 0.23 from the knife edge, of its top;
    /// the union's notch in the hull's face between the edge and its section with the top
    /// as narrow as that, touching the bottom, `pinched`). Two faces at a wider angle are
    /// not asked: the reaches of their planes meet in a region about their line some
    /// reaches across at any angle (√2 of the reach at a right angle), which is where they
    /// meet, not a feature. Nor are two that meet nowhere: two faces of one solid are the
    /// operand precondition's (`pipeline.featureSize`: twice the tolerance apart), two
    /// solids of one operand touching face to face hold no material between them, and a
    /// block's gap must not make a plate past the precondition thin (a hull's edge across
    /// a plate 2.1 tolerances thick, its reach widened by its ends' gaps, is made). A face
    /// crossing a knife steeply with no block there is made (its sections leave the knife
    /// edge within the angle of each other, which the imprint holds: a knife-edge wedge cut
    /// into a box). Decided over every block of both
    /// operands before any refusal, so neither order nor the first block asked decides
    /// which: refused (`below_feature_size`) when any block's stretch ends beyond the
    /// reach, else at the reach to rounding (`at_tolerance`, D27), each naming the block's
    /// edge.
    fn knifeBlocks(self: *Filler) Error!void {
        const p = self.p;
        var scratch: Stretch = .{};
        defer scratch.deinit(self.allocator);
        var beyond: ?diagnostics.Finding = null;
        var at: ?diagnostics.Finding = null;
        for (0..2) |k| {
            const other = 1 - k;
            const body_k = self.body(k);
            for (body_k.edges.items, 0..) |edge, ei| {
                if (edge.flags.tombstone or edge.flags.degenerate or edge.coedge == .none or edge.curve.kind != .line) continue;
                const list = p.edge_paves[k][ei].items;
                if (list.len < 2) continue;
                for (list[0 .. list.len - 1], list[1..]) |x, y| {
                    const a = p.point(x.vertex);
                    const b = p.point(y.vertex);
                    const gap = incidence.edgeGap(p.gaps.items[x.vertex], p.gaps.items[y.vertex]);
                    const reach = incidence.reach(p.tol, gap);
                    var box = Box3.ofPoint(a);
                    box.grow(b);
                    var near: NearFaces = .{};
                    self.face_tree[other].query(box.inflated(gap), &near, NearFaces.visit);
                    if (near.count == near.items.len) return self.diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "faces near one pave block", .measured = @floatFromInt(near.count) });
                    const entity: diagnostics.EntityRef = .of(.edge, @as(u32, @intCast(ei)));
                    for (near.items[0..near.count], 0..) |item1, n| for (near.items[n + 1 .. near.count]) |item2| {
                        const g1 = self.faces[other][item1];
                        const g2 = self.faces[other][item2];
                        if (!self.knifePair(other, g1, g2)) continue;
                        for (try self.stretchIn(other, .{ g1, g2 }, a, b, reach, &scratch)) |t| {
                            const q = vec.lerp(a, b, t);
                            const from = try self.fromMeeting(other, g1, g2, q);
                            // Meeting nowhere: the operand precondition's pair, or two
                            // solids of one operand touching face to face
                            if (from == std.math.inf(f64)) break;
                            switch (p.decide.within(from, reach)) {
                                .same => {},
                                .apart => if (beyond == null) {
                                    beyond = .{ .code = .below_feature_size, .entity = entity, .label = if (k == 0) "an edge of the first operand within reach of two faces of the second facing apart at an angle within the angular tolerance, away from where they meet," else "an edge of the second operand within reach of two faces of the first facing apart at an angle within the angular tolerance, away from where they meet,", .measured = from, .threshold = reach };
                                },
                                .at_tolerance => |c| if (at == null) {
                                    at = .{ .code = .at_tolerance, .entity = entity, .label = if (k == 0) "an edge of the first operand within reach of two faces of the second facing apart, at the reach of where they meet to rounding" else "an edge of the second operand within reach of two faces of the first facing apart, at the reach of where they meet to rounding", .measured = c.measured, .threshold = c.limit };
                                },
                            }
                        }
                    };
                }
            }
        }
        if (beyond) |d| return self.diag.fail(error.Degenerate, d);
        if (at) |d| return self.diag.fail(error.Degenerate, d);
    }

    /// Whether faces `g1` and `g2` of operand `k` are a knife pair: faces of one shell (two
    /// solids touching hold no material between their faces: OCCT's checkerboard of cubes
    /// meeting at edges, their sides in one plane sharing corners), their planes parallel
    /// within the angular tolerance and the faces facing apart (material between them, not
    /// one side's surface in two faces), as `sandwiched` takes them.
    fn knifePair(self: *Filler, k: usize, g1: types.FaceIndex, g2: types.FaceIndex) bool {
        const body_k = self.body(k);
        if (body_k.face(g1).shell != body_k.face(g2).shell) return false;
        if (!self.p.tol.parallel(planar_faces.frameOf(body_k, g1).?.z, planar_faces.frameOf(body_k, g2).?.z)) return false;
        return vec.dot(in_face.outwardNormal(body_k, g1, .{ 0, 0 }), in_face.outwardNormal(body_k, g2, .{ 0, 0 })) < 0;
    }

    /// The ends of the stretches of the segment from `a` to `b` (as parameters in [0, 1])
    /// within `reach` of the planes of both faces `g` of operand `k`, their feet inside both
    /// (each face's triangles over its merged vertices, boundary included).
    fn stretchIn(self: *Filler, k: usize, g: [2]types.FaceIndex, a: Vec3, b: Vec3, reach: f64, scratch: *Stretch) Error![]const f64 {
        var band: [2]f64 = .{ 0, 1 };
        for (g) |face| {
            const frame = planar_faces.frameOf(self.body(k), face).?;
            const ha = vec.dot(vec.sub(a, frame.origin), frame.z);
            const hb = vec.dot(vec.sub(b, frame.origin), frame.z);
            // reach − h(t) ≥ 0 and reach + h(t) ≥ 0, h affine in t
            band = clip(band, reach - ha, ha - hb);
            band = clip(band, reach + ha, hb - ha);
        }
        scratch.ends.clearRetainingCapacity();
        if (!(band[0] <= band[1])) return scratch.ends.items;
        for (g, &scratch.within) |face, *spans| try self.feetIn(k, face, a, b, band, spans);
        // The spans of both, pairwise (each merged, sorted)
        for (scratch.within[0].items) |s1| for (scratch.within[1].items) |s2| {
            const lo = @max(s1[0], s2[0]);
            const hi = @min(s1[1], s2[1]);
            if (!(lo <= hi)) continue;
            try scratch.ends.appendSlice(self.allocator, &.{ lo, hi });
        };
        return scratch.ends.items;
    }

    /// The parameters in `band` of the segment from `a` to `b` whose feet on face `g`'s
    /// plane lie in one of its triangles, as merged sorted spans, into `out`. A segment along
    /// a triangle's side to rounding (D27's band at the operands' size) is in it: a box's
    /// edge along the side edge of a flat tetrahedron's bottom, within reach of its bottom
    /// and top over a third of its length, was refused in place and made in half the far
    /// moves, where the rounding put the edge outside the side (the audit of fixed
    /// numbers, 2026-11-22).
    fn feetIn(self: *Filler, k: usize, g: types.FaceIndex, a: Vec3, b: Vec3, band: [2]f64, out: *std.ArrayList([2]f64)) Error!void {
        const p = self.p;
        out.clearRetainingCapacity();
        const n = planar_faces.frameOf(self.body(k), g).?.z;
        const corners = try overlap.FaceTriangles.ofFace(self.allocator, self.body(k), g, self.diag);
        defer self.allocator.free(corners);
        for (corners) |t| {
            var q: [3]Vec3 = undefined;
            for (t, &q) |v, *point| point.* = p.point(p.vertex_of[k][@backingInt(v)]);
            const turn = vec.dot(vec.cross(vec.sub(q[1], q[0]), vec.sub(q[2], q[0])), n);
            if (turn == 0) continue;
            const sense: f64 = if (turn > 0) 1 else -1;
            var span = band;
            for (0..3) |i| {
                const from = q[i];
                const side = vec.sub(q[(i + 1) % 3], from);
                // The foot's side of the triangle's edge, affine in t: the normal's part of
                // side × (point − from), the point's height dropping out
                const at_a = sense * vec.dot(vec.cross(side, vec.sub(a, from)), n);
                const at_b = sense * vec.dot(vec.cross(side, vec.sub(b, from)), n);
                // Along the side to rounding, both ends on its line, is inside (the boundary
                // included): such a segment reads 0 at both ends where it is drawn and the
                // coordinates' rounding of either sign moved whole, its span kept, cut or
                // emptied by it. A segment leaving the side is cut where it leaves, exactly
                const on = p.rounding * vec.length(side);
                if (@abs(at_a) <= on and @abs(at_b) <= on) continue;
                span = clip(span, at_a, at_b - at_a);
            }
            if (span[0] <= span[1]) try out.append(self.allocator, span);
        }
        std.mem.sort([2]f64, out.items, {}, lessSpan);
        var merged: usize = 0;
        for (out.items) |s| {
            if (merged > 0 and s[0] <= out.items[merged - 1][1]) {
                out.items[merged - 1][1] = @max(out.items[merged - 1][1], s[1]);
            } else {
                out.items[merged] = s;
                merged += 1;
            }
        }
        out.shrinkRetainingCapacity(merged);
    }

    /// The distance from `q` to where faces `g1` and `g2` of operand `k` meet: an edge of
    /// both, or a vertex of both; infinite when they meet nowhere.
    fn fromMeeting(self: *Filler, k: usize, g1: types.FaceIndex, g2: types.FaceIndex, q: Vec3) Error!f64 {
        const body_k = self.body(k);
        var nearest = std.math.inf(f64);
        var loops = traverse.Loops.init(body_k, g1);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const coedge = body_k.coedge(c);
                if (coedge.partner != .none and body_k.loop(body_k.coedge(coedge.partner).loop).face == g2) nearest = @min(nearest, in_face.edgeDistance(body_k, coedge.edge, q));
                const corner = body_k.coedgeStart(c);
                if (try self.faceHasVertex(k, g2, corner)) nearest = @min(nearest, vec.distance(body_k.point(corner), q));
            }
        }
        return nearest;
    }

    /// Whether faces `a` and `b` of operand `k` meet at merged vertex `m`, as the paves
    /// decided it: `m` a pave of an edge both use (its ends among them), or of an edge of each
    /// that are copies (two solids of the operand touching along a line, each with its own
    /// edge there between the same two vertices: a vertex in the line's middle was taken for
    /// two faces 0 apart that do not meet, and a boolean refused its own result as the next
    /// operand; OCCT's buc60801 as a chain, 2026-11-14), or the merged vertex of a vertex both
    /// use. Measured again (`m` within reach of the edge or the vertex), a second decision of
    /// the same could disagree with the first (D28).
    fn meetAt(self: *Filler, k: usize, a: types.FaceIndex, b: types.FaceIndex, m: u32) Error!bool {
        const body_k = self.body(k);
        var loops = traverse.Loops.init(body_k, a);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            if (body_k.loop(l).vertex != .none and self.p.vertex_of[k][@backingInt(body_k.loop(l).vertex)] == m and try self.faceHasVertex(k, b, body_k.loop(l).vertex)) return true;
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const coedge = body_k.coedge(c);
                // An edge of both: its other coedge in `b`; or an edge of `b` its copy
                if (self.hasPave(k, coedge.edge, m)) {
                    if (coedge.partner != .none and body_k.loop(body_k.coedge(coedge.partner).loop).face == b) return true;
                    if (try self.copyIn(k, b, coedge.edge, m)) return true;
                }
                // A vertex of both
                const corner = body_k.coedgeStart(c);
                if (self.p.vertex_of[k][@backingInt(corner)] == m and try self.faceHasVertex(k, b, corner)) return true;
            }
        }
        return false;
    }

    /// Whether face `f` of operand `k` has an edge, not `e`, between the same two vertices as
    /// `e` (its copy: another solid of the operand touching along it) with `m` a pave of it.
    fn copyIn(self: *Filler, k: usize, f: types.FaceIndex, e: types.EdgeIndex, m: u32) Error!bool {
        const body_k = self.body(k);
        const edge = body_k.edge(e);
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const other = body_k.coedge(c).edge;
                if (other == e) continue;
                const o = body_k.edge(other);
                const same_ends = (o.start == edge.start and o.end == edge.end) or (o.start == edge.end and o.end == edge.start);
                if (same_ends and self.hasPave(k, other, m)) return true;
            }
        }
        return false;
    }

    /// Whether vertex `v` of operand `k` is a corner of face `f`.
    fn faceHasVertex(self: *Filler, k: usize, f: types.FaceIndex, v: types.VertexIndex) Error!bool {
        const body_k = self.body(k);
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            if (body_k.loop(l).vertex == v) return true;
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| if (body_k.coedgeStart(c) == v) return true;
        }
        return false;
    }

    // --- edge–face ---

    /// Every edge of one operand crossing a face of the other, its ends on either side of
    /// the face's plane and neither on the face (an end on the face is vertex–face's, and
    /// the crossing is that end): the crossing, inside the face or on its boundary, a
    /// merged vertex on the edge and the face (one on the face's boundary tried against the
    /// other operand's edges, where edge–edge should have found it). A straight edge meets
    /// a plane once: a pave the edge already has on the face (edge–edge's, where it passes
    /// an edge of the face) is the crossing, however far the computed point is from it. At
    /// a shallow angle the edge stays within the tolerance of the plane along a stretch
    /// many times the tolerance, and a second vertex there made the two faces meet along a
    /// bent chain that both kept, a fold (2026-11-13). The crossings of both operands are
    /// taken steepest first (by the sine of the angle the edge crosses the plane at;
    /// crossings as steep in their order): which crossing becomes the merged vertex, and
    /// which others within the tolerance then share it, is the least uncertain crossing's,
    /// as edge–edge takes its pairs nearest first, never the operands' order or the edges'
    /// numbering. In that order a tetrahedron's apex 3e-5 over a box's top, its three
    /// edges crossing the top within the tolerance of one another, put the intersection's
    /// apex at whichever crossing came first, 5.8e-6 apart as the hull, drawn turned a
    /// quarter or mirrored, numbered its edges (the audit of the ties, finding 6,
    /// 2026-11-25).
    fn edgeFace(self: *Filler) Error!void {
        // Every edge crossing a face's plane, of both operands, then taken steepest first
        var candidates: std.ArrayList(Piercing) = .empty;
        defer candidates.deinit(self.allocator);
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
                if ((h0 < 0) == (h1 < 0)) continue;
                try candidates.append(self.allocator, .{ .k = k, .e = e, .f = f, .steep = @abs(h0 - h1) / vec.distance(p0, p1) });
            }
        }
        std.mem.sort(Piercing, candidates.items, {}, Piercing.steeper);
        for (candidates.items) |candidate| {
            const k = candidate.k;
            const other = 1 - k;
            const e = candidate.e;
            const f = candidate.f;
            const v = self.ends(k, e);
            const p0 = self.p.point(v[0]);
            const p1 = self.p.point(v[1]);
            const plane = planar_faces.planeOf(planar_faces.frameOf(self.body(other), f).?);
            const h0 = plane.height(p0);
            const h1 = plane.height(p1);
            // An end on the face is vertex–face's, as vertex–face decided it
            // (`faceVerdict`: within its reach of the plane, the tolerance and its gap,
            // and inside the face or on its boundary; the M0–M4 review, 2026-11-15: one
            // predicate, one measure), and the crossing is that end. An end within
            // reach of the plane and outside the face is on nothing of the face: the
            // edge crosses the plane elsewhere, and that crossing is placed as any
            // other. Taken as vertex–face's by the plane alone, the crossing of an edge
            // from such an end was nobody's (OCCT's `PerformEF` takes an intersection
            // at an end for the end only where the end is on the face,
            // `CheckFacePaves`, or can be put on it, `ForceInterfVF`, and makes a
            // vertex otherwise): a hull's corner 1.5e-4 from the plane of a box's side,
            // its foot on the footprint of the side's edge and the corner 2.5e-4 from
            // the edge itself, which a union had left 1e-4 off the side's plane (D28),
            // its edge crossing the side 3.7e-4 on, 3e-4 inside it; the hull's section
            // of the side ended there on one face of the two about that edge, and the
            // side's fragment had the chain as a spur, inside and outside by it
            // (`unclassified`; the nightly of 2026-11-20, bp). Both ends asked, then
            // decided: one on the face settles it whatever the other (a plate's edge
            // from a box's corner to an end at the tolerance to rounding was refused
            // when it ran from that end; the 10K session on 0fce3ff4)
            const on0 = try self.faceVerdict(other, f, plane, v[0]);
            const on1 = try self.faceVerdict(other, f, plane, v[1]);
            if (try self.settle(canonical.either(on0.on, on1.on), .of(.edge, @backingInt(e)))) continue;
            const q = vec.lerp(p0, p1, h0 / (h0 - h1));
            if (try self.paveOnFace(k, e, other, f, plane, q)) |at| {
                try self.foundOn(other, f, at.vertex, at.place);
                continue;
            }
            const place = try self.placeIn(other, f, q, null);
            if (place == .outside) continue;
            const before = self.p.points.items.len;
            const w = try self.weld(q, 0, .{ .{ .edge = .{ .k = k, .e = e } }, .{ .face = .{ .k = other, .f = f } } });
            if (!self.hasPave(k, e, w)) {
                if (self.along(k, e, self.p.point(w))) |at| {
                    if (try self.inStrip(at, e)) try self.endStrip(k, e, w) else try self.addPave(k, e, w, at);
                }
            }
            try self.foundOn(other, f, w, place);
            if (place == .boundary and self.p.points.items.len > before) try self.onEdges(other, w, null);
        }
    }

    /// Of edge `e`'s paves so far, the one nearest `q` lying on face `f` of operand
    /// `other` (within the tolerance and its gap of the face's plane, inside the face or on
    /// its boundary), with where it lies in the face; null when none is.
    fn paveOnFace(self: *Filler, k: usize, e: types.EdgeIndex, other: usize, f: types.FaceIndex, plane: Plane, q: Vec3) Error!?struct { vertex: u32, place: in_face.Place } {
        var best: ?u32 = null;
        var best_place: in_face.Place = .outside;
        var best_distance = std.math.inf(f64);
        for (self.p.edge_paves[k][@backingInt(e)].items) |pave| {
            const distance = vec.distance(self.p.point(pave.vertex), q);
            if (distance >= best_distance) continue;
            const place = try self.placeOnFace(other, f, plane, pave.vertex) orelse continue;
            best = pave.vertex;
            best_place = place;
            best_distance = distance;
        }
        return if (best) |v| .{ .vertex = v, .place = best_place } else null;
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
                            try p.boundary.append(self.allocator, .{ .face = .{ .operand = @intCast(k), .face = @backingInt(f) }, .vertex = pave.vertex });
                        }
                    }
                }
            }
        }
        sortUnique(Incidence, &p.boundary, Incidence.lessThan);
        try p.incidences.appendSlice(self.allocator, p.boundary.items);
        try p.incidences.appendSlice(self.allocator, self.found.items);
        sortUnique(Incidence, &p.incidences, Incidence.lessThan);
        sortUnique(Touch, &p.touches, Touch.lessThan);
    }

    /// Whether the paves put merged vertex `v` on the boundary of face `f` of operand `k`.
    fn onBoundary(self: *const Filler, k: usize, f: types.FaceIndex, v: u32) bool {
        return Incidence.in(self.p.boundary.items, .{ .face = .{ .operand = @intCast(k), .face = @backingInt(f) }, .vertex = v });
    }

    /// How a piece between two merged vertices lies against a face (`lies`).
    const Lie = enum {
        /// In the face: a section of it, imprinted on it.
        in,
        /// A run of the face's own boundary: the face's already, a section of the other
        /// face alone.
        along,
        /// Beside the face: a section of neither face.
        beside,
    };

    /// How the piece from `u` to `w`, its middle `mid` at `place` against face `f` of
    /// operand `k`, lies against the face (`other` the face the piece is a section with).
    /// Inside by its middle, it is in the face. On the boundary by its middle, it is in
    /// the face too when an end is off the boundary (a piece from the boundary to an end
    /// the paves put off it: one intersection tolerance long, from an edge's tolerance
    /// out, its middle is within the zone of the edge), and along the boundary when it is
    /// a run of the face's own blocks (`alongBoundary`). What is left is a chord between
    /// two places of the boundary, within reach of it at its middle: across a sliver or a
    /// corner of the face, in the face, or across a notch of it, beside the face. The
    /// distance cannot tell these apart, so the face's loops do, by the chord's middle
    /// (`in_face.byLoops`, what places a point beyond reach of the boundary; OCCT's
    /// `IsValidBlockForFaces` classifies a section block's middle against each face, its
    /// band the edges' own tolerance).
    ///
    /// Every such chord was taken for one in the face: a hull's face 1.6 tolerances from a
    /// corner of a pocket's mouth, where the pocket's ceiling and side (a reflex edge
    /// between them) meet the face the pocket opens through, cut the corner's three edges,
    /// and the 6e-5 between its crossings of the mouth's two edges, 1.5e-5 from one of
    /// them and over the open mouth, was made a section of the face about the mouth. The
    /// piece of the hull's face in the pocket, all of it within the zone of the pocket's
    /// faces, was then outside by its seams on the ceiling and the side and inside by that
    /// one (`unclassified`; the locus session on 0856d7ba, 2026-11-21, bt, a chain an
    /// `at_tolerance` refusal of edge–face stopped a step earlier until 955002cb).
    fn lies(self: *Filler, k: usize, f: types.FaceIndex, u: u32, w: u32, mid: Vec3, place: in_face.Place, other: FaceRef) Error!Lie {
        switch (place) {
            .inside => return .in,
            .outside => return .beside,
            .boundary => {
                if (!self.onBoundary(k, f, u) or !self.onBoundary(k, f, w)) return .in;
                if (try self.alongBoundary(k, f, u, w, other)) return .along;
                return if (try in_face.byLoops(self.body(k), f, mid, try self.edgesOf(k, f), self.diag) == .outside) .beside else .in;
            },
        }
    }

    /// Whether merged vertices `u` and `w` are joined along face `f`'s boundary by a run of
    /// its pave blocks within reach of the piece between them (the intersection tolerance
    /// and their gaps), each vertex between on face `other`, the one the piece is a section
    /// with: the piece is that run, already the face's (OCCT's `IsExistingPaveBlock`: a
    /// section block with an existing block's ends, its middle on it). Both ends on the
    /// boundary and the middle near it is not enough: a chord across a sliver one tolerance
    /// wide has them (the solids fuzzer, 2026-11-14: a strip 2.05e-4 wide at a tolerance of
    /// 2e-4 left whole, straddling the other solid's face, and its ray's class spread to a
    /// fragment inside). Nor is a run within reach through a vertex the paves kept off the
    /// other face: the run is the section only through vertices on it, and a box's corner
    /// 3.3e-5 from where a face cut its three edges was the section's on one of its faces
    /// and not on another, by a hair of reach, and the corner's faces did not close (the
    /// 10K fuzz session, 2026-11-15). The edges are lines (M4): a block whose ends are
    /// within reach of the piece is within reach along it. The run found is the section,
    /// and its edges' lines go into the result (D28): each must lie on the other face's
    /// plane as the checker holds an edge to its surfaces (`runOnPlane`).
    fn alongBoundary(self: *Filler, k: usize, f: types.FaceIndex, u: u32, w: u32, other: FaceRef) Error!bool {
        const p = self.p;
        const operand = self.body(k);
        const a = p.point(u);
        const b = p.point(w);
        const reach = @max(self.reachOf(u), self.reachOf(w));
        var ring: std.ArrayList(u32) = .empty;
        defer ring.deinit(self.allocator);
        // The edge of the block from each ring vertex to the next
        var ring_edges: std.ArrayList(types.EdgeIndex) = .empty;
        defer ring_edges.deinit(self.allocator);
        var loops = traverse.Loops.init(operand, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            // The loop as its merged vertices in order, each coedge's paves its way round
            ring.clearRetainingCapacity();
            ring_edges.clearRetainingCapacity();
            var it = traverse.Coedges.init(operand, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const coedge = operand.coedge(c);
                const list = p.edge_paves[k][@backingInt(coedge.edge)].items;
                for (0..list.len - 1) |i| {
                    try ring.append(self.allocator, if (coedge.same_sense) list[i].vertex else list[list.len - 1 - i].vertex);
                    try ring_edges.append(self.allocator, coedge.edge);
                }
            }
            const n = ring.items.len;
            for (ring.items, 0..) |v, start| {
                if (v != u) continue;
                // From `u` either way round, while the boundary keeps within reach
                for ([_]usize{ 1, n - 1 }) |step| {
                    var i = (start + step) % n;
                    while (i != start) : (i = (i + step) % n) {
                        const x = ring.items[i];
                        if (x == w) {
                            try self.runOnPlane(k, ring.items, ring_edges.items, start, i, step, other);
                            return true;
                        }
                        if (!Incidence.in(p.incidences.items, .{ .face = other, .vertex = x })) break;
                        const off = vec.distance(p.point(x), closestOnSegment(a, b, p.point(x)));
                        if (!try self.within(off, reach, .of(.face, @backingInt(f)))) break;
                    }
                }
            }
        }
        return false;
    }

    /// The run of face boundary blocks from ring position `from` to `to` (stepping by
    /// `step` round a ring of `ring.len`), which `alongBoundary` takes for a section with
    /// face `other`, on that face's plane: each block's line, where its ends project on
    /// it, within the intersection tolerance and the edge's gap of the plane, as the
    /// checker holds an edge to its surfaces. The run's vertices are on the face by their
    /// reach, which spends their gaps; a line beyond its own reach of the plane would put
    /// the edge on the face with the tolerance spent twice (the 10K session on 7a1bfb5e,
    /// 2026-11-16: a hull's edge between corners 2.1e-5 from a box's face, their gaps
    /// 5.3e-6, its line 2.5e-5 from it, laid in the face as a slit, `edge_off_surface`).
    /// Refused, the edge within twice the tolerance of a face it does not lie in
    /// (`below_feature_size`; a pair the paves refuse, Leo 2026-11-15), as `weld` refuses
    /// a merged vertex beyond a feature's reach.
    fn runOnPlane(self: *Filler, k: usize, ring: []const u32, edges: []const types.EdgeIndex, from: usize, to: usize, step: usize, other: FaceRef) Error!void {
        const p = self.p;
        const operand = self.body(k);
        const plane = planar_faces.planeOf(planar_faces.frameOf(self.body(other.operand), types.FaceIndex.of(other.face)).?);
        const n = ring.len;
        var i = from;
        while (i != to) {
            const next = (i + step) % n;
            // The block between ring positions `i` and `next` is the edge of the earlier one
            const e = edges[if (step == 1) i else next];
            const edge = operand.edge(e);
            if (operand.geometry.curve(edge.curve) == .line) {
                const line = operand.geometry.curve(edge.curve).line;
                const limit = p.tol.xsect + edge.gap;
                for ([2]u32{ ring[i], ring[next] }) |v| {
                    const height = @abs(plane.height(line.eval(line.project(p.point(v)))));
                    if (!try self.within(height, limit, .of(.edge, @backingInt(e)))) return self.diag.fail(error.Degenerate, .{
                        .code = .below_feature_size,
                        .entity = .of(.edge, @backingInt(e)),
                        .label = if (k == 0) "an edge of the first operand, on a face of the second by its ends' reach and off it by its line," else "an edge of the second operand, on a face of the first by its ends' reach and off it by its line,",
                        .measured = height,
                        .threshold = limit,
                    });
                }
            }
            i = next;
        }
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
                try self.alongEachOther(ea, @backingInt(e), key);
                try p.common.append(self.allocator, .{ .vertices = key, .edges = .{ ea, @backingInt(e) } });
            }
        }
    }

    /// Edge `ea` of `a` and `eb` of `b` sharing the piece between merged vertices `key` run
    /// along each other. Two edges at an angle share no piece: one found is their crossing
    /// stretched by the tolerance (a vertex of one within it of the other, near where they
    /// cross, and the crossing past the welding distance from it), which one vertex could
    /// not hold without a gap past the zone, and whose direction is the tolerance's: the
    /// faces about it would be ordered by noise (the nightly's find, run 43515591144, an
    /// edge 4.1e-5 long 14 degrees off both). Refused, `edge_too_short`: the piece against
    /// the most the tolerance stretches a crossing at their angle.
    fn alongEachOther(self: *Filler, ea: u32, eb: u32, key: [2]u32) Error!void {
        const ca = self.body(0).geometry.curve(self.body(0).edge(types.EdgeIndex.of(ea)).curve);
        const cb = self.body(1).geometry.curve(self.body(1).edge(types.EdgeIndex.of(eb)).curve);
        if (ca != .line or cb != .line) return;
        const cos = @abs(vec.dot(ca.line.d, cb.line.d));
        switch (canonical.verdict(&.{canonical.Comparison.angle(1.0 - cos, self.p.tol.angle)})) {
            .same => return,
            .at_tolerance => |c| return self.diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.edge, eb), .label = "an edge of the second operand along one of the first or not, the angle between them the angular tolerance to rounding", .measured = c.measured, .threshold = c.limit }),
            .apart => {
                const sin = @sqrt(@max(1.0 - cos * cos, 0));
                return self.diag.fail(error.TooSmallEdge, .{ .code = .edge_too_short, .entity = .of(.edge, eb), .label = "a piece an edge of the second operand shares with one of the first at an angle: their crossing, which the tolerance stretched past the welding distance (a vertex of one within it of the other near the crossing)", .measured = vec.distance(self.p.point(key[0]), self.p.point(key[1])), .threshold = 2 * self.p.tol.xsect / sin });
            },
        }
    }

    // --- face–face ---

    /// Every pair of faces of `a` and `b`: lying in one plane, recorded, and each one's
    /// pave blocks inside the other a section segment of it; else the merged vertices both
    /// lie on, sorted along their planes' line, each gap whose middle is in both faces a
    /// section segment of each face it is inside of (`lies`: not a run of the face's own
    /// boundary, and no section at all where it is a chord beside either face, across a
    /// notch of its boundary), and so is each face's own pave block between two of them
    /// that no gap is (`blocksOnBoth`). The line is `meetingLine`'s: planes at an angle
    /// meet along their own line; planes parallel within the angular tolerance
    /// have none (their normals' cross product is noise), so they meet along the merged
    /// vertices' line, and merged vertices off one line put them in one plane where they
    /// meet, whatever corners of theirs lie off it elsewhere: the pair is recorded as lying
    /// in one plane, and the plane the pipeline gives the pair holds both faces or the pair
    /// is refused (`Provenance.samePlanes`). Taken for a line, they were ordered by the noise
    /// of two parallel normals' cross product, and each face kept the other's imprint or
    /// not by its own corners: a plate's top and another's bottom, a hair off parallel and
    /// within the tolerance of each other over most of where they meet, past it at one
    /// corner, were both kept, the union's face doubled (the 10K fuzz session on e252409f).
    /// A pair sharing no merged vertex does not meet, whatever their planes: faces in one
    /// plane that overlap or touch have a corner of one on the other or edges crossing, as
    /// OCCT takes tangent faces for same-domain ones only by their common parts. Their
    /// boxes overlapping is the trees' filter, not a meeting: a plate's side and a box's
    /// face 1.5e-4 off its plane, 2 apart across it, were recorded in one plane once the
    /// operands were turned 0.3 rad and the plate's box grew over the other's, and the box's
    /// face was given the plate's plane (the 10K fuzz session on 2b26eef1, the solids
    /// moved whole).
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
        // The pieces of a pair decided so far, each its two vertices, the lesser first
        var asked: std.ArrayList([2]u32) = .empty;
        defer asked.deinit(self.allocator);
        for (pairs.items) |pair| {
            try self.options.checkCancel();
            const fa = self.faces[0][pair[0]];
            const fb = self.faces[1][pair[1]];
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
            if (both.items.len == 0) continue;
            const frame_a = planar_faces.frameOf(self.body(0), fa).?;
            const frame_b = planar_faces.frameOf(self.body(1), fb).?;
            const a_in_b = try self.liesIn(0, fa, frame_b);
            const b_in_a = try self.liesIn(1, fb, frame_a);
            if (try self.settle(canonical.either(a_in_b, b_in_a), if (a_in_b == .at_tolerance) .of(.face, @backingInt(fa)) else .of(.face, @backingInt(fb)))) {
                try p.coplanar.append(self.allocator, .{ @backingInt(fa), @backingInt(fb) });
                try self.blocksInside(1, fb, 0, fa);
                try self.blocksInside(0, fa, 1, fb);
                continue;
            }
            if (both.items.len < 2) continue;
            const line = switch (try self.meetingLine(fa, fb, frame_a, frame_b, both.items, .of(.face, @backingInt(fb)))) {
                .line => |d| d,
                .one_plane => {
                    try p.coplanar.append(self.allocator, .{ @backingInt(fa), @backingInt(fb) });
                    try self.blocksInside(1, fb, 0, fa);
                    try self.blocksInside(0, fa, 1, fb);
                    continue;
                },
            };
            var order = planar_faces.Along.init(line, planar_faces.outward(self.body(0), fa), planar_faces.outward(self.body(1), fb), 0, p.tol);
            // Two whose separation lies across the line within the angle are at one place
            // along it (`Along`)
            order.steep = p.tol.angleSine();
            if (order.sort(u32, both.items, p.points.items, mergedPoint)) |refusal| switch (refusal) {
                .at => |tie| return self.diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.face, @backingInt(fb)), .label = "two merged vertices on two faces at one place along the faces' line, apart across it to rounding", .measured = vec.distance(p.point(tie[0]), p.point(tie[1])), .threshold = p.tol.xsect }),
                .steep => |at| return self.diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.face, @backingInt(fb)), .label = "two merged vertices on two faces whose order along the faces' line hangs on the angular tolerance to rounding", .measured = at.comparison.measured, .threshold = at.comparison.limit }),
            };
            asked.clearRetainingCapacity();
            for (both.items[0 .. both.items.len - 1], both.items[1..]) |u, w| {
                try asked.append(self.allocator, .{ @min(u, w), @max(u, w) });
                try self.sectionOf(fa, fb, u, w);
            }
            // Each face's own pave blocks between two of them, where the line's order did
            // not make them a gap (`blocksOnBoth`)
            try self.blocksOnBoth(0, fa, fb, both.items, &asked);
            try self.blocksOnBoth(1, fb, fa, both.items, &asked);
        }
    }

    /// The piece between merged vertices `u` and `w`, both on face `fa` of `a` and `fb` of
    /// `b`, as a section of each face it lies in (`lies`): its middle outside either face,
    /// or beside either (a chord across a notch of its boundary), no part of where the two
    /// meet; a run of one face's own boundary, that face's already.
    fn sectionOf(self: *Filler, fa: types.FaceIndex, fb: types.FaceIndex, u: u32, w: u32) Error!void {
        const p = self.p;
        const mid = vec.lerp(p.point(u), p.point(w), 0.5);
        // A pave block of either face's own edges is on that face's boundary by the paves'
        // record (`ownBlock`), and `lies` holds its line to the other face (`runOnPlane`)
        const own = [2]bool{ try self.ownBlock(0, fa, u, w), try self.ownBlock(1, fb, u, w) };
        // Outside either face it is no part of where the two meet, whatever the other
        const in_a, const in_b = try self.placeInBoth(fa, fb, mid, own) orelse return;
        const segment: [2]u32 = .{ @min(u, w), @max(u, w) };
        // Beside either face it is no part of where the two meet
        const lies_a = try self.lies(0, fa, u, w, mid, in_a, .{ .operand = 1, .face = @backingInt(fb) });
        const lies_b = try self.lies(1, fb, u, w, mid, in_b, .{ .operand = 0, .face = @backingInt(fa) });
        if (lies_a == .beside or lies_b == .beside) return;
        const imprint_a = lies_a == .in;
        const imprint_b = lies_b == .in;
        if (imprint_a) try p.sections[0][@backingInt(fa)].append(self.allocator, segment);
        if (imprint_b) try p.sections[1][@backingInt(fb)].append(self.allocator, segment);
        if (imprint_a or imprint_b) {
            const entry = try p.section_line_of.getOrPut(self.allocator, segment);
            if (!entry.found_existing) {
                // Merged vertices more than the welding distance apart: a line
                try p.section_lines.append(self.allocator, curves.Line.through(p.point(segment[0]), p.point(segment[1])).?);
                entry.value_ptr.* = @intCast(p.section_lines.items.len - 1);
            }
        }
        self.tally();
    }

    /// Each pave block of face `f` of operand `k` whose two ends are among `both`, the
    /// merged vertices on `f` and on face `g` of the other operand, and not a piece
    /// `asked` already: a piece of where the two meet, decided as a gap of their line is
    /// (`sectionOf`), an edge of one face lying in the other (OCCT's edge–face common
    /// block, a pave block on a face: `IntTools_EdgeFace`'s common part of type edge,
    /// `BOPDS_FaceInfo::PaveBlocksIn`). The merged vertices on both lie within their reach
    /// of both planes, not of the planes' line: where the faces meet at an angle the band
    /// within the tolerance of both is that reach over the angle's sine wide across the
    /// line, and three such vertices can span a region of both faces, which the gaps of
    /// one order along the line only walk through. A hull's corner 1.5e-5 off a plate's
    /// side, the three faces about it rising from the side at 24° and more, left the
    /// side's piece inside the hull a quad of four merged vertices on it, its corners on
    /// the hull's edges, and the hull's face between two of those edges a triangle of
    /// three, all within the tolerance of the side. The corner and the vertex where the
    /// third edge crossed the plate's bottom, beside it along the line, were one place by
    /// the angle, ordered across (`planar_faces.Along`), the gaps a path past the edge
    /// from the corner down to the bottom, which no gap was: the side was not cut along
    /// it, and its quad was kept with the hull's triangle over part of it, an edge of the
    /// intersection with three faces and another with one (the nightly's locus_solids
    /// find dm on 9c931fef, a regression of e83d2a0e's order, which before walked that
    /// edge by chance). Cut along each such block, the side's pieces are the hull's faces'
    /// twins over the same pieces (`classify`, OCCT's same-domain faces).
    fn blocksOnBoth(self: *Filler, k: usize, f: types.FaceIndex, g: types.FaceIndex, both: []const u32, asked: *std.ArrayList([2]u32)) Error!void {
        const p = self.p;
        const body_k = self.body(k);
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const list = p.edge_paves[k][@backingInt(body_k.coedge(c).edge)].items;
                for (list[0 .. list.len - 1], list[1..]) |x, y| {
                    if (std.mem.indexOfScalar(u32, both, x.vertex) == null or std.mem.indexOfScalar(u32, both, y.vertex) == null) continue;
                    const segment: [2]u32 = .{ @min(x.vertex, y.vertex), @max(x.vertex, y.vertex) };
                    if (for (asked.items) |piece| {
                        if (piece[0] == segment[0] and piece[1] == segment[1]) break true;
                    } else false) continue;
                    try asked.append(self.allocator, segment);
                    if (k == 0) try self.sectionOf(f, g, x.vertex, y.vertex) else try self.sectionOf(g, f, x.vertex, y.vertex);
                }
            }
        }
    }

    /// Whether merged vertices `u` and `w` are two consecutive paves of an edge of face `f` of
    /// operand `k`: a pave block of the face's own boundary, on it by the paves' record and
    /// not measured; `lies` then holds the block's line to the other face (`runOnPlane`), on
    /// every path alike. Its middle, the chord between paves merged onto the edge by their
    /// reach and measured with no gap, can leave the face: a hull's base edge between two vertices the
    /// paves had merged onto a box's top edge, 2.1e-5 off the hull's edge (within their
    /// reach of 2.5e-5 by their gap of 5e-6), was outside both the hull's faces by its
    /// middle, so the box's side, which the edge lay in, was not cut along it, and the
    /// difference kept the hull's face as a pocket's wall meeting the side along that line,
    /// the body touching itself there, made (the nightly's locus_solids find dn on 9772565c,
    /// 2026-11-24). OCCT places an edge's own pave block on its faces by the topology
    /// (`BOPDS_FaceInfo::PaveBlocksOn`), never by a point of it. Measured, a plate's edge
    /// 2.12e-4 under a hull's sloped face at a tolerance of 2e-4, its ends merged onto the
    /// face, had left the plate's own face and the union was made; on its boundary, its line
    /// off the hull's face is refused `below_feature_size` as any such run is (bx; Leo,
    /// 2026-11-24: the same configuration refused on every path).
    fn ownBlock(self: *Filler, k: usize, f: types.FaceIndex, u: u32, w: u32) Error!bool {
        const operand = self.body(k);
        var loops = traverse.Loops.init(operand, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(operand, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const list = self.p.edge_paves[k][@backingInt(operand.coedge(c).edge)].items;
                for (list[0 .. list.len - 1], list[1..]) |x, y| {
                    if ((x.vertex == u and y.vertex == w) or (x.vertex == w and y.vertex == u)) return true;
                }
            }
        }
        return false;
    }

    /// The direction of the line two faces with unit normals `n_a` and `n_b` meet along,
    /// through merged vertices `vertices` on both (at least two, each more than the welding
    /// distance from the others), or that they lie in one plane there. Planes at an angle
    /// meet along their own line, each such vertex within its reach of both planes and so
    /// near it, however far from a line through two of them: a box's side and a plate's
    /// top, at right angles, shared four vertices, one 1.8e-4 below the others' line, and
    /// measured from it the others were off one line, the pair taken for one plane and its
    /// imprints disagreeing (the 10K session on 415e356d). Planes parallel within the
    /// angular tolerance have no line of their own, so the vertices' (`lineThrough`), or
    /// one plane when they are off one line; at that tolerance to rounding, refused
    /// (`at_tolerance`, D27). Along the vertices' line the two planes hinge, which they do
    /// only within the tolerance of each other there (`hingedWithin`), and only where one
    /// face keeps to one side of the other's plane: faces `fa` of `a` and `fb` of `b`
    /// crossing each other are refused (`planar_faces.refuseCrossingParallel`, the slice's
    /// rule alike; a hull's base 0.0085 rad off a box's top and crossing it, hinged on the
    /// hull's edge, which the top kept as a slit with the base and a side of the hull on
    /// it, four coedges: the solids sessions on 9015ab26, du).
    fn meetingLine(self: *Filler, fa: types.FaceIndex, fb: types.FaceIndex, frame_a: Frame, frame_b: Frame, vertices: []const u32, entity: diagnostics.EntityRef) Error!union(enum) { line: Vec3, one_plane } {
        const parallel = planar_faces.parallelPlanes(frame_a.z, frame_b.z, self.p.tol);
        switch (parallel) {
            .apart => return .{ .line = planar_faces.lineDirection(vec.normalized(vec.cross(frame_a.z, frame_b.z)).?) },
            .at_tolerance => |c| return self.diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = entity, .label = "two faces of the operands sharing merged vertices, parallel or not, the angle between them the angular tolerance to rounding", .measured = c.measured, .threshold = c.limit }),
            .same => {
                const crossing = canonical.both(try self.crossesPlane(0, fa, frame_b), try self.crossesPlane(1, fb, frame_a));
                try planar_faces.refuseCrossingParallel(parallel, crossing, frame_a.z, frame_b.z, self.p.tol, entity, self.diag);
                const d = (try self.lineThrough(vertices, entity)) orelse return .one_plane;
                try self.hingedWithin(frame_a, frame_b, vertices, entity);
                return .{ .line = planar_faces.lineDirection(d) };
            },
        }
    }

    /// Whether face `f` of operand `k` crosses `frame`'s plane: a merged vertex at its
    /// corners beyond its reach of the plane on each side (`same`), on one side none
    /// (`apart`), else one at its reach to rounding decides (`at_tolerance`).
    fn crossesPlane(self: *Filler, k: usize, f: types.FaceIndex, frame: Frame) Error!Verdict {
        const p = self.p;
        const plane = planar_faces.planeOf(frame);
        const body_k = self.body(k);
        var below: Verdict = .apart;
        var above: Verdict = .apart;
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const v = p.vertex_of[k][@backingInt(body_k.coedgeStart(c))];
                const beyond: Verdict = switch (self.planeVerdict(plane, v)) {
                    .same => continue,
                    .apart => .same,
                    .at_tolerance => |at| .{ .at_tolerance = at },
                };
                if (plane.height(p.point(v)) < 0) below = canonical.either(below, beyond) else above = canonical.either(above, beyond);
            }
        }
        return canonical.both(below, above);
    }

    /// Two faces' planes (`frame_a`, `frame_b`), parallel within the angular tolerance and
    /// not in one plane, meeting along the line of the merged vertices `vertices` both
    /// faces hold: within the tolerance of each other there, the difference of the
    /// vertex's heights over the two (the planes' gap at it, their normals parallel). A
    /// merged vertex is on a face within its reach of the face's plane, a corner of a
    /// boolean's result as far off its own face's (D28: an edge keeps its source's line),
    /// so two planes can each hold the vertices and lie farther than the tolerance from
    /// each other: one face's edge touches the other face, the faces themselves apart all
    /// along it, a hair from parallel, and being within the tolerance is not transitive
    /// there. No side of the one face's plane is the other's at such a line: read by the
    /// turn between them, noise, the classification put a slab's top 2.5e-4 under a
    /// plate's bottom (a tolerance of 2e-4) inside the plate, its edge 1.8e-4 over the
    /// top's plane and 7e-5 under the bottom's, the planes 2.7e-7 rad apart
    /// (`unclassified`; left to a ray, the solids touching along the edge had its faces
    /// ordered about it by the same noise, `edge_coedge_count`: the locus session on
    /// 8a0a4a2c, bn). Refused (`below_feature_size`), naming `entity`.
    ///
    /// The vertex's own gap is no part of the measure: it is how far the vertex may lie
    /// from what was merged into it, and planes this near parallel are as far apart at any
    /// of those places. Held to the vertex's reach, a box's bottom 2.1e-4 over a slab's
    /// top hinged on the top's lifted edge at two crossings of gap 1.5e-5, where the
    /// faces' corners (`liesIn`) had the two apart, and the union came out by the same
    /// noise (the targeted review of 2026-11-20, lead 1).
    fn hingedWithin(self: *Filler, frame_a: Frame, frame_b: Frame, vertices: []const u32, entity: diagnostics.EntityRef) Error!void {
        const p = self.p;
        const plane_a = planar_faces.planeOf(frame_a);
        const plane_b = planar_faces.planeOf(frame_b);
        const facing: f64 = if (vec.dot(frame_a.z, frame_b.z) < 0) -1 else 1;
        var verdict: Verdict = .same;
        var apart: f64 = 0;
        for (vertices) |v| {
            const gap = @abs(plane_a.height(p.point(v)) - facing * plane_b.height(p.point(v)));
            apart = @max(apart, gap);
            verdict = canonical.both(verdict, p.decide.within(gap, p.tol.xsect));
        }
        if (try self.settle(verdict, entity)) return;
        return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = entity, .label = "two faces of the operands parallel within the angular tolerance, an edge of one on the other, their planes farther apart along it than the tolerance,", .measured = apart, .threshold = p.tol.xsect });
    }

    /// The direction of the line through merged vertices `vertices` (at least two, each
    /// more than the welding distance from the others), the two farthest apart, when every
    /// other lies within its reach of that line, else null: one clearly off it decides,
    /// whatever the others; else one at its reach to rounding is refused (`entity` named).
    /// The line is the vertices' own, not their order's: drawn from the first merged vertex,
    /// which is the first operand's, a box's top bent 1.5e-5 off a line at its middle
    /// corner, a plate hinged on it at 0.005 rad, put the far corner 3e-5 off the line from
    /// the middle one (one plane, refused) and the middle one 1.5e-5 off the line between
    /// the corners with the operands swapped (a line, made).
    fn lineThrough(self: *Filler, vertices: []const u32, entity: diagnostics.EntityRef) Error!?Vec3 {
        const p = self.p;
        // The pair farthest apart, a tie to the pair whose points come first (merged
        // vertices are distinct points, so their order is the points')
        var span: [2]u32 = undefined;
        var longest: f64 = -1;
        for (vertices, 0..) |x, i| for (vertices[i + 1 ..]) |y| {
            const pair: [2]u32 = if (pointBefore(p.point(y), p.point(x))) .{ y, x } else .{ x, y };
            const length = vec.lengthSq(vec.sub(p.point(pair[1]), p.point(pair[0])));
            if (length > longest or (length == longest and pairBefore(p, pair, span))) {
                span = pair;
                longest = length;
            }
        };
        const u = p.point(span[0]);
        const d = vec.normalized(vec.sub(p.point(span[1]), u)).?;
        var verdict: Verdict = .same;
        for (vertices) |v| {
            if (v == span[0] or v == span[1]) continue;
            verdict = canonical.both(verdict, p.decide.within(vec.length(vec.cross(vec.sub(p.point(v), u), d)), self.reachOf(v)));
            if (verdict == .apart) return null;
        }
        return if (try self.settle(verdict, entity)) d else null;
    }

    /// A warning (`nearly_coplanar`, OCCT's BadPositioning) for each face of `a` parallel to
    /// a face of `b` within `NEARLY_COPLANAR` intersection tolerances of its plane but not
    /// in it, their boxes that near: the result has faces as thin as the gap. Its own pairs,
    /// the boxes grown by that reach, since faces that far apart meet in no other stage.
    fn nearlyCoplanar(self: *Filler) Error!void {
        const p = self.p;
        const reach = NEARLY_COPLANAR * p.tol.xsect;
        var trees: [2]Bvh = .{ .{}, .{} };
        defer for (&trees) |*t| t.deinit(self.allocator);
        var grown: std.ArrayList(Box3) = .empty;
        defer grown.deinit(self.allocator);
        for (0..2) |k| {
            grown.clearRetainingCapacity();
            for (self.face_boxes[k]) |b| try grown.append(self.allocator, b.inflated(reach / 2));
            trees[k] = try Bvh.build(self.allocator, grown.items);
        }
        var pairs = try self.overlapping(&trees[0], &trees[1]);
        defer pairs.deinit(self.allocator);
        for (pairs.items) |pair| {
            const fa = self.faces[0][pair[0]];
            const fb = self.faces[1][pair[1]];
            const frame_a = planar_faces.frameOf(self.body(0), fa).?;
            const frame_b = planar_faces.frameOf(self.body(1), fb).?;
            if (!p.tol.parallel(frame_a.z, frame_b.z)) continue;
            const apart = try self.planeGap(0, fa, frame_b);
            // A warning decides nothing, so it refuses nothing: at the tolerance to
            // rounding is within it (`incidence.holds`), as the checker takes it. It refused
            // a union whose operands, swapped, were made (the 10K session on 0fce3ff4, at)
            if (incidence.holds(p.decide.within(apart, p.tol.xsect)) or apart > reach) continue;
            try self.diag.warn(.{ .code = .nearly_coplanar, .entity = .of(.face, @backingInt(fa)), .measured = apart, .threshold = p.tol.xsect });
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
    /// the tolerance and its gap: apart at the first vertex clearly off it, whatever the
    /// others; at the tolerance when one is at its reach to rounding and none is off.
    fn liesIn(self: *Filler, k: usize, f: types.FaceIndex, frame: Frame) Error!Verdict {
        const p = self.p;
        const plane = planar_faces.planeOf(frame);
        const body_k = self.body(k);
        var verdict: Verdict = .same;
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                verdict = canonical.both(verdict, self.planeVerdict(plane, p.vertex_of[k][@backingInt(body_k.coedgeStart(c))]));
                if (verdict == .apart) return .apart;
            }
        }
        return verdict;
    }

    /// Each face's coplanar partners (faces of the other operand lying in its plane,
    /// `Paves.coplanar`) coplanar with each other too, or sharing an edge: lying in a plane
    /// within the tolerance is not transitive (Segal and Séquin 1988's restriction R1), and
    /// two faces of one operand in one face's plane but not in one plane are two planes that
    /// face is decided against (a wall 1.5 intersection tolerances thick probed by a face
    /// inside it: the wall's two faces both in its plane, the imprints apart). Refused
    /// (`below_feature_size`), naming the second of the two.
    fn coplanarTogether(self: *Filler) Error!void {
        const p = self.p;
        var pairs: std.ArrayList([2]u32) = .empty;
        defer pairs.deinit(self.allocator);
        for (0..2) |k| {
            // Face `pair[0]` of operand `k`, a partner `pair[1]` of the other, by face
            const other = 1 - k;
            pairs.clearRetainingCapacity();
            for (p.coplanar.items) |pair| try pairs.append(self.allocator, .{ pair[k], pair[other] });
            std.mem.sort([2]u32, pairs.items, {}, lessPair);
            var start: usize = 0;
            while (start < pairs.items.len) {
                var end = start;
                while (end < pairs.items.len and pairs.items[end][0] == pairs.items[start][0]) end += 1;
                const group = pairs.items[start..end];
                for (group, 0..) |x, i| for (group[i + 1 ..]) |y| {
                    const f = types.FaceIndex.of(x[1]);
                    const g = types.FaceIndex.of(y[1]);
                    if (try self.adjacent(other, f, g)) continue;
                    if (try self.settle(try self.liesIn(other, f, planar_faces.frameOf(self.body(other), g).?), .of(.face, @backingInt(f))) and try self.settle(try self.liesIn(other, g, planar_faces.frameOf(self.body(other), f).?), .of(.face, @backingInt(g)))) continue;
                    return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = .of(.face, y[1]), .label = if (other == 0) "two faces of the first operand in the plane of one face of the second, not in one plane," else "two faces of the second operand in the plane of one face of the first, not in one plane,", .threshold = p.tol.xsect });
                };
                start = end;
            }
        }
    }

    /// Whether faces `f` and `g` of operand `k` share an edge.
    fn adjacent(self: *Filler, k: usize, f: types.FaceIndex, g: types.FaceIndex) Error!bool {
        const body_k = self.body(k);
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const partner = body_k.coedge(c).partner;
                if (partner != .none and body_k.loop(body_k.coedge(partner).loop).face == g) return true;
            }
        }
        return false;
    }

    /// Each face's section segments (what the other operand leaves on it), pairwise and
    /// against the face's own pave blocks, further apart in the face's plane than the
    /// intersection tolerance where the paves did not join them: nearer, the imprint's
    /// overlay welds or cuts them where the paves found no point (within the zone), or
    /// leaves a strip between them whose every point is within the zone of both, which no
    /// sample classifies (twice the zone is the tolerance).
    ///
    /// Two segments are two of the other operand's features within the tolerance of each
    /// other here, away from where they meet (a flat tetrahedron's opposite edges 1.5e-5
    /// apart, both in the plane of a face between them, crossing there; Segal and Séquin
    /// 1988's R3). Two sharing a vertex are the minimum feature size's: the other end of
    /// one within reach of the other is a merged vertex within reach of two of that
    /// operand's faces away from where they meet (`featureSize`).
    ///
    /// A segment and a block are a feature of each operand, which no rule of one operand
    /// holds apart, and the paves decide a vertex against an edge's line in space while the
    /// overlay cuts the block between its merged vertices' points in the plane: a hull's
    /// edge laid in a box's bottom 5e-6 over it, along the bottom's edge at 1e-6 rad, its
    /// first corner 1.965e-5 from that edge, on it, its second 2.06e-5 from the edge's
    /// line, off it, lay 7.3e-6 from the edge's piece between the first corner and the
    /// box's, and the overlay welded it on (`imprint_unmatched`, every operation either way
    /// round; the sessions on ab354a0a, bf). Two sharing one vertex, where the paves joined
    /// them, are measured by their other ends (`hingedGap`), and a segment along a block,
    /// sharing both, is that block. Refused (`below_feature_size`), naming the face.
    fn sectionsApart(self: *Filler) Error!void {
        const p = self.p;
        // A section segment, or one of the face's own pave blocks (`own`)
        const Flat = struct { ends: [2]u32, at: [2]Vec2, lo: f64, hi: f64, own: bool };
        var flat: std.ArrayList(Flat) = .empty;
        defer flat.deinit(self.allocator);
        for (0..2) |k| for (self.faces[k]) |f| {
            const list = p.sections[k][@backingInt(f)].items;
            if (list.len == 0) continue;
            const operand = self.body(k);
            const frame = planar_faces.frameOf(operand, f).?;
            flat.clearRetainingCapacity();
            for (list) |segment| {
                const a = planar_faces.flat(frame, p.point(segment[0]));
                const b = planar_faces.flat(frame, p.point(segment[1]));
                try flat.append(self.allocator, .{ .ends = segment, .at = .{ a, b }, .lo = @min(a[0], b[0]), .hi = @max(a[0], b[0]), .own = false });
            }
            var loops = traverse.Loops.init(operand, f);
            while (loops.next() catch return corrupt(self.diag)) |l| {
                var it = traverse.Coedges.init(operand, l);
                while (it.next() catch return corrupt(self.diag)) |c| {
                    const blocks = p.edge_paves[k][@backingInt(operand.coedge(c).edge)].items;
                    for (blocks[0 .. blocks.len - 1], blocks[1..]) |x, y| {
                        const block: [2]u32 = .{ @min(x.vertex, y.vertex), @max(x.vertex, y.vertex) };
                        const a = planar_faces.flat(frame, p.point(block[0]));
                        const b = planar_faces.flat(frame, p.point(block[1]));
                        try flat.append(self.allocator, .{ .ends = block, .at = .{ a, b }, .lo = @min(a[0], b[0]), .hi = @max(a[0], b[0]), .own = true });
                    }
                }
            }
            const Order = struct {
                fn lessThan(_: void, x: Flat, y: Flat) bool {
                    if (x.lo != y.lo) return x.lo < y.lo;
                    if (x.own != y.own) return y.own;
                    return lessPair({}, x.ends, y.ends);
                }
            };
            std.mem.sort(Flat, flat.items, {}, Order.lessThan);
            for (flat.items, 0..) |x, i| for (flat.items[i + 1 ..]) |y| {
                // Sorted by their least x: none further on comes within reach
                if (y.lo > x.hi + p.tol.xsect) break;
                if (x.own and y.own) continue;
                const x_shared: [2]bool = .{ x.ends[0] == y.ends[0] or x.ends[0] == y.ends[1], x.ends[1] == y.ends[0] or x.ends[1] == y.ends[1] };
                const hinged = x_shared[0] or x_shared[1];
                const with_own = x.own or y.own;
                // Two segments sharing a vertex are `featureSize`'s; a segment along a block
                // is that block
                if (hinged and (!with_own or (x_shared[0] and x_shared[1]))) continue;
                const gap = if (hinged) hingedGap(x.at, @intFromBool(x_shared[0]), y.at, @intFromBool(y.ends[0] == x.ends[0] or y.ends[0] == x.ends[1])) else segmentGap(x.at[0], x.at[1], y.at[0], y.at[1]);
                if (!try self.within(gap, p.tol.xsect, .of(.face, @backingInt(f)))) continue;
                return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = .of(.face, @backingInt(f)), .label = apartLabel(k, with_own), .measured = gap, .threshold = p.tol.xsect });
            };
        };
    }

    /// Each face of one operand within the intersection tolerance of two faces of the
    /// other at once, the three parallel within the angular tolerance and the two facing
    /// apart (Leo, 2026-11-15, 2026-11-16): the two bound a feature thinner than twice the
    /// tolerance where the face reaches both, and the face is within the tolerance of both
    /// over a band as wide as their small angle makes it, where the paves' sections
    /// (through merged vertices) may lie anywhere and the result's records decide what the
    /// shape is. No decision of the tolerance is consistent (the minimum feature size).
    /// Whether the two meet does not matter: two faces that do not meet are refused before
    /// the paves when that near (`pipeline.featureSize`), but two meeting at an edge at an
    /// angle within the angular tolerance (a knife edge) are not, and stay within twice the
    /// tolerance of each other far from it (the 10K session, 2026-11-16: a flat
    /// tetrahedron 2.1 tolerances thick, its faces meeting at 6e-5 rad, under a hull's top
    /// 4e-5 rad off them, a piece of the top within the zone of both everywhere,
    /// unclassified). Within both is at a point of the face whose feet on the two planes
    /// lie in those faces, within the tolerance of both planes (`reachesBoth`). A face
    /// crossing a thin feature steeply is not this: its sections with the two sides lie
    /// apart where the paves put them, and `sectionsApart` refuses them nearer than the
    /// tolerance. Refused (`below_feature_size`), naming the second of the two. The nightly
    /// solids fuzzer (2026-11-14): a flat tetrahedron's face 3.8e-5 rad off the top of a
    /// plate 2.5e-5 thick, within the tolerance of its top and its bottom over x 2.04–2.43.
    fn sandwiched(self: *Filler) Error!void {
        const p = self.p;
        var pairs = try self.overlapping(&self.face_tree[0], &self.face_tree[1]);
        defer pairs.deinit(self.allocator);
        var scratch: Sandwich = .{};
        defer scratch.deinit(self.allocator);
        var near: std.ArrayList(types.FaceIndex) = .empty;
        defer near.deinit(self.allocator);
        for (0..2) |k| {
            const other = 1 - k;
            // The pairs by the face of operand `k`
            if (k == 1) std.mem.sort([2]u32, pairs.items, {}, lessSecond);
            var start: usize = 0;
            while (start < pairs.items.len) {
                var end = start;
                while (end < pairs.items.len and pairs.items[end][k] == pairs.items[start][k]) end += 1;
                defer start = end;
                const f = self.faces[k][pairs.items[start][k]];
                const frame = planar_faces.frameOf(self.body(k), f).?;
                near.clearRetainingCapacity();
                for (pairs.items[start..end]) |pair| {
                    const g = self.faces[other][pair[other]];
                    if (p.tol.parallel(frame.z, planar_faces.frameOf(self.body(other), g).?.z)) try near.append(self.allocator, g);
                }
                if (near.items.len < 2) continue;
                for (near.items, 0..) |g1, i| for (near.items[i + 1 ..]) |g2| {
                    // Facing apart: material between them, not one side's surface in two faces
                    if (vec.dot(in_face.outwardNormal(self.body(other), g1, .{ 0, 0 }), in_face.outwardNormal(self.body(other), g2, .{ 0, 0 })) >= 0) continue;
                    if (!try self.reachesBoth(k, f, frame, other, g1, g2, &scratch)) continue;
                    return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = .of(.face, @backingInt(g2)), .label = if (other == 0) "two faces of the first operand facing apart, both within reach of one face of the second parallel to them," else "two faces of the second operand facing apart, both within reach of one face of the first parallel to them,", .threshold = p.tol.xsect });
                };
            }
        }
    }

    /// Whether a point of face `f` of operand `k` (in the plane of `frame`) lies within the
    /// intersection tolerance of the planes of faces `g1` and `g2` of operand `other`, its
    /// feet on them in the faces: the faces' triangles, put in `f`'s plane (`g1`'s and
    /// `g2`'s along their own normals, where a point's foot on them lies), meet in a region
    /// within the band of both planes, one wider than the zone (`Convex.width`, the
    /// checker's measure of a face that is no sliver; at the zone to rounding refused,
    /// `at_tolerance`, D27). Not one of any positive area: footprints that only touch along
    /// an edge meet in none where they are drawn, and in a sliver of the coordinates'
    /// rounding once the solids are moved whole, positive half the time (a box's top along
    /// a flat tetrahedron's knife edge, the two beside each other: made in place, refused
    /// `below_feature_size` moved to 3e5; the audit of fixed numbers, 2026-11-22).
    fn reachesBoth(self: *Filler, k: usize, f: types.FaceIndex, frame: Frame, other: usize, g1: types.FaceIndex, g2: types.FaceIndex, scratch: *Sandwich) Error!bool {
        const p = self.p;
        const xsect = p.tol.xsect;
        // The band of both planes over the face's box in its plane, first: mostly empty
        try self.flatTriangles(k, f, frame, null, &scratch.f);
        if (scratch.f.items.len == 0) return false;
        var lo: Vec2 = .{ std.math.inf(f64), std.math.inf(f64) };
        var hi: Vec2 = .{ -std.math.inf(f64), -std.math.inf(f64) };
        for (scratch.f.items) |t| for (t) |q| {
            lo = .{ @min(lo[0], q[0]), @min(lo[1], q[1]) };
            hi = .{ @max(hi[0], q[0]), @max(hi[1], q[1]) };
        };
        var box: Convex = .{};
        box.points[0..4].* = .{ lo, .{ hi[0], lo[1] }, hi, .{ lo[0], hi[1] } };
        box.len = 4;
        for ([2]types.FaceIndex{ g1, g2 }) |g| {
            // The plane's height over `f`'s plane, affine in its coordinates
            const plane = planar_faces.planeOf(planar_faces.frameOf(self.body(other), g).?);
            const at = plane.height(frame.origin);
            const slope: Vec2 = .{ vec.dot(plane.n, frame.x), vec.dot(plane.n, frame.y) };
            box = box.clip(slope, xsect - at).clip(.{ -slope[0], -slope[1] }, xsect + at);
        }
        if (!(box.area() > 0)) return false;
        try self.flatTriangles(other, g1, frame, planar_faces.frameOf(self.body(other), g1).?.z, &scratch.g1);
        try self.flatTriangles(other, g2, frame, planar_faces.frameOf(self.body(other), g2).?.z, &scratch.g2);
        for (scratch.f.items) |tf| {
            const in_f = box.clipTriangle(tf);
            if (!(in_f.area() > 0)) continue;
            for (scratch.g1.items) |t1| {
                const in_g1 = in_f.clipTriangle(t1);
                if (!(in_g1.area() > 0)) continue;
                for (scratch.g2.items) |t2| {
                    // A region wider than the zone: a strip narrower is no region, as a
                    // face that narrow is none (`check`'s sliver measure)
                    const width = in_g1.clipTriangle(t2).width();
                    if (!try self.settle(p.decide.within(width, p.tol.zone), .of(.face, @backingInt(g2)))) return true;
                }
            }
        }
        return false;
    }

    /// Face `g` of operand `k`'s triangles in the plane of `frame`, counter-clockwise
    /// there, into `out`: its merged vertices put on that plane along `direction` (the face's
    /// own normal, where a point's foot on it lies), or straight down for none.
    fn flatTriangles(self: *Filler, k: usize, g: types.FaceIndex, frame: Frame, direction: ?Vec3, out: *std.ArrayList([3]Vec2)) Error!void {
        const p = self.p;
        out.clearRetainingCapacity();
        const corners = try overlap.FaceTriangles.ofFace(self.allocator, self.body(k), g, self.diag);
        defer self.allocator.free(corners);
        const plane = planar_faces.planeOf(frame);
        for (corners) |t| {
            var flat: [3]Vec2 = undefined;
            for (t, &flat) |v, *q| {
                const point = p.point(p.vertex_of[k][@backingInt(v)]);
                const onto = if (direction) |n| vec.addScaled(point, n, -plane.height(point) / vec.dot(plane.n, n)) else point;
                q.* = planar_faces.flat(frame, onto);
            }
            const turn = vec.cross2(vec.sub2(flat[1], flat[0]), vec.sub2(flat[2], flat[0]));
            if (turn == 0) continue;
            if (turn < 0) std.mem.swap(Vec2, &flat[1], &flat[2]);
            try out.append(self.allocator, flat);
        }
    }

    /// Each pave block of face `f` of operand `k` whose middle is inside face `g` of
    /// operand `other` (one plane): a section segment of `g`. Its ends must lie in `g`'s
    /// plane within the tolerance and their gaps, as `liesIn` takes a face's vertices to
    /// (where in that plane is the imprint's: a piece from `g`'s boundary to an end just
    /// outside it is one): the two faces are in one plane by one's vertices against the
    /// other's plane, and a face whose plane a chain's group moved off its own boundary
    /// (D28) takes the other face within the tolerance of its plane while its boundary
    /// inside that face lies beyond it (the nightly, 2026-11-15: a union's top moved 7e-5
    /// onto a box's plane, a hull's top 1.8e-4 from that plane and 2.5e-4 from the top's
    /// edges, at a tolerance of 2e-4: the hull's top split where the paves found no point,
    /// `imprint_unmatched`). Within the tolerance is not transitive there, and no decision
    /// of it is consistent: refused (`below_feature_size`), naming `f`. So is a block that
    /// comes within the tolerance of one of `g`'s own pieces in that plane where the paves
    /// did not join them (`apartInPlane`).
    fn blocksInside(self: *Filler, k: usize, f: types.FaceIndex, other: usize, g: types.FaceIndex) Error!void {
        const p = self.p;
        const body_k = self.body(k);
        const frame = planar_faces.frameOf(self.body(other), g).?;
        const plane = planar_faces.planeOf(frame);
        var crossing: std.ArrayList(struct { edge: types.EdgeIndex, block: [2]u32 }) = .empty;
        defer crossing.deinit(self.allocator);
        var imprinted: std.ArrayList(u32) = .empty;
        defer imprinted.deinit(self.allocator);
        var loops = traverse.Loops.init(body_k, f);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_k, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const e = body_k.coedge(c).edge;
                const list = p.edge_paves[k][@backingInt(e)].items;
                for (list[0 .. list.len - 1], list[1..]) |x, y| {
                    const mid = vec.lerp(p.point(x.vertex), p.point(y.vertex), 0.5);
                    const place = try self.placeIn(other, g, mid, null);
                    if (try self.lies(other, g, x.vertex, y.vertex, mid, place, .{ .operand = @intCast(k), .face = @backingInt(f) }) != .in) {
                        // From inside `g` to outside it in that plane, with no merged vertex
                        // where it crosses `g`'s boundary: decided below, once the blocks
                        // imprinted on `g` are known
                        if (try self.passesOut(other, g, x.vertex, y.vertex)) try crossing.append(self.allocator, .{ .edge = e, .block = .{ x.vertex, y.vertex } });
                        continue;
                    }
                    for ([2]u32{ x.vertex, y.vertex }) |v| {
                        if (try self.onPlane(plane, v, .of(.face, @backingInt(g)))) continue;
                        return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = .of(.face, @backingInt(f)), .label = if (k == 0) "a face of the first operand in one plane with a face of the second, its boundary inside that face beyond reach of its plane," else "a face of the second operand in one plane with a face of the first, its boundary inside that face beyond reach of its plane,", .measured = @abs(plane.height(p.point(v))), .threshold = p.tol.xsect + p.gaps.items[v] });
                    }
                    try self.apartInPlane(k, e, .{ x.vertex, y.vertex }, other, g, frame, f);
                    try p.sections[other][@backingInt(g)].append(self.allocator, .{ @min(x.vertex, y.vertex), @max(x.vertex, y.vertex) });
                    try imprinted.appendSlice(self.allocator, &.{ x.vertex, y.vertex });
                    self.tally();
                }
            }
        }
        // A block leaving `g` from the end of one imprinted on it: the imprint ends there,
        // inside `g`, where `g`'s imprint of the other face has no end (`passesOut`)
        for (crossing.items) |c| {
            const inside = if (try self.placeIn(other, g, p.point(c.block[0]), c.block[0]) == .inside) c.block[0] else c.block[1];
            if (std.mem.indexOfScalar(u32, imprinted.items, inside) == null) continue;
            try self.apartInPlane(k, c.edge, c.block, other, g, frame, f);
        }
    }

    /// Whether the pave block from merged vertex `u` to `w` runs from strictly inside face
    /// `g` of operand `other` to strictly outside it, in either order: it crosses `g`'s
    /// boundary between two of its paves, where the paves found no vertex. Faces taken for
    /// one plane whose boundaries pass each other there beyond the tolerance, which the
    /// plane drops: a wall's face 1.83e-5 to 2.03e-5 off a hull's, turned 1e-6 rad, its edge
    /// from a corner inside the hull's face 1.97e-5 off it out past the hull's edge 2.0e-5
    /// from it, the hull's imprint of the wall a spur to that corner and the wall's of the
    /// hull another (`imprint_unmatched`; the ReleaseSafe session on ff515852, dd). Where
    /// the block leaves from the end of a block imprinted on `g`, the imprint ends inside
    /// `g` with no end in the other face's imprint of `g`, and the block goes to
    /// `apartInPlane`, which refuses it where it meets `g`'s boundary in the plane (Leo,
    /// 2026-11-18: refused, not decided again in the plane); where it leaves from no
    /// imprint, neither face's imprint ends there, and the two agree (a box's corner 1.1
    /// tolerances over a slab's edge 0.9 under its top's plane, beside it: made, sound).
    fn passesOut(self: *Filler, other: usize, g: types.FaceIndex, u: u32, w: u32) Error!bool {
        const at_u = try self.placeIn(other, g, self.p.point(u), u);
        const at_w = try self.placeIn(other, g, self.p.point(w), w);
        return (at_u == .inside and at_w == .outside) or (at_u == .outside and at_w == .inside);
    }

    /// The pave block `block` of edge `e` of operand `k`, a section of face `g` of operand
    /// `other` in one plane with it (`frame` `g`'s): refused (`below_feature_size`, naming
    /// face `f`, the block's) where, in that plane, it comes within the tolerance and both
    /// edges' gaps of one of `g`'s own pave blocks (`edgesMeet`) other than where the paves
    /// joined them, a merged vertex the two share. Taken for one plane, the pair's distance
    /// along its normal is dropped (the tolerance at most, each face's vertices on either
    /// side of it), so a corner of `g` the paves found 2.013e-4 from the block's edge, off
    /// it at a tolerance of 2e-4, was 2e-5 from it in `g`'s plane, and the imprint's overlay
    /// welded it onto the block (`imprint_unmatched`; the nightly, 2026-11-18: a hull's
    /// bottom 1.8e-4 under a plate's, a corner of a plate under the hull 1.5e-5 below it).
    /// Leo, 2026-11-18: refused, not decided again in the plane. A pair of blocks sharing
    /// one vertex is measured by their other ends (a crossing is the paves' to find).
    fn apartInPlane(self: *Filler, k: usize, e: types.EdgeIndex, block: [2]u32, other: usize, g: types.FaceIndex, frame: Frame, f: types.FaceIndex) Error!void {
        const p = self.p;
        const a = planar_faces.flat(frame, p.point(block[0]));
        const b = planar_faces.flat(frame, p.point(block[1]));
        const body_g = self.body(other);
        var loops = traverse.Loops.init(body_g, g);
        while (loops.next() catch return corrupt(self.diag)) |l| {
            var it = traverse.Coedges.init(body_g, l);
            while (it.next() catch return corrupt(self.diag)) |c| {
                const eg = body_g.coedge(c).edge;
                const list = p.edge_paves[other][@backingInt(eg)].items;
                for (list[0 .. list.len - 1], list[1..]) |x, y| {
                    const piece = [2]u32{ x.vertex, y.vertex };
                    const shared_0 = piece[0] == block[0] or piece[0] == block[1];
                    const shared_1 = piece[1] == block[0] or piece[1] == block[1];
                    if (shared_0 and shared_1) continue;
                    const u = planar_faces.flat(frame, p.point(piece[0]));
                    const w = planar_faces.flat(frame, p.point(piece[1]));
                    // Sharing one: the ends the two do not share, each against the other
                    const gap = if (shared_0 or shared_1) hingedGap(.{ u, w }, @intFromBool(shared_0), .{ a, b }, @intFromBool(block[0] == piece[0] or block[0] == piece[1])) else segmentGap(a, b, u, w);
                    switch (p.decide.edgesMeet(gap, self.edgeGapOf(k, e), self.edgeGapOf(other, eg))) {
                        .apart => {},
                        .at_tolerance => |cmp| return self.atTolerance(cmp.measured, cmp.limit, .of(.face, @backingInt(f))),
                        .same => return self.diag.fail(error.Degenerate, .{ .code = .below_feature_size, .entity = .of(.face, @backingInt(f)), .label = if (k == 0) "a face of the first operand in one plane with a face of the second, its boundary within reach of that face's boundary in the plane, not where the paves met them, by" else "a face of the second operand in one plane with a face of the first, its boundary within reach of that face's boundary in the plane, not where the paves met them, by", .measured = gap, .threshold = p.tol.xsect + self.edgeGapOf(k, e) + self.edgeGapOf(other, eg) }),
                    }
                }
            }
        }
    }
};

/// Pairs of merged vertices, each pair's points in order, in lexicographic order of them.
fn pairBefore(p: *const Paves, x: [2]u32, y: [2]u32) bool {
    if (x[0] != y[0]) return pointBefore(p.point(x[0]), p.point(y[0]));
    return pointBefore(p.point(x[1]), p.point(y[1]));
}

/// The point of the segment from `a` to `b` nearest `q`.
fn closestOnSegment(a: Vec3, b: Vec3, q: Vec3) Vec3 {
    const d = vec.sub(b, a);
    const len2 = vec.dot(d, d);
    if (len2 == 0) return a;
    return vec.addScaled(a, d, std.math.clamp(vec.dot(vec.sub(q, a), d) / len2, 0, 1));
}

/// What `Filler.sectionsApart` says of two pieces on a face of operand `k` too near each
/// other: two the other operand leaves on it, or one and a piece of the face's own
/// boundary (`with_own`).
fn apartLabel(k: usize, with_own: bool) []const u8 {
    if (with_own) return if (k == 0) "a piece the second operand leaves on a face of the first, nearer the face's own boundary in its plane than the reach where the paves did not join them," else "a piece the first operand leaves on a face of the second, nearer the face's own boundary in its plane than the reach where the paves did not join them,";
    return if (k == 0) "two of the pieces the second operand leaves on a face of the first, nearer each other in its plane than the reach where they do not meet," else "two of the pieces the first operand leaves on a face of the second, nearer each other in its plane than the reach where they do not meet,";
}

/// The distance in a plane between two segments sharing one end, `x`'s other end its
/// `x_other`-th and `y`'s its `y_other`-th: the least of each other end's from the other
/// segment (a crossing is the paves' to find).
fn hingedGap(x: [2]Vec2, x_other: usize, y: [2]Vec2, y_other: usize) f64 {
    return @min(pointGap(x[x_other], y[0], y[1]), pointGap(y[y_other], x[0], x[1]));
}

/// The distance between the segments from `a` to `b` and from `c` to `d` in a plane: 0 when
/// they cross (the exact orientations), else the least of each end's from the other.
fn segmentGap(a: Vec2, b: Vec2, c: Vec2, d: Vec2) f64 {
    const o1 = predicates.orient2d(a, b, c);
    const o2 = predicates.orient2d(a, b, d);
    const o3 = predicates.orient2d(c, d, a);
    const o4 = predicates.orient2d(c, d, b);
    if (((o1 > 0 and o2 < 0) or (o1 < 0 and o2 > 0)) and ((o3 > 0 and o4 < 0) or (o3 < 0 and o4 > 0))) return 0;
    return @min(@min(pointGap(c, a, b), pointGap(d, a, b)), @min(pointGap(a, c, d), pointGap(b, c, d)));
}

/// The part of parameter span `span` where `at0 + t·slope ≥ 0`; empty (its low end past its
/// high one) when none is.
fn clip(span: [2]f64, at0: f64, slope: f64) [2]f64 {
    if (slope == 0) return if (at0 >= 0) span else .{ 1, 0 };
    const t = -at0 / slope;
    return if (slope > 0) .{ @max(span[0], t), span[1] } else .{ span[0], @min(span[1], t) };
}

fn lessSpan(_: void, x: [2]f64, y: [2]f64) bool {
    return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]);
}

/// The distance from `q` to the segment from `a` to `b` in a plane, measured from the
/// segment's lesser end (by x, then y) whichever end is given first: the same two segments
/// measure the same to the last bit whichever comes first and whichever way each runs, as
/// the two operand orders give them. From `a` along `b − a` the rounding went with the
/// order: a block of one hull's face and a section of another 2e-5 and a hair apart
/// measured 2.0000000056848476e-5 one way round and 2.0000000056756098e-5 the other, either
/// side of D27's band about the intersection tolerance, and the intersection was made one
/// way round and refused `at_tolerance` the other (find co, a locus_solids ReleaseSafe
/// run, 2026-11-22).
fn pointGap(q: Vec2, a_given: Vec2, b_given: Vec2) f64 {
    const swap = b_given[0] < a_given[0] or (b_given[0] == a_given[0] and b_given[1] < a_given[1]);
    const a = if (swap) b_given else a_given;
    const b = if (swap) a_given else b_given;
    const d = vec.sub2(b, a);
    const len_sq = vec.lengthSq2(d);
    const s = if (len_sq == 0) 0 else std.math.clamp(vec.dot2(vec.sub2(q, a), d) / len_sq, 0, 1);
    return vec.distance2(q, vec.addScaled2(a, d, s));
}

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

fn lessSecond(_: void, x: [2]u32, y: [2]u32) bool {
    return x[1] < y[1] or (x[1] == y[1] and x[0] < y[0]);
}

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
/// What a refusal at the tolerance was deciding, by its stage.
fn stageLabel(stage: Stage) []const u8 {
    return switch (stage) {
        .vertex_vertex => "a vertex of the first operand and one of the second, merged or not (vertex–vertex)",
        .vertex_edge => "a vertex on an edge of the other operand or not (vertex–edge)",
        .edge_edge => "two edges of the operands crossing or not (edge–edge)",
        .vertex_face => "a vertex on a face of the other operand or not (vertex–face)",
        .edge_face => "an edge's end on a face's plane of the other operand or not (edge–face)",
        else => "a face in a face's plane of the other operand or not (face–face)",
    };
}

/// The largest coordinate of `a` and `b`: what a distance between their points is rounded
/// at.
fn scaleOf(a: *const Body, b: *const Body, diag: *Diagnostics) Error!f64 {
    var scale: f64 = 0;
    for ([_]*const Body{ a, b }) |body| {
        const box = bbox.bodyBounds(body) catch return corrupt(diag);
        if (box.isEmpty()) continue;
        for (0..3) |k| scale = @max(scale, @max(@abs(box.min[k]), @abs(box.max[k])));
    }
    return scale;
}

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

/// Merged vertex `v`'s point among `points` (`planar_faces.Along.sort`'s accessor).
fn mergedPoint(points: []const Vec3, v: u32) Vec3 {
    return points[v];
}
