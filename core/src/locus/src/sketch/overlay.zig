//! The overlay engine (docs/architecture.md §7.3, D9): the arrangement of line segments
//! and circular arcs in the plane, labelled by how many times each input winds about each
//! region. Every face split in Locus goes through it: sketch booleans and offsets, a
//! polygon's even-odd fill, and later the imprinting of intersection curves on faces.
//!
//! The steps (BKOS §2.3, with the degeneracies the book leaves out handled first):
//! endpoints and intersection points are welded within the zone, so coincident vertices
//! across inputs are one vertex; edges are split at every vertex on them, collinear
//! overlaps included, and sub-edges between one vertex pair on one curve become one edge
//! carrying every input's contribution; the half-edges about each vertex are ordered by
//! their tangent's angle, tangent arcs by curvature; cycles are walked with the face to
//! the left and told outer from hole by their signed area (exact for lines and arcs, so a
//! cycle whose leftmost point is inside an arc needs no special case); holes are nested in
//! the innermost outer cycle containing a point of them; and the windings are propagated
//! from the unbounded face across each edge's contributions, never by point tests.
//! Everything is index-addressed in flat arrays.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const predicates = @import("../math/predicates.zig");
const canonical = @import("../geometry/canonical.zig");
const grid = @import("../spatial/grid.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

/// `OutOfRange`: a coordinate too far from the origin for the welder's grid.
/// `AtTolerance`: two curves the zone apart to within rounding (D27), touching or not.
pub const Error = error{ OutOfMemory, TooMany, OutOfRange, AtTolerance };

/// The most inputs an overlay labels (a batch boolean's operands).
pub const MAX_INPUTS: usize = 1 << 16;
/// Edges meeting at one vertex at most.
const MAX_DEGREE: usize = 1 << 16;
/// Passes of cutting at most (`cutAll`): two in practice, the second finding what the
/// first pass's cuts moved.
const MAX_CUT_PASSES: usize = 8;
/// How far past an arc's end an angle may be and still count as on it, in radians.
const SPAN_SLACK: f64 = 1e-9;
/// How far along its curve a half-edge is sampled for the order about its origin, in
/// zones: past any crossing within the zone of the vertex (snapped to it: the order past
/// the vertex is the order past the crossing, and the tangents at the vertex told the
/// order before it, a rotation system of genus one), and far enough that an arc's bend
/// outweighs the arithmetic of its sample (a radius of 1000 bends 5e-10 in 1e-3).
const ORDER_REACH: f64 = 100;

/// A circular arc's circle: the arc runs from the edge's `a` to its `b` about `c`,
/// counter-clockwise when `ccw`.
pub const Arc = struct {
    c: Vec2,
    r: f64,
    ccw: bool,
};

/// An edge of an input: its region is to the left (outer loops run counter-clockwise,
/// holes clockwise).
pub const InputEdge = struct {
    a: Vec2,
    b: Vec2,
    arc: ?Arc = null,
};

/// An edge of the arrangement: between two vertices, straight or an arc, with what the
/// inputs contributed to it (`contributions[first_contribution..][0..contributions]`).
pub const Edge = struct {
    a: u32,
    b: u32,
    arc: ?Arc,
    first_contribution: u32 = 0,
    contributions: u32 = 0,
};

/// One input's edge lying on an arrangement edge, running with it (`along`) or against.
pub const Contribution = struct {
    edge: u32,
    input: u32,
    along: bool,

    fn lessThan(_: void, x: Contribution, y: Contribution) bool {
        return x.edge < y.edge;
    }
};

/// A cycle of half-edges: an outer boundary (counter-clockwise, positive area) or a hole
/// (clockwise). `face` is the face it bounds: its own for an outer, the containing one for a
/// hole; `UNBOUNDED` for a hole of the plane.
pub const Cycle = struct {
    first_half: u32,
    count: u32,
    area: f64,
    face: u32 = UNBOUNDED,
};

/// A bounded region: its outer cycle and its holes (`face_holes[first_hole..][0..hole_count]`).
pub const Face = struct {
    outer: u32,
    first_hole: u32 = 0,
    hole_count: u32 = 0,
};

pub const UNBOUNDED: u32 = std.math.maxInt(u32);

/// The arrangement. Add every input's edges, then `run`; read the faces and their
/// windings; `boundary` selects a region's cycles.
pub const Overlay = struct {
    allocator: std.mem.Allocator,
    tol: Tolerance,
    inputs: u32 = 0,
    /// The arcs' centres, welded like the vertices, and their radii, each the first seen
    /// within the zone: cocircular arcs that reach the overlay by different arithmetic (a
    /// round join at a vertex three faces share, each face's own) are one circle here, so
    /// their pieces merge into one arrangement edge instead of lying on each other.
    centers: std.ArrayList(Vec3) = .empty,
    center_welder: grid.PointWelder,
    radii: std.ArrayList(f64) = .empty,
    /// The welded vertices, as 3D points for the welder (z = 0).
    points: std.ArrayList(Vec3) = .empty,
    welder: grid.PointWelder,
    /// The inputs' edges, their endpoints welded.
    given: std.ArrayList(Given) = .empty,
    /// The arrangement's edges, half-edges `2e` (a → b) and `2e + 1` (b → a).
    edges: std.ArrayList(Edge) = .empty,
    contributions: std.ArrayList(Contribution) = .empty,
    /// The half-edges leaving each vertex in counter-clockwise order of their tangent:
    /// `out[out_start[v]..out_start[v + 1]]`.
    out: std.ArrayList(u32) = .empty,
    out_start: std.ArrayList(u32) = .empty,
    /// Each half-edge's place in its origin's list, its next in its cycle, its cycle.
    slot: std.ArrayList(u32) = .empty,
    next: std.ArrayList(u32) = .empty,
    cycle_of: std.ArrayList(u32) = .empty,
    cycles: std.ArrayList(Cycle) = .empty,
    cycle_halves: std.ArrayList(u32) = .empty,
    faces: std.ArrayList(Face) = .empty,
    face_holes: std.ArrayList(u32) = .empty,
    /// The windings per face per input: `windings[face * inputs + input]`.
    windings: std.ArrayList(i32) = .empty,

    const Given = struct { a: u32, b: u32, arc: ?Arc, input: u32 };

    const Cut = struct {
        given: u32,
        t: f64,
        vertex: u32,

        fn lessThan(_: void, x: Cut, y: Cut) bool {
            if (x.given != y.given) return x.given < y.given;
            return x.t < y.t;
        }
    };

    const Box = struct { min: Vec2, max: Vec2 };
    const EdgeKey = struct { a: u32, b: u32, arc: u64 };

    pub fn init(allocator: std.mem.Allocator, tol: Tolerance) Overlay {
        return .{ .allocator = allocator, .tol = tol, .welder = grid.PointWelder.init(tol.zone), .center_welder = grid.PointWelder.init(tol.zone) };
    }

    pub fn deinit(self: *Overlay) void {
        const a = self.allocator;
        self.points.deinit(a);
        self.welder.deinit(a);
        self.centers.deinit(a);
        self.center_welder.deinit(a);
        self.radii.deinit(a);
        self.given.deinit(a);
        self.edges.deinit(a);
        self.contributions.deinit(a);
        self.out.deinit(a);
        self.out_start.deinit(a);
        self.slot.deinit(a);
        self.next.deinit(a);
        self.cycle_of.deinit(a);
        self.cycles.deinit(a);
        self.cycle_halves.deinit(a);
        self.faces.deinit(a);
        self.face_holes.deinit(a);
        self.windings.deinit(a);
        self.* = undefined;
    }

    /// Opens an input; its edges follow. Returns its index.
    pub fn addInput(self: *Overlay) Error!u32 {
        if (self.inputs >= MAX_INPUTS) return error.TooMany;
        self.inputs += 1;
        return self.inputs - 1;
    }

    /// An edge of the last input opened. One whose ends weld to one vertex is nothing (an
    /// arc that is a full circle is given as two).
    pub fn addEdge(self: *Overlay, edge: InputEdge) Error!void {
        const a = try self.vertex(edge.a);
        const b = try self.vertex(edge.b);
        if (a == b) return;
        const arc: ?Arc = if (edge.arc) |given| try self.weldArc(given) else null;
        try self.given.append(self.allocator, .{ .a = a, .b = b, .arc = arc, .input = self.inputs - 1 });
    }

    /// The arc about the centre and with the radius first seen within the zone of its own.
    fn weldArc(self: *Overlay, arc: Arc) Error!Arc {
        const p3 = Vec3{ arc.c[0], arc.c[1], 0 };
        var c = arc.c;
        if (try self.center_welder.find(self.centers.items, p3)) |found| {
            c = .{ self.centers.items[found][0], self.centers.items[found][1] };
        } else {
            const index: u32 = @intCast(self.centers.items.len);
            try self.centers.append(self.allocator, p3);
            try self.center_welder.add(self.allocator, self.centers.items, index);
        }
        var r = arc.r;
        for (self.radii.items) |known| {
            if (@abs(known - arc.r) <= self.tol.zone) {
                r = known;
                break;
            }
        } else try self.radii.append(self.allocator, arc.r);
        return .{ .c = c, .r = r, .ccw = arc.ccw };
    }

    /// The vertex at `p`: an existing one within the zone, else a new one.
    fn vertex(self: *Overlay, p: Vec2) Error!u32 {
        const p3 = Vec3{ p[0], p[1], 0 };
        if (try self.welder.find(self.points.items, p3)) |found| return found;
        const index: u32 = @intCast(self.points.items.len);
        try self.points.append(self.allocator, p3);
        try self.welder.add(self.allocator, self.points.items, index);
        return index;
    }

    pub fn point(self: *const Overlay, v: u32) Vec2 {
        const p = self.points.items[v];
        return .{ p[0], p[1] };
    }

    pub fn windingOf(self: *const Overlay, face: u32, input: u32) i32 {
        return self.windings.items[face * self.inputs + input];
    }

    pub fn holesOf(self: *const Overlay, face: u32) []const u32 {
        const f = self.faces.items[face];
        return self.face_holes.items[f.first_hole..][0..f.hole_count];
    }

    pub fn halvesOf(self: *const Overlay, cycle: u32) []const u32 {
        const c = self.cycles.items[cycle];
        return self.cycle_halves.items[c.first_half..][0..c.count];
    }

    /// The face to the left of a half-edge; `UNBOUNDED` for the plane.
    pub fn leftOf(self: *const Overlay, half: u32) u32 {
        return self.cycles.items[self.cycle_of.items[half]].face;
    }

    pub fn origin(self: *const Overlay, half: u32) u32 {
        const e = self.edges.items[half / 2];
        return if (half % 2 == 0) e.a else e.b;
    }

    pub fn target(self: *const Overlay, half: u32) u32 {
        return self.origin(half ^ 1);
    }

    /// The half-edge's arc as it runs it: the edge's, turned the other way for the twin.
    pub fn arcOf(self: *const Overlay, half: u32) ?Arc {
        const arc = self.edges.items[half / 2].arc orelse return null;
        return if (half % 2 == 0) arc else .{ .c = arc.c, .r = arc.r, .ccw = !arc.ccw };
    }

    /// Builds the arrangement, its faces and their windings.
    pub fn run(self: *Overlay) Error!void {
        try self.cutAll();
        try self.order();
        try self.walkCycles();
        try self.nest();
        try self.label();
    }

    // --- splitting ---

    /// Every intersection and every vertex on an edge becomes a cut; the given edges are
    /// split at their cuts into the arrangement's edges, sub-edges between one vertex pair
    /// on one curve merged with their contributions summed. Then the pieces are cut again,
    /// until a pass cuts nothing: a cut at a vertex within the zone of an edge moves the
    /// edge's piece to run through the vertex, and near a tangency that moves the piece's
    /// crossings by up to `√(2·r·zone)`, hundreds of zones (the fuzzer, 2026-11-10: a band
    /// line tangent to a join's circle, which floating point said it missed, cut at the
    /// arc's end within its zone, then crossing the arc with no vertex there; the map was
    /// not planar). A pass that cuts nothing leaves the pieces as they are, so the map's
    /// edges meet only at vertices.
    fn cutAll(self: *Overlay) Error!void {
        var pass: usize = 1;
        while (try self.cutPass() > 0) : (pass += 1) {
            if (pass == MAX_CUT_PASSES) return error.TooMany;
            try self.piecesAsGiven();
        }
    }

    /// The arrangement's edges as the given edges again, one per contribution, for a
    /// further pass of cutting; the arrangement's edges cleared.
    fn piecesAsGiven(self: *Overlay) Error!void {
        self.given.clearRetainingCapacity();
        for (self.edges.items) |e| {
            for (self.contributions.items[e.first_contribution..][0..e.contributions]) |c| {
                const arc: ?Arc = if (e.arc) |arc| .{ .c = arc.c, .r = arc.r, .ccw = if (c.along) arc.ccw else !arc.ccw } else null;
                try self.given.append(self.allocator, .{ .a = if (c.along) e.a else e.b, .b = if (c.along) e.b else e.a, .arc = arc, .input = c.input });
            }
        }
        self.edges.clearRetainingCapacity();
        self.contributions.clearRetainingCapacity();
    }

    /// One pass of `cutAll` over the given edges; how many cuts it made.
    fn cutPass(self: *Overlay) Error!usize {
        const allocator = self.allocator;
        var cuts = std.ArrayList(Cut).empty;
        defer cuts.deinit(allocator);
        // Broad phase: the edges by their box's least x, each against the ones that follow
        // while their boxes may still meet
        const n = self.given.items.len;
        const order_by_x = try allocator.alloc(u32, n);
        defer allocator.free(order_by_x);
        const boxes = try allocator.alloc(Box, n);
        defer allocator.free(boxes);
        for (self.given.items, 0..) |g, i| {
            order_by_x[i] = @intCast(i);
            boxes[i] = self.boxOf(g);
        }
        std.mem.sort(u32, order_by_x, boxes, byMinX);
        for (order_by_x, 0..) |i, k| {
            for (order_by_x[k + 1 ..]) |j| {
                if (boxes[j].min[0] > boxes[i].max[0] + self.tol.zone) break;
                if (boxes[j].min[1] > boxes[i].max[1] + self.tol.zone or boxes[j].max[1] < boxes[i].min[1] - self.tol.zone) continue;
                try self.cutPair(i, j, &cuts);
            }
        }
        // Every vertex within the zone of a given edge is a cut on it, whichever pair
        // made the vertex: a crossing computed from one of two coincident edges and not
        // from the other (a tangency, its discriminant a rounding either side of zero
        // from either end) would otherwise split one and not the other, and the map
        // would not be planar. The vertices by x, each edge's box binary-searched
        const by_x = try allocator.alloc(u32, self.points.items.len);
        defer allocator.free(by_x);
        for (by_x, 0..) |*v, i| v.* = @intCast(i);
        std.mem.sort(u32, by_x, self.points.items, byPointX);
        for (boxes, 0..) |box, i| {
            var lo: usize = 0;
            var hi: usize = by_x.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (self.points.items[by_x[mid]][0] < box.min[0] - self.tol.zone) lo = mid + 1 else hi = mid;
            }
            while (lo < by_x.len and self.points.items[by_x[lo]][0] <= box.max[0] + self.tol.zone) : (lo += 1) {
                const v = by_x[lo];
                const y = self.points.items[v][1];
                if (y < box.min[1] - self.tol.zone or y > box.max[1] + self.tol.zone) continue;
                try self.cutAt(@intCast(i), v, &cuts);
            }
        }
        // Each given edge's cuts in order along it, the pieces as edges
        std.mem.sort(Cut, cuts.items, {}, Cut.lessThan);
        var merged = std.AutoHashMapUnmanaged(EdgeKey, u32).empty;
        defer merged.deinit(allocator);
        var at: usize = 0;
        for (self.given.items, 0..) |g, gi| {
            var from = g.a;
            while (at < cuts.items.len and cuts.items[at].given == gi) : (at += 1) {
                const v = cuts.items[at].vertex;
                if (v == from) continue;
                try self.piece(&merged, g, from, v);
                from = v;
            }
            if (from != g.b) try self.piece(&merged, g, from, g.b);
        }
        try self.mergeLenses(&merged);
        // The contributions grouped by edge
        std.mem.sort(Contribution, self.contributions.items, {}, Contribution.lessThan);
        for (self.edges.items) |*e| e.contributions = 0;
        for (self.contributions.items, 0..) |c, i| {
            const e = &self.edges.items[c.edge];
            if (e.contributions == 0) e.first_contribution = @intCast(i);
            e.contributions += 1;
        }
        return cuts.items.len;
    }

    fn byMinX(boxes: []const Box, i: u32, j: u32) bool {
        return boxes[i].min[0] < boxes[j].min[0];
    }

    fn byPointX(points: []const Vec3, i: u32, j: u32) bool {
        return points[i][0] < points[j][0];
    }

    /// The box of a given edge: its ends, and its arc's extreme points.
    fn boxOf(self: *const Overlay, g: Given) Box {
        const a = self.point(g.a);
        const b = self.point(g.b);
        var box = Box{ .min = .{ @min(a[0], b[0]), @min(a[1], b[1]) }, .max = .{ @max(a[0], b[0]), @max(a[1], b[1]) } };
        if (g.arc) |arc| {
            const span = arcSpan(a, b, arc);
            for ([_]Vec2{ .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 } }) |d| {
                if (span.holds(trig.atan2(d[1], d[0]))) {
                    const p = vec.addScaled2(arc.c, d, arc.r);
                    box.min = .{ @min(box.min[0], p[0]), @min(box.min[1], p[1]) };
                    box.max = .{ @max(box.max[0], p[0]), @max(box.max[1], p[1]) };
                }
            }
        }
        return box;
    }

    /// Where two given edges meet: crossings, a vertex of one on the other, the overlap
    /// of collinear or cocircular pieces; each becomes a cut on the edges it lies inside.
    fn cutPair(self: *Overlay, i: u32, j: u32, cuts: *std.ArrayList(Cut)) Error!void {
        const gi = self.given.items[i];
        const gj = self.given.items[j];
        var candidates: [4]Vec2 = undefined;
        var n: usize = 0;
        if (gi.arc == null and gj.arc == null) {
            n = self.lineLine(gi, gj, &candidates);
        } else if (gi.arc != null and gj.arc != null) {
            n = try self.arcArc(gi, gj, &candidates);
        } else {
            n = try self.lineArc(if (gi.arc == null) gi else gj, if (gi.arc == null) gj else gi, &candidates);
        }
        for (candidates[0..n]) |p| {
            if (self.sameMeeting(gi, gj, p)) continue;
            const v = try self.vertex(p);
            try self.cutAt(i, v, cuts);
            try self.cutAt(j, v, cuts);
        }
        // Each end of one on the other: a T-junction, or the end of an overlap
        for ([_]u32{ gj.a, gj.b }) |v| try self.cutAt(i, v, cuts);
        for ([_]u32{ gi.a, gi.b }) |v| try self.cutAt(j, v, cuts);
    }

    /// Whether `p`, where given edges `gi` and `gj` meet, is the meeting a vertex they share
    /// already is: from that vertex to `p` the two never part by more than the rounding of
    /// their coordinates (D27's band), so the arithmetic cannot tell `p` from the vertex's
    /// own contact (two curves meet once per contact, as the booleans' edges do, KNOWLEDGE
    /// "Two edges meet once, too"). At a tangent join the touch's place along the curves is
    /// ill-conditioned, a rounding δ of the line moving it by √(2·r·δ): an offset's round
    /// join turned and moved 2e6 out, its line and arc tangent at their vertex, 1.3e-10
    /// apart up to a point 2.26e-5 along, which the sheet's own overlay cut (the sheet
    /// rule's first run, 2026-11-16). Parting by more is a second meeting, cut: two arcs
    /// crossing at a shared vertex and again 5.8e-3 on, a lens 9.2e-6 thick between them,
    /// left uncut, crossed where the map had no vertex (the zone, tried first, merged
    /// them: the overlay target, the same day). Two lines need none: an end on the other's
    /// line is never their crossing (`lineLine`).
    fn sameMeeting(self: *const Overlay, gi: Given, gj: Given, p: Vec2) bool {
        if (gi.arc == null and gj.arc == null) return false;
        for ([2]u32{ gi.a, gi.b }) |v| {
            if (v != gj.a and v != gj.b) continue;
            const from = self.point(v);
            var scale = @max(magnitude2(from), magnitude2(p));
            const apart = if (gi.arc != null and gj.arc != null) blk: {
                const ai = gi.arc.?;
                const aj = gj.arc.?;
                scale = @max(scale, magnitude2(ai.c) + ai.r, magnitude2(aj.c) + aj.r);
                // The stretch of `gi`'s arc from the shared vertex to `p`, run as the arc runs
                const ends: [2]Vec2 = if (v == gi.a) .{ from, p } else .{ p, from };
                break :blk arcStretchApart(ends[0], ends[1], ai, aj);
            } else blk: {
                const arc = (gi.arc orelse gj.arc).?;
                scale = @max(scale, magnitude2(arc.c) + arc.r);
                break :blk segmentApart(from, p, arc);
            };
            if (apart <= canonical.Comparison.distance(apart, 0, scale).band) return true;
        }
        return false;
    }

    /// A cut of given edge `i` at vertex `v`, when `v` lies on it and is neither end.
    fn cutAt(self: *Overlay, i: u32, v: u32, cuts: *std.ArrayList(Cut)) Error!void {
        const g = self.given.items[i];
        if (v == g.a or v == g.b) return;
        if (self.paramOn(g, self.point(v))) |t| try cuts.append(self.allocator, .{ .given = i, .t = t, .vertex = v });
    }

    /// The parameter of `p` along a given edge when `p` lies inside it within the zone (a
    /// line's fraction of its length, an arc's angle from its start), else null. On an
    /// arc, inside is told by the chord (`onArcStrictly`), never by an angle. A line is
    /// measured from its lower end (by x, then y), whichever way it was given: from either
    /// end a point the zone from it rounds either side (1.00000000003e-5 one way,
    /// 9.99999999997e-6 the other), and two coincident sides given opposite ways were cut
    /// at it one and not the other, a sliver face one zone wide between them.
    fn paramOn(self: *const Overlay, g: Given, p: Vec2) ?f64 {
        const a = self.point(g.a);
        const b = self.point(g.b);
        if (g.arc) |arc| {
            if (@abs(vec.length2(vec.sub2(p, arc.c)) - arc.r) > self.tol.zone) return null;
            if (!onArcStrictly(a, b, arc, p)) return null;
            return arcParam(a, b, arc, p);
        }
        const from_b = b[0] < a[0] or (b[0] == a[0] and b[1] < a[1]);
        const lo = if (from_b) b else a;
        const d = vec.sub2(if (from_b) a else b, lo);
        const len = vec.length2(d);
        const s = vec.dot2(vec.sub2(p, lo), d) / (len * len);
        if (s <= 0 or s >= 1) return null;
        if (vec.distance2(vec.addScaled2(lo, d, s), p) > self.tol.zone) return null;
        return if (from_b) 1 - s else s;
    }

    /// The crossing of two line segments inside both (an end on the other is a cut of its
    /// own; collinear ones overlap along their ends, which are cuts too). Coincidence
    /// first (D16): an end within the zone of the other segment's line is on it, a
    /// T-junction or an overlap for `cutAt`, never a crossing, whichever side the exact
    /// turn puts it: a crossing computed from two near-zero turns could land anywhere
    /// along the segment.
    fn lineLine(self: *const Overlay, gi: Given, gj: Given, out: *[4]Vec2) usize {
        const a = self.point(gi.a);
        const b = self.point(gi.b);
        const c = self.point(gj.a);
        const d = self.point(gj.b);
        const abc = predicates.orient2d(a, b, c);
        const abd = predicates.orient2d(a, b, d);
        const cda = predicates.orient2d(c, d, a);
        const cdb = predicates.orient2d(c, d, b);
        // A turn is twice the triangle's area: the end's distance from the line times the
        // line's length
        const ab_zone = self.tol.zone * vec.distance2(a, b);
        const cd_zone = self.tol.zone * vec.distance2(c, d);
        if (@abs(abc) <= ab_zone or @abs(abd) <= ab_zone or @abs(cda) <= cd_zone or @abs(cdb) <= cd_zone) return 0;
        if ((abc > 0) == (abd > 0) or (cda > 0) == (cdb > 0)) return 0;
        out[0] = vec.addScaled2(a, vec.sub2(b, a), cda / (cda - cdb));
        return 1;
    }

    /// The crossings of a line segment and an arc, inside both: whether the line meets
    /// the circle, touches it or misses it, and where each root lies along the segment,
    /// by the exact predicates (D26; a touch is the one point, the foot of the centre's
    /// perpendicular); whether the point is on the arc, by the chord. A line missing the
    /// circle by no more than the zone touches it (D16, as `arcArc`), one point midway
    /// between the foot and the circle. The point itself is a construction, welded by the
    /// caller.
    fn lineArc(self: *const Overlay, line: Given, arc_edge: Given, out: *[4]Vec2) Error!usize {
        const arc = arc_edge.arc.?;
        const a = self.point(line.a);
        const b = self.point(line.b);
        const arc_a = self.point(arc_edge.a);
        const arc_b = self.point(arc_edge.b);
        const disc = predicates.lineCircleDiscriminant(a, b, arc.c, arc.r);
        if (disc < 0) {
            // Missing the circle by no more than the zone: a touch, midway between the
            // perpendicular's foot and the circle
            const d = vec.sub2(b, a);
            const s = vec.dot2(vec.sub2(arc.c, a), d) / vec.dot2(d, d);
            const foot = vec.addScaled2(a, d, s);
            const off = vec.distance2(foot, arc.c);
            const scale = @max(magnitude2(a), magnitude2(b), magnitude2(arc.c) + arc.r);
            if (!try self.touch(off - arc.r, scale)) return 0;
            const p = vec.addScaled2(arc.c, vec.sub2(foot, arc.c), (off + arc.r) / (2 * off));
            if (s <= 0 or s >= 1 or !onArcStrictly(arc_a, arc_b, arc, p)) return 0;
            out[0] = p;
            return 1;
        }
        const d = vec.sub2(b, a);
        const f = vec.sub2(a, arc.c);
        const qa = vec.dot2(d, d);
        const qb = 2 * vec.dot2(f, d);
        const qc = vec.dot2(f, f) - arc.r * arc.r;
        const root = if (disc == 0) 0 else @sqrt(@max(qb * qb - 4 * qa * qc, 0));
        var n: usize = 0;
        for ([_]predicates.Root{ .first, .second }, [_]f64{ -root, root }) |which, signed| {
            const place = predicates.lineCircleCrossing(a, b, arc.c, arc.r, which) orelse continue;
            if (place != .inside) continue;
            const p = vec.addScaled2(a, d, (-qb + signed) / (2 * qa));
            if (!onArcStrictly(arc_a, arc_b, arc, p)) continue;
            if (n > 0 and vec.distance2(out[0], p) <= self.tol.zone) continue;
            out[n] = p;
            n += 1;
        }
        return n;
    }

    /// The crossings of two arcs inside both (cocircular arcs overlap along their ends).
    /// How the circles lie is the exact sign on their centres and radii (D26,
    /// `predicates.circlePair`). Crossing, the two points, `h²` in factored form,
    /// `((r₁ + r₂)² − d²)(d² − (r₁ − r₂)²) / 4d²`, each factor positive (two within the
    /// zone of each other are one, welded). Touching, or missing each other by no more
    /// than the zone, outside (`d − (r₁ + r₂)`) or inside (`|r₁ − r₂| − d`): one point,
    /// coincidence first (D16, Leo 2026-11-16), on the line of the centres midway
    /// between their nearest points (`touch`), never the radical line's foot, which near
    /// an inner touch moves by the gap times `(r₁ + r₂)/d` (a pair missing by less than
    /// the zone took a touch point on neither circle). The exact sign alone (2026-11-14)
    /// left a touch to the rounding of the radii: two circles on the grid touching inside,
    /// of radii √11.25 and √0.3125, came out nested by 1e-16, no vertex was made where
    /// they touch, and a sheet's face touched itself there (the nightly, 2026-11-16, run
    /// 43773180777).
    fn arcArc(self: *const Overlay, gi: Given, gj: Given, out: *[4]Vec2) Error!usize {
        const ai = gi.arc.?;
        const aj = gj.arc.?;
        const between = vec.sub2(aj.c, ai.c);
        const dist = vec.length2(between);
        // Concentric within the zone: one circle, welded (`addEdge`), overlapping
        if (dist <= self.tol.zone) return 0;
        const a_i = self.point(gi.a);
        const b_i = self.point(gi.b);
        const a_j = self.point(gj.a);
        const b_j = self.point(gj.b);
        const pair = predicates.circlePair(ai.c, ai.r, aj.c, aj.r);
        if (pair != .crossing) {
            // Along the centres from `ai`'s, the point midway between the nearest points
            const scale = @max(magnitude2(ai.c) + ai.r, magnitude2(aj.c) + aj.r);
            const outside = pair == .apart or pair == .touching_outside;
            const gap = if (outside) dist - (ai.r + aj.r) else @abs(ai.r - aj.r) - dist;
            if (!try self.touch(gap, scale)) return 0;
            const x = if (outside) (ai.r + dist - aj.r) / 2 else if (ai.r >= aj.r) (ai.r + dist + aj.r) / 2 else (dist - ai.r - aj.r) / 2;
            const p = vec.addScaled2(ai.c, vec.scale2(between, 1.0 / dist), x);
            if (!onArcStrictly(a_i, b_i, ai, p) or !onArcStrictly(a_j, b_j, aj, p)) return 0;
            out[0] = p;
            return 1;
        }
        // The radical line: `x` along the centres, `h` across it
        const d2 = vec.dot2(between, between);
        const x = (d2 + ai.r * ai.r - aj.r * aj.r) / (2 * dist);
        const h = blk: {
            const sum = ai.r + aj.r;
            const diff = ai.r - aj.r;
            break :blk @sqrt(@max((sum * sum - d2) * (d2 - diff * diff), 0)) / (2 * dist);
        };
        const along = vec.scale2(between, 1.0 / dist);
        const across = Vec2{ -along[1], along[0] };
        const foot = vec.addScaled2(ai.c, along, x);
        var n: usize = 0;
        for ([_]f64{ h, -h }) |side| {
            const p = vec.addScaled2(foot, across, side);
            if (!onArcStrictly(a_i, b_i, ai, p) or !onArcStrictly(a_j, b_j, aj, p)) continue;
            if (n > 0 and vec.distance2(out[0], p) <= self.tol.zone) continue;
            out[n] = p;
            n += 1;
        }
        return n;
    }

    /// Whether two curves `gap` apart (signed, either way) touch: within the zone (D16), at
    /// it to rounding of coordinates of size `scale` refused (D27, `AtTolerance`).
    fn touch(self: *const Overlay, gap: f64, scale: f64) Error!bool {
        return switch (canonical.verdict(&.{canonical.Comparison.distance(@abs(gap), self.tol.zone, scale)})) {
            .same => true,
            .apart => false,
            .at_tolerance => error.AtTolerance,
        };
    }

    /// A piece of a given edge between two vertices, as an arrangement edge: the one
    /// already there between them on the same curve, or a new one; the input's
    /// contribution recorded with its direction relative to the edge's.
    fn piece(self: *Overlay, merged: *std.AutoHashMapUnmanaged(EdgeKey, u32), g: Given, from: u32, to: u32) Error!void {
        // The edge's own direction is from the lesser vertex; an arc turned about keeps
        // its circle and reverses its sense
        const forward = from < to;
        const a = if (forward) from else to;
        const b = if (forward) to else from;
        // A piece keeps its given edge's curve, however short it is (D28's rule in the
        // plane): an arc piece within the zone of its chord is still an arc of its circle,
        // and one edge with a line between its ends only where there is such a line
        // (`mergeLenses`)
        const arc: ?Arc = if (g.arc) |given_arc| .{ .c = given_arc.c, .r = given_arc.r, .ccw = if (forward) given_arc.ccw else !given_arc.ccw } else null;
        const key = EdgeKey{ .a = a, .b = b, .arc = if (arc) |piece_arc| arcKey(piece_arc) else 0 };
        try merged.ensureUnusedCapacity(self.allocator, 1);
        const entry = merged.getOrPutAssumeCapacity(key);
        if (!entry.found_existing) {
            if (self.edges.items.len >= std.math.maxInt(u32) / 2) return error.TooMany;
            entry.value_ptr.* = @intCast(self.edges.items.len);
            try self.edges.append(self.allocator, .{ .a = a, .b = b, .arc = arc });
        }
        try self.contributions.append(self.allocator, .{ .edge = entry.value_ptr.*, .input = g.input, .along = forward });
    }

    /// Edges between the same two vertices that lie within the zone of each other are one
    /// edge: the lens between them is thinner than the zone, its area at the rounding level
    /// and of either sign, and no region. Two minor arcs over one chord are furthest apart
    /// at its middle, by the difference of their bulges across it, and an arc is as far
    /// from the line between its ends as its own bulge; arcs a major arc's length within
    /// the zone of each other are on one circle, welded in `addEdge`. The line, where there
    /// is one (`merged` has it), keeps its curve and takes the arcs' contributions; else the
    /// first arc keeps its own (the fuzzer, 2026-11-13: two internally tangent circles, a
    /// line crossing both where they are within the zone, both cut at the one vertex its
    /// crossings welded to, and the lens between them made V − E + F wrong).
    ///
    /// An arc with no such edge beside it keeps its circle, however near its chord it
    /// lies: taken for its chord, as every such piece was, it left its circle's tangent by
    /// half its angle, `√(2·zone/r)` at the most, and an offset's join at its end, which
    /// goes by the tangent, moved by that times the offset (the nightly of 2026-11-20, bm:
    /// an arc ending 0.0012 rad short of the point its sweeps met at, to +x of its centre
    /// where the sheet's own arc was split, D7; the piece between a line, a bevel beside it
    /// 9e-4 off at 1.5, the area 82.93347 in place and 82.93419 turned).
    fn mergeLenses(self: *Overlay, merged: *const std.AutoHashMapUnmanaged(EdgeKey, u32)) Error!void {
        const allocator = self.allocator;
        const n = self.edges.items.len;
        // The arc edges by their ends
        const by_ends = try allocator.alloc(u32, n);
        defer allocator.free(by_ends);
        var m: usize = 0;
        for (self.edges.items, 0..) |e, i| {
            if (e.arc == null) continue;
            by_ends[m] = @intCast(i);
            m += 1;
        }
        const ByEnds = struct {
            edges: []const Edge,
            fn lessThan(edges: []const Edge, x: u32, y: u32) bool {
                const ex = edges[x];
                const ey = edges[y];
                if (ex.a != ey.a) return ex.a < ey.a;
                if (ex.b != ey.b) return ex.b < ey.b;
                return x < y;
            }
        };
        std.mem.sort(u32, by_ends[0..m], self.edges.items, ByEnds.lessThan);
        // Each edge the one it merges into, itself when it stays
        const into = try allocator.alloc(u32, n);
        defer allocator.free(into);
        for (into, 0..) |*x, i| x.* = @intCast(i);
        var merges: usize = 0;
        var start: usize = 0;
        while (start < m) {
            var end = start + 1;
            const first = self.edges.items[by_ends[start]];
            while (end < m and self.edges.items[by_ends[end]].a == first.a and self.edges.items[by_ends[end]].b == first.b) end += 1;
            defer start = end;
            if (merged.get(.{ .a = first.a, .b = first.b, .arc = 0 })) |line| {
                for (by_ends[start..end]) |x| {
                    if (self.withinZone(self.edges.items[line], self.edges.items[x])) {
                        into[x] = line;
                        merges += 1;
                    }
                }
            }
            for (by_ends[start..end], 0..) |x, k| {
                if (into[x] != x) continue;
                for (by_ends[start..end][k + 1 ..]) |y| {
                    if (into[y] != y) continue;
                    if (self.withinZone(self.edges.items[x], self.edges.items[y])) {
                        into[y] = x;
                        merges += 1;
                    }
                }
            }
        }
        if (merges == 0) return;
        // The edges kept, renumbered, and every contribution moved onto its edge's
        const index = try allocator.alloc(u32, n);
        defer allocator.free(index);
        var kept: u32 = 0;
        for (self.edges.items, 0..) |e, i| {
            if (into[i] != i) continue;
            index[i] = kept;
            self.edges.items[kept] = e;
            kept += 1;
        }
        for (self.contributions.items) |*c| c.edge = index[into[c.edge]];
        self.edges.shrinkRetainingCapacity(kept);
    }

    /// Whether two edges between the same vertices lie within the zone of each other: each
    /// a line or a minor arc, their bulges across the chord (signed by the side they bow
    /// to) the zone apart at most.
    fn withinZone(self: *const Overlay, x: Edge, y: Edge) bool {
        const pa = self.point(x.a);
        const pb = self.point(x.b);
        const bx = bulge(pa, pb, x.arc) orelse return false;
        const by = bulge(pa, pb, y.arc) orelse return false;
        return @abs(bx - by) <= self.tol.zone;
    }

    /// How far a line or a minor arc from `a` to `b` bows from its chord, positive to the
    /// chord's left: nothing for a line; null for a major arc (its centre on the side it
    /// bows to).
    fn bulge(a: Vec2, b: Vec2, curve: ?Arc) ?f64 {
        const arc = curve orelse return 0;
        const side = predicates.orient2d(a, b, arc.c);
        // A minor arc bows away from its centre: to the left when the centre is right of
        // the chord and the arc runs counter-clockwise about it from `a`, or left of it and
        // clockwise
        const minor = (side > 0) == arc.ccw;
        if (!minor) return null;
        const half = vec.distance2(a, b) / 2;
        const sagitta = arc.r - @sqrt(@max(arc.r * arc.r - half * half, 0));
        return if (side < 0) sagitta else -sagitta;
    }

    /// An arc's identity for merging: its circle as bits (welded in `addEdge`, so arcs
    /// cocircular within the zone have the same bits) and which way round it runs in the
    /// edge's own direction (the two halves of a circle share their ends and their
    /// circle, and are two arcs).
    fn arcKey(arc: Arc) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&arc.c));
        h.update(std.mem.asBytes(&arc.r));
        h.update(std.mem.asBytes(&arc.ccw));
        return h.final() | 1;
    }

    // --- the order about each vertex ---

    /// The half-edges leaving each vertex in counter-clockwise order of their tangent's
    /// angle, tangent arcs by their curvature (the one curving left is further round).
    fn order(self: *Overlay) Error!void {
        const allocator = self.allocator;
        const n_vertices = self.points.items.len;
        const n_halves = 2 * self.edges.items.len;
        try self.out_start.resize(allocator, n_vertices + 1);
        @memset(self.out_start.items, 0);
        for (0..n_halves) |h| self.out_start.items[self.origin(@intCast(h)) + 1] += 1;
        for (1..n_vertices + 1) |v| self.out_start.items[v] += self.out_start.items[v - 1];
        try self.out.resize(allocator, n_halves);
        const fill = try allocator.alloc(u32, n_vertices);
        defer allocator.free(fill);
        @memset(fill, 0);
        for (0..n_halves) |h| {
            const v = self.origin(@intCast(h));
            self.out.items[self.out_start.items[v] + fill[v]] = @intCast(h);
            fill[v] += 1;
        }
        try self.slot.resize(allocator, n_halves);
        for (0..n_vertices) |v| {
            if (self.out_start.items[v + 1] - self.out_start.items[v] > MAX_DEGREE) return error.TooMany;
            const halves = self.out.items[self.out_start.items[v]..self.out_start.items[v + 1]];
            std.mem.sort(u32, halves, self, lessAbout);
            for (halves, 0..) |h, k| self.slot.items[h] = @intCast(k);
        }
    }

    /// Whether `x` leaves its origin at a smaller angle than `y`, counter-clockwise from
    /// the positive x axis: by the directions to their samples a reach along them
    /// (`orderSample`), by half-plane, then by the exact predicate on the sample points.
    /// Tangent curves (a join arc and the line it joins) part by their bend within the
    /// reach, so no curvature rule is needed; two lines a fraction of a degree apart have
    /// their definite order (as near-tangent by an angle tolerance they had none, and the
    /// sort put them anyhow). No angle is ever computed, so a direction along the
    /// negative x axis has no seam to fall across.
    fn lessAbout(self: *const Overlay, x: u32, y: u32) bool {
        const o = self.point(self.origin(x));
        const px = self.sample(x);
        const py = self.sample(y);
        const ux = upperHalf(vec.sub2(px, o));
        const uy = upperHalf(vec.sub2(py, o));
        if (ux != uy) return ux;
        const side = predicates.orient2d(o, px, py);
        if (side != 0) return side > 0;
        return x < y;
    }

    /// The half-edge's point the order about its origin goes by (`orderSample`).
    fn sample(self: *const Overlay, half: u32) Vec2 {
        return orderSample(self.point(self.origin(half)), self.point(self.target(half)), self.arcOf(half), self.tol.zone);
    }

    fn upperHalf(d: Vec2) bool {
        return d[1] > 0 or (d[1] == 0 and d[0] > 0);
    }

    // --- cycles ---

    /// Every half-edge's successor in the cycle with the face to its left: the half-edge
    /// leaving its target just clockwise of its twin; the cycles walked, their signed
    /// areas taken.
    fn walkCycles(self: *Overlay) Error!void {
        const allocator = self.allocator;
        const n_halves = 2 * self.edges.items.len;
        try self.next.resize(allocator, n_halves);
        for (0..n_halves) |h| self.next.items[h] = self.clockwiseOfTwin(@intCast(h));
        try self.cycle_of.resize(allocator, n_halves);
        @memset(self.cycle_of.items, UNBOUNDED);
        self.cycles.clearRetainingCapacity();
        self.cycle_halves.clearRetainingCapacity();
        for (0..n_halves) |start| {
            if (self.cycle_of.items[start] != UNBOUNDED) continue;
            const id: u32 = @intCast(self.cycles.items.len);
            const first: u32 = @intCast(self.cycle_halves.items.len);
            var area: f64 = 0;
            var h: u32 = @intCast(start);
            const from = self.point(self.origin(h));
            while (self.cycle_of.items[h] == UNBOUNDED) : (h = self.next.items[h]) {
                self.cycle_of.items[h] = id;
                try self.cycle_halves.append(allocator, h);
                area += self.areaTerm(h, from);
            }
            // A cycle that runs each of its edges both ways (a tree of edges: collinear
            // points, a slit standing alone) bounds nothing, its area exactly 0; the sum's
            // rounding gave it a sign, and a positive one made it a face (the fuzzer,
            // 2026-11-12: three collinear points, a face of area 2e-16)
            var bounds_nothing = true;
            for (self.cycle_halves.items[first..]) |half| bounds_nothing = bounds_nothing and self.cycle_of.items[half ^ 1] == id;
            if (bounds_nothing) area = 0;
            try self.cycles.append(allocator, .{ .first_half = first, .count = @intCast(self.cycle_halves.items.len - first), .area = area / 2.0 });
        }
    }

    fn clockwiseOfTwin(self: *const Overlay, half: u32) u32 {
        const twin = half ^ 1;
        const v = self.origin(twin);
        const halves = self.out.items[self.out_start.items[v]..self.out_start.items[v + 1]];
        const k = self.slot.items[twin];
        return halves[(k + halves.len - 1) % halves.len];
    }

    /// Twice the half-edge's share of its cycle's area (Green's theorem): the chord's
    /// `a × b` about `from`, a point of the cycle (about the world's origin, a sliver 1e7
    /// out summed terms of 1e14 to an area of 0), plus an arc's segment `r² (θ − sin θ)`
    /// with the sign of its turn.
    fn areaTerm(self: *const Overlay, half: u32, from: Vec2) f64 {
        const a = self.point(self.origin(half));
        const b = self.point(self.target(half));
        var twice = chordTerm(a, b, from);
        if (self.arcOf(half)) |arc| {
            const theta = arcSpan(a, b, arc).sweep;
            const segment = arc.r * arc.r * (theta - @sin(theta));
            twice += if (arc.ccw) segment else -segment;
        }
        return twice;
    }

    // --- faces ---

    /// Each counter-clockwise cycle bounds a face; each clockwise one is a hole of the
    /// face it lies in (`nestCycles`), else of the plane.
    fn nest(self: *Overlay) Error!void {
        const allocator = self.allocator;
        self.faces.clearRetainingCapacity();
        self.face_holes.clearRetainingCapacity();
        const n = self.cycles.items.len;
        for (self.cycles.items, 0..) |*c, i| {
            c.face = UNBOUNDED;
            if (c.area > 0) {
                c.face = @intCast(self.faces.items.len);
                try self.faces.append(allocator, .{ .outer = @intCast(i) });
            }
        }
        // Every half-edge as a segment of its cycle, the cycles' halves being laid out
        // one cycle after another
        const segments = try allocator.alloc(Segment, self.cycle_halves.items.len);
        defer allocator.free(segments);
        const starts = try allocator.alloc(u32, n + 1);
        defer allocator.free(starts);
        const areas = try allocator.alloc(f64, n);
        defer allocator.free(areas);
        for (self.cycles.items, 0..) |c, i| {
            starts[i] = c.first_half;
            areas[i] = c.area;
            for (self.halvesOf(@intCast(i)), c.first_half..) |h, k| {
                segments[k] = .{ .a = self.point(self.origin(h)), .b = self.point(self.target(h)), .arc = self.arcOf(h), .cycle = @intCast(i), .beyond = self.cycle_of.items[h ^ 1], .slot_a = self.slot.items[h], .slot_b = self.slot.items[h ^ 1] };
            }
        }
        starts[n] = @intCast(self.cycle_halves.items.len);
        const owner = try allocator.alloc(u32, n);
        defer allocator.free(owner);
        try nestCycles(allocator, segments, starts, areas, self.tol.zone, owner);
        for (self.cycles.items, owner) |*c, within| {
            if (c.area > 0) continue;
            c.face = if (within == UNBOUNDED) UNBOUNDED else self.cycles.items[within].face;
        }
        for (self.faces.items, 0..) |*f, fi| {
            f.first_hole = @intCast(self.face_holes.items.len);
            for (self.cycles.items, 0..) |c, ci| if (c.area <= 0 and c.face == fi) try self.face_holes.append(allocator, @intCast(ci));
            f.hole_count = @intCast(self.face_holes.items.len - f.first_hole);
        }
    }

    // --- windings ---

    /// The windings of every face per input, from the unbounded face (none) across each
    /// edge: an input's edge running with the half-edge has its region to the left.
    fn label(self: *Overlay) Error!void {
        const allocator = self.allocator;
        const n_faces = self.faces.items.len;
        try self.windings.resize(allocator, n_faces * self.inputs);
        @memset(self.windings.items, 0);
        const known = try allocator.alloc(bool, n_faces);
        defer allocator.free(known);
        @memset(known, false);
        var queue = std.ArrayList(u32).empty;
        defer queue.deinit(allocator);
        var pending = n_faces;
        while (pending > 0) {
            // A seed: a face next to the plane or to a known face, through the half-edge
            // from the known side
            var seed: ?u32 = null;
            for (0..self.edges.items.len) |e| {
                for ([_]u32{ @intCast(2 * e), @intCast(2 * e + 1) }) |h| {
                    const left = self.leftOf(h);
                    const right = self.leftOf(h ^ 1);
                    if (left != UNBOUNDED and !known[left] and (right == UNBOUNDED or known[right])) seed = h;
                }
                if (seed != null) break;
            }
            const start = seed orelse break;
            try self.cross(start);
            known[self.leftOf(start)] = true;
            pending -= 1;
            try queue.append(allocator, self.leftOf(start));
            while (queue.pop()) |face| {
                for (self.halvesOf(self.faces.items[face].outer)) |h| try self.spread(h, known, &queue, &pending);
                for (self.holesOf(face)) |hole| for (self.halvesOf(hole)) |h| try self.spread(h, known, &queue, &pending);
            }
        }
    }

    /// From the face left of `half`, across to the face right of it, when unknown.
    fn spread(self: *Overlay, half: u32, known: []bool, queue: *std.ArrayList(u32), pending: *usize) Error!void {
        const twin = half ^ 1;
        const beyond = self.leftOf(twin);
        if (beyond == UNBOUNDED or known[beyond]) return;
        try self.cross(twin);
        known[beyond] = true;
        pending.* -= 1;
        try queue.append(self.allocator, beyond);
    }

    /// Sets the windings of the face left of `half` from the face right of it (none for
    /// the plane) and the edge's contributions.
    fn cross(self: *Overlay, half: u32) Error!void {
        const left = self.leftOf(half);
        const right = self.leftOf(half ^ 1);
        const e = self.edges.items[half / 2];
        const inputs = self.inputs;
        for (0..inputs) |k| self.windings.items[left * inputs + k] = if (right == UNBOUNDED) 0 else self.windings.items[right * inputs + k];
        for (self.contributions.items[e.first_contribution..][0..e.contributions]) |c| {
            const with_half = c.along == (half % 2 == 0);
            self.windings.items[left * inputs + c.input] += if (with_half) 1 else -1;
        }
    }

    // --- selection ---

    /// The boundary of the region of the faces `keep` says yes to, as cycles of half-edges
    /// with the region to their left, into `halves` and `starts` (a cycle is
    /// `halves[starts[i]..starts[i + 1]]`).
    pub fn boundary(self: *const Overlay, keep: []const bool, halves: *std.ArrayList(u32), starts: *std.ArrayList(u32)) Error!void {
        const allocator = self.allocator;
        halves.clearRetainingCapacity();
        starts.clearRetainingCapacity();
        const n_halves = 2 * self.edges.items.len;
        const visited = try allocator.alloc(bool, n_halves);
        defer allocator.free(visited);
        @memset(visited, false);
        for (0..n_halves) |start| {
            if (visited[start] or !self.onBoundary(@intCast(start), keep)) continue;
            try starts.append(allocator, @intCast(halves.items.len));
            var h: u32 = @intCast(start);
            while (!visited[h]) : (h = self.nextOnBoundary(h, keep)) {
                visited[h] = true;
                try halves.append(allocator, h);
            }
        }
        try starts.append(allocator, @intCast(halves.items.len));
    }

    fn onBoundary(self: *const Overlay, half: u32, keep: []const bool) bool {
        const left = self.leftOf(half);
        const right = self.leftOf(half ^ 1);
        const kept_left = left != UNBOUNDED and keep[left];
        const kept_right = right != UNBOUNDED and keep[right];
        return kept_left and !kept_right;
    }

    /// The boundary half-edge following `half`: the first clockwise of its twin about its
    /// target that bounds the region.
    fn nextOnBoundary(self: *const Overlay, half: u32, keep: []const bool) u32 {
        const twin = half ^ 1;
        const v = self.origin(twin);
        const halves = self.out.items[self.out_start.items[v]..self.out_start.items[v + 1]];
        var k: usize = self.slot.items[twin];
        for (0..halves.len) |_| {
            k = (k + halves.len - 1) % halves.len;
            if (self.onBoundary(halves[k], keep)) return halves[k];
        }
        unreachable;
    }
};

/// An arc's angular extent: from `start` (the angle of its first end about the centre),
/// through `sweep` radians the way it turns.
const Span = struct {
    start: f64,
    sweep: f64,
    ccw: bool,

    /// How far along the arc the angle `angle` lies, in radians from its start, when it
    /// lies on the arc's extent; else null.
    fn offsetOf(self: Span, angle: f64) ?f64 {
        var t = if (self.ccw) angle - self.start else self.start - angle;
        t = @mod(t, 2 * std.math.pi);
        if (t > self.sweep + SPAN_SLACK) {
            if (t > 2 * std.math.pi - SPAN_SLACK) return 0;
            return null;
        }
        return @min(t, self.sweep);
    }

    fn holds(self: Span, angle: f64) bool {
        return self.offsetOf(angle) != null;
    }
};

/// The point the curve from `a` to `b` (straight, or along `arc`) is ordered by among the
/// curves leaving `a`: `ORDER_REACH` zones along it, or its middle when it is shorter
/// than twice that; `b` itself for a line, whose direction from `a` is the same anywhere
/// along it and exact there. The overlay's order about a vertex goes by it, and so does
/// the offset's turn at a cusp (offset.zig), so the two read curves leaving a vertex one
/// way alike.
/// Which way a boundary turns at `v`, arriving along the curve from `a` (straight, or along
/// `arc`) with tangent `t1` there and leaving along the curve to `b` (straight, or along
/// `next_arc`) with tangent `t2`: positive to the left, negative to the right. Within a
/// quarter turn of straight on, the tangents' cross: the turn's size and side are the
/// tangents' alone, however the curves bend. Past it, the side as the overlay orders the
/// two curves about `v` (`orderSample`, the predicate exact on those points), +1 or −1: at
/// a cusp (an arc ending tangent to a line) the tangents oppose and their cross is 0 or a
/// rounding either way, while the turn is a half turn to the side the face lies on, which
/// only the curves' bend tells; elsewhere the two agree, the overlay having cut the curves
/// where they cross. The offset's corners and the convexity query decide a corner by it
/// (the fuzzer, 2026-11-14: a round join at a cusp left out in place and put in turned;
/// a reflex cusp taken for convex).
pub fn turnAt(v: Vec2, a: Vec2, arc: ?Arc, t1: Vec2, b: Vec2, next_arc: ?Arc, t2: Vec2, zone: f64) f64 {
    if (vec.dot2(t1, t2) >= 0) return vec.cross2(t1, t2);
    const back: ?Arc = if (arc) |circle| .{ .c = circle.c, .r = circle.r, .ccw = !circle.ccw } else null;
    const behind = orderSample(v, a, back, zone);
    const ahead = orderSample(v, b, next_arc, zone);
    // Left when the curve back lies within a half turn counter-clockwise of the one ahead:
    // the face, between them that way round, is the narrower side
    const side = predicates.orient2d(v, ahead, behind);
    return if (side > 0) 1 else if (side < 0) -1 else 0;
}

pub fn orderSample(a: Vec2, b: Vec2, arc: ?Arc, zone: f64) Vec2 {
    const circle = arc orelse return b;
    const span = arcSpan(a, b, circle);
    const s = @min(ORDER_REACH * zone, circle.r * span.sweep / 2.0);
    const angle = span.start + (if (circle.ccw) s else -s) / circle.r;
    return vec.addScaled2(circle.c, .{ @cos(angle), @sin(angle) }, circle.r);
}

/// Twice the signed area of the triangle `from`, `a`, `b`: a chord's share of its cycle's
/// area, about a point of the cycle so that the terms are as small as the cycle (the sum
/// is the same about any point, its rounding is not).
pub fn chordTerm(a: Vec2, b: Vec2, from: Vec2) f64 {
    return vec.cross2(vec.sub2(a, from), vec.sub2(b, from));
}

pub fn arcSweep(a: Vec2, b: Vec2, arc: Arc) f64 {
    return arcSpan(a, b, arc).sweep;
}

fn arcSpan(a: Vec2, b: Vec2, arc: Arc) Span {
    const start = trig.atan2(a[1] - arc.c[1], a[0] - arc.c[0]);
    const end = trig.atan2(b[1] - arc.c[1], b[0] - arc.c[0]);
    var sweep = if (arc.ccw) end - start else start - end;
    sweep = @mod(sweep, 2 * std.math.pi);
    if (sweep < SPAN_SLACK) sweep = 2 * std.math.pi;
    return .{ .start = start, .sweep = sweep, .ccw = arc.ccw };
}

/// Whether `p` lies within the arc's turn from `a` to `b` about its centre, strictly
/// between the ends' radii: for a counter-clockwise arc, within the counter-clockwise
/// turn from the radius through `a` to the radius through `b`. Exact, by `orient2d`
/// about the centre (D26): no angle decides, so there is no seam and no slack, and the
/// answer for a point a little off the circle (a welded vertex within the zone of it) is
/// the same whichever piece of the arc asks, which a test against the chord is not. A
/// point on an end's own radius is that end, or the rounding of one.
fn onArcStrictly(a: Vec2, b: Vec2, arc: Arc, p: Vec2) bool {
    return strictlyOnArc(a, b, arc, .{ .point = p });
}

/// `onArcStrictly` of the circle's highest or lowest point, decided by the ends' own
/// coordinates against the centre's (`Place`).
fn extremeOnArcStrictly(a: Vec2, b: Vec2, arc: Arc, extreme: Extreme) bool {
    return strictlyOnArc(a, b, arc, .{ .extreme = extreme });
}

fn strictlyOnArc(a: Vec2, b: Vec2, arc: Arc, place: Place) bool {
    if (!arc.ccw) return strictlyOnArc(b, a, .{ .c = arc.c, .r = arc.r, .ccw = true }, place);
    const c = arc.c;
    const turn = predicates.orient2d(c, a, b);
    // Within the minor turn from `a` to `b`, or not within the one from `b` to `a`
    if (turn > 0) return place.after(c, a) and place.before(c, b);
    if (turn < 0) return !(place.after(c, b) and place.before(c, a)) and !place.onRayThrough(c, a) and !place.onRayThrough(c, b);
    // `b` on `a`'s radius or opposite it: a half circle, or (the ends welded) a full one
    if (vec.dot2(vec.sub2(a, c), vec.sub2(b, c)) < 0) return place.after(c, a);
    return !place.onRayThrough(c, a);
}

/// A circle's highest or lowest point: straight above or below its centre.
const Extreme = enum { top, bottom };

/// What is asked of an arc's turn about its centre `c`: a point, by `orient2d`, or the
/// circle's highest or lowest point. An extreme is straight above or below the centre, so
/// which way round an end `q` is from it is which side of the centre's x the end's x is, a
/// comparison of two coordinates: the same comparison `ArcPieces` tells a piece's side by,
/// and one with no product in it to underflow, where `orient2d` of the extreme's point
/// multiplies the radius by the end's distance from the centre's x (0.25 times 5e-324,
/// the least double, rounds to nothing: the end reads as on the extreme's radius, no cut
/// is made at the extreme, and the piece from that end to the lowest point, the whole
/// west half, is told east by its end; the overlay fuzz target, 2026-11-20, bk).
const Place = union(enum) {
    point: Vec2,
    extreme: Extreme,

    /// Whether the place is strictly within the half turn counter-clockwise from the
    /// radius through `q`.
    fn after(self: Place, c: Vec2, q: Vec2) bool {
        return switch (self) {
            .point => |p| predicates.orient2d(c, q, p) > 0,
            .extreme => |extreme| if (extreme == .top) q[0] > c[0] else q[0] < c[0],
        };
    }

    /// Whether the place is strictly within the half turn clockwise from the radius
    /// through `q`.
    fn before(self: Place, c: Vec2, q: Vec2) bool {
        return switch (self) {
            .point => |p| predicates.orient2d(c, p, q) > 0,
            .extreme => |extreme| if (extreme == .top) q[0] < c[0] else q[0] > c[0],
        };
    }

    /// Whether the place lies on the ray from `c` through `q`.
    fn onRayThrough(self: Place, c: Vec2, q: Vec2) bool {
        return switch (self) {
            .point => |p| onRay(c, q, p),
            .extreme => |extreme| q[0] == c[0] and (if (extreme == .top) q[1] > c[1] else q[1] < c[1]),
        };
    }
};

/// Whether `p` lies on the ray from `c` through `a`.
fn onRay(c: Vec2, a: Vec2, p: Vec2) bool {
    return predicates.orient2d(c, a, p) == 0 and vec.dot2(vec.sub2(a, c), vec.sub2(p, c)) > 0;
}

/// How far along the arc from `a` to `b` the point `p` of it lies, in radians from `a`:
/// for ordering the cuts along an arc (a construction, never a decision: whether `p` is
/// on the arc is `onArcStrictly`'s). A rounding past either end is that end.
fn arcParam(a: Vec2, b: Vec2, arc: Arc, p: Vec2) f64 {
    const span = arcSpan(a, b, arc);
    const angle = trig.atan2(p[1] - arc.c[1], p[0] - arc.c[0]);
    const t = @mod(if (arc.ccw) angle - span.start else span.start - angle, 2 * std.math.pi);
    if (t <= span.sweep) return t;
    return if (t - span.sweep < 2 * std.math.pi - t) span.sweep else 0;
}

/// The y-monotone pieces of an arc from `a` to `b`, with the heights of their ends: the
/// ends' own points at the arc's ends, never the circle's point at the end's angle, which
/// may differ by a rounding (2 − 1.2e-16 is the double below 2) while the edge beyond the
/// vertex counts the vertex by its point; the circle's top and bottom at the extremes
/// between. Pieces that short are kept: the half-open rule then agrees at every vertex.
/// A piece's side of the centre is told by its ends, exactly (D26): an end is a vertex or
/// an extreme, the extremes at the centre's x, and the arc is cut at an extreme just when
/// its ends lie strictly either side of it in x, both decided by the one comparison of an
/// end's x with the centre's (`Place`), so a piece's ends are never on opposite sides and
/// the first of them off the centre's x tells the side; a piece between
/// the two extremes, both at that x, is a half circle and lies where its arc runs that way
/// (a counter-clockwise arc goes down its west half). Never by the angle of its middle: a
/// piece 4.4e-16 wide between a vertex and the lowest point has its middle within a
/// rounding of straight below the centre, whose cosine is of either sign, and its two
/// half-edges read it on opposite sides (the overlay fuzz target, 2026-11-19, bj).
const ArcPieces = struct {
    /// The centre's x and the arc's sense: what a piece's side is told by.
    centre_x: f64,
    ccw: bool,
    cuts: [4]Cut,
    n: usize,
    at: usize = 0,

    const Cut = struct { t: f64, x: f64, y: f64 };

    const Piece = struct {
        y0: f64,
        y1: f64,
        /// The ends' x, exact where an end is a vertex or an extreme.
        x0: f64,
        x1: f64,
        /// The side of the centre the piece lies on: which crossing of its circle it is
        /// at any height.
        side: predicates.Side,
    };

    fn init(a: Vec2, b: Vec2, arc: Arc) ArcPieces {
        const span = arcSpan(a, b, arc);
        var cuts: [4]Cut = undefined;
        var n: usize = 0;
        cuts[n] = .{ .t = 0, .x = a[0], .y = a[1] };
        n += 1;
        for (std.enums.values(Extreme)) |extreme| {
            if (!extremeOnArcStrictly(a, b, arc, extreme)) continue;
            const at: Vec2 = .{ arc.c[0], if (extreme == .top) arc.c[1] + arc.r else arc.c[1] - arc.r };
            cuts[n] = .{ .t = arcParam(a, b, arc, at), .x = at[0], .y = at[1] };
            n += 1;
        }
        cuts[n] = .{ .t = span.sweep, .x = b[0], .y = b[1] };
        n += 1;
        std.mem.sort(Cut, cuts[0..n], {}, struct {
            fn lessThan(_: void, x: Cut, y: Cut) bool {
                return x.t < y.t;
            }
        }.lessThan);
        return .{ .centre_x = arc.c[0], .ccw = arc.ccw, .cuts = cuts, .n = n };
    }

    fn next(self: *ArcPieces) ?Piece {
        if (self.at + 1 >= self.n) return null;
        const c0 = self.cuts[self.at];
        const c1 = self.cuts[self.at + 1];
        self.at += 1;
        return .{ .y0 = c0.y, .y1 = c1.y, .x0 = c0.x, .x1 = c1.x, .side = self.sideOf(c0, c1) };
    }

    /// The far end of the piece that meets the one `next` just gave at that one's lower
    /// end: the piece after it when it ran down to that end (`descending`), the one before
    /// it when it ran up from it. Null when the lower end is the arc's own, no cut at an
    /// extreme of its circle.
    fn pastLowerEnd(self: *const ArcPieces, descending: bool) ?Vec2 {
        if (if (descending) self.at + 1 >= self.n else self.at < 2) return null;
        const cut = self.cuts[if (descending) self.at + 1 else self.at - 2];
        return .{ cut.x, cut.y };
    }

    fn sideOf(self: *const ArcPieces, c0: Cut, c1: Cut) predicates.Side {
        for ([_]f64{ c0.x, c1.x }) |x| {
            if (x != self.centre_x) return if (x > self.centre_x) .east else .west;
        }
        const descending = c0.y > c1.y;
        return if (descending == self.ccw) .west else .east;
    }
};

/// Whether the ray from `p` to +x crosses the arc an odd number of times: each y-monotone
/// piece counted on the half-open rule as a straight edge would be, the piece's x at the
/// height against `p`'s by the exact predicate (`p` as a circle of no radius).
pub fn arcCrossings(a: Vec2, b: Vec2, arc: Arc, p: Vec2) bool {
    var pieces = ArcPieces.init(a, b, arc);
    var odd = false;
    while (pieces.next()) |piece| {
        if ((piece.y0 > p[1]) == (piece.y1 > p[1])) continue;
        if (predicates.compareArcX(arc.c, arc.r, piece.side, p, 0, .east, p[1]) > 0) odd = !odd;
    }
    return odd;
}

/// A segment of a cycle for `nestCycles`: from `a` to `b`, straight or along `arc`, run
/// by `cycle` with its region on the left; `beyond` is the cycle on its other side, when
/// known (the overlay's twin half-edge), else `UNBOUNDED`.
pub const Segment = struct {
    a: Vec2,
    b: Vec2,
    arc: ?Arc = null,
    cycle: u32,
    beyond: u32 = UNBOUNDED,
    /// Where the segment leaves `a` and `b` in the overlay's order about each (`slot` of
    /// the half-edge leaving the vertex along it), when it is the overlay's: two segments
    /// tied on the nesting ray at a vertex they share are ordered by these, the order the
    /// cycles were walked by. `NO_SLOT` when unknown.
    slot_a: u32 = NO_SLOT,
    slot_b: u32 = NO_SLOT,
};

/// A segment end with no place in the overlay's order (`Segment.slot_a`).
pub const NO_SLOT: u32 = std.math.maxInt(u32);

/// The cycle each clockwise cycle lies in, into `owner`: the index of a counter-clockwise
/// cycle, or `UNBOUNDED` for a hole of the plane (and for the counter-clockwise cycles
/// themselves). Cycle `i` is `segments[starts[i]..starts[i + 1]]`, of signed area
/// `areas[i]`. By the textbook rule (BKOS §2.3), exact where the probe point was not:
/// the region just left of a hole's leftmost (then lowest) vertex is the hole's face,
/// since the hole lies to that vertex's right with its corner within the closed right
/// half-plane; the ray from the vertex to −x, just above it (the half-open rule), reaches
/// the nearest segment it crosses, and the face is on that segment's left when the
/// segment runs down through the ray, else beyond it. Where the ray meets a vertex,
/// the segments up from it tie at its x, and the most clockwise of them (the tangent,
/// then the bend) bounds the region east of it. A clockwise cycle found that way lies in
/// the same face and reaches further left, so the owners resolve in a bounded chain.
pub fn nestCycles(allocator: std.mem.Allocator, segments: []const Segment, starts: []const u32, areas: []const f64, zone: f64, owner: []u32) error{OutOfMemory}!void {
    const n = areas.len;
    const parent = try allocator.alloc(u32, n);
    defer allocator.free(parent);
    for (0..n) |i| {
        owner[i] = UNBOUNDED;
        parent[i] = UNBOUNDED;
        if (areas[i] > 0) continue;
        // The cycle's leftmost point: a vertex, or an arc's west extreme when the arc
        // bulges past its ends. The point is compared with the crossings as what it is:
        // a vertex by its own x, an extreme as the arc's own crossing there (its x as a
        // number is a rounding of `cx − r`, which the exact comparison would put a hair
        // off the arc's crossing, and the cycle's own segment must be passed, never hit).
        // An extreme within the zone of the arc's end is that end, as the welding has it:
        // every edge leaving the vertex crosses the ray there a rounding to either side of
        // the extreme, and one taken for a hit to its west nests the cycle in its own
        // region (the overlay fuzz target, 2026-11-12: a circle's west extreme a rounding
        // below the vertex its half and a lens arc leave, the lens arc's radius rounded to
        // cross west of it, a component's outer boundary a hole of one of its faces)
        var v = segments[starts[i]].a;
        var v_at: Crossing = .{ .point = v[0] };
        for (segments[starts[i]..starts[i + 1]]) |s| {
            if (lefter(s.a, v)) {
                v = s.a;
                v_at = .{ .point = v[0] };
            }
            if (s.arc) |arc| {
                const west: Vec2 = .{ arc.c[0] - arc.r, arc.c[1] };
                const at_end = vec.distance2(west, s.a) <= zone or vec.distance2(west, s.b) <= zone;
                if (!at_end and onArcStrictly(s.a, s.b, arc, west) and lefter(west, v)) {
                    v = west;
                    v_at = .{ .arc = .{ .c = arc.c, .r = arc.r, .side = .west } };
                }
            }
        }
        var best: ?Hit = null;
        for (segments) |s| {
            if (s.arc) |arc| {
                var pieces = ArcPieces.init(s.a, s.b, arc);
                while (pieces.next()) |piece| {
                    if ((piece.y0 > v[1]) == (piece.y1 > v[1])) continue;
                    const where: Crossing = if (v[1] == piece.y0) .{ .point = piece.x0 } else if (v[1] == piece.y1) .{ .point = piece.x1 } else .{ .arc = .{ .c = arc.c, .r = arc.r, .side = piece.side } };
                    if (compareCrossings(where, v_at, v[1]) >= 0) continue;
                    // The tangent up from the crossing, and which way the arc bends
                    // going up: a counter-clockwise arc turns left (west)
                    const descending = piece.y0 > piece.y1;
                    const at: Vec2 = .{ crossingX(where, v[1]), v[1] };
                    const top: Vec2 = if (descending) .{ piece.x0, piece.y0 } else .{ piece.x1, piece.y1 };
                    const bottom: Vec2 = if (descending) .{ piece.x1, piece.y1 } else .{ piece.x0, piece.y0 };
                    // A piece's end is the arc's own end or an extreme (no vertex there)
                    const slot_top = slotAt(s, top);
                    const slot_bottom = slotAt(s, bottom);
                    // Up from an extreme of its circle on the ray (its lowest point): the
                    // arc goes on past it, to where its other piece there ends
                    const past: ?Vec2 = if (bottom[1] == v[1]) pieces.pastLowerEnd(descending) else null;
                    const radial = vec.sub2(at, arc.c);
                    var up = Vec2{ -radial[1], radial[0] };
                    // Level at the circle's lowest point: the piece on the east half leaves
                    // it east, the west one west (its top can be straight above the lowest
                    // point, a half-turn round: the overlay fuzz target, 2026-11-13)
                    if (up[1] < 0 or (up[1] == 0 and (up[0] > 0) != (piece.side == .east))) up = vec.scale2(up, -1);
                    const up_ccw = if (descending) !arc.ccw else arc.ccw;
                    const bend = if (up_ccw) -1 / arc.r else 1 / arc.r;
                    consider(&best, .{ .at = where, .up = up, .bend = bend, .top = top, .bottom = bottom, .slot_top = slot_top, .slot_bottom = slot_bottom, .past = past orelse bottom, .slot_past = if (past) |end| slotAt(s, end) else NO_SLOT, .cycle = if (descending) s.cycle else s.beyond }, v[1]);
                }
                continue;
            }
            if ((s.a[1] > v[1]) == (s.b[1] > v[1])) continue;
            const where: Crossing = if (v[1] == s.a[1]) .{ .point = s.a[0] } else if (v[1] == s.b[1]) .{ .point = s.b[0] } else .{ .line = .{ .a = s.a, .b = s.b } };
            if (compareCrossings(where, v_at, v[1]) >= 0) continue;
            const descending = s.a[1] > s.b[1];
            const up = if (descending) vec.sub2(s.a, s.b) else vec.sub2(s.b, s.a);
            const top = if (descending) s.a else s.b;
            const bottom = if (descending) s.b else s.a;
            consider(&best, .{ .at = where, .up = up, .bend = 0, .top = top, .bottom = bottom, .slot_top = if (descending) s.slot_a else s.slot_b, .slot_bottom = if (descending) s.slot_b else s.slot_a, .cycle = if (descending) s.cycle else s.beyond }, v[1]);
        }
        if (best) |hit| parent[i] = hit.cycle;
    }
    for (0..n) |i| {
        if (areas[i] > 0) continue;
        var within = parent[i];
        var steps: usize = 0;
        while (within != UNBOUNDED and areas[within] <= 0) : (steps += 1) {
            // A chain of holes reaches further left each step and cannot loop; bounded all
            // the same, so that no input can make this spin
            if (steps > n) {
                within = UNBOUNDED;
                break;
            }
            within = parent[within];
        }
        owner[i] = within;
    }
}

/// Where a segment crosses the ray's height, as the exact predicates compare it
/// (`compareCrossings`): a vertex or an extreme on the ray by its own x, else the line
/// through two points or the `side` crossing of a circle, never a computed x.
const Crossing = union(enum) {
    point: f64,
    line: struct { a: Vec2, b: Vec2 },
    arc: struct { c: Vec2, r: f64, side: predicates.Side },
};

/// The sign of `p − q` in x at height `y`, exact. A point is the crossing of a circle of
/// no radius through it, which the predicates take as it is.
fn compareCrossings(p: Crossing, q: Crossing, y: f64) f64 {
    return switch (p) {
        .point => |x| switch (q) {
            .point => |xq| if (x > xq) 1 else if (x < xq) -1 else 0,
            .line => |l| predicates.compareArcXWithLine(.{ x, y }, 0, .east, y, l.a, l.b).?,
            .arc => |c| -predicates.compareArcX(c.c, c.r, c.side, .{ x, y }, 0, .east, y),
        },
        .line => |l| switch (q) {
            .point, .arc => -compareCrossings(q, p, y),
            .line => |m| predicates.compareLineX(y, l.a, l.b, m.a, m.b).?,
        },
        .arc => |c| switch (q) {
            .point => |xq| predicates.compareArcX(c.c, c.r, c.side, .{ xq, y }, 0, .east, y),
            .line => |l| predicates.compareArcXWithLine(c.c, c.r, c.side, y, l.a, l.b).?,
            .arc => |d| predicates.compareArcX(c.c, c.r, c.side, d.c, d.r, d.side, y),
        },
    };
}

/// The crossing's x at height `y`, as a number: for the sample along the segment, never
/// for a comparison.
fn crossingX(c: Crossing, y: f64) f64 {
    return switch (c) {
        .point => |x| x,
        .line => |l| l.a[0] + (y - l.a[1]) * (l.b[0] - l.a[0]) / (l.b[1] - l.a[1]),
        .arc => |a| {
            const dy = y - a.c[1];
            const dx = @sqrt(@max(a.r * a.r - dy * dy, 0));
            return if (a.side == .east) a.c[0] + dx else a.c[0] - dx;
        },
    };
}

/// A crossing of the ray from a hole's leftmost vertex to −x.
const Hit = struct {
    at: Crossing,
    /// The tangent up from the crossing along the segment (any length), and how the
    /// segment bends going up: the signed curvature, positive bending east (right).
    up: Vec2,
    bend: f64,
    /// The segment's (or arc piece's) ends above the ray and at or below it, exactly as
    /// given: two segments that tie meet at one of them.
    top: Vec2,
    bottom: Vec2,
    /// Where the segment leaves each of those ends in the overlay's order about it, or
    /// `NO_SLOT` (an arc piece's end at an extreme, a segment not the overlay's).
    slot_top: u32 = NO_SLOT,
    slot_bottom: u32 = NO_SLOT,
    /// For an arc's piece up from an extreme of its circle on the ray (its lowest point,
    /// no vertex): where the arc's other piece at that point ends, and the arc's slot
    /// there, or `NO_SLOT` when that is the circle's other extreme. The two pieces meet
    /// the ray at the one point with only the inside of their circle between them, where
    /// no segment that crosses the ray passes: one that shares an end with either piece is
    /// on the same side of both, and is ordered against both about that end.
    past: Vec2 = .{ 0, 0 },
    slot_past: u32 = NO_SLOT,
    /// The cycle whose region is just east of the crossing.
    cycle: u32,

    /// A vertex the hit's segment leaves, with its slot there.
    const End = struct { at: Vec2, slot: u32 };

    /// The segment's vertices above the ray at `y` (`above`) or at or below it, with the
    /// slots it leaves them by: the piece's own end, and the arc's end past an extreme on
    /// the ray (`past`).
    fn ends(self: Hit, above: bool, y: f64) [2]End {
        const own: End = if (above) .{ .at = self.top, .slot = self.slot_top } else .{ .at = self.bottom, .slot = self.slot_bottom };
        const beyond: End = .{ .at = self.past, .slot = if ((self.past[1] > y) == above) self.slot_past else NO_SLOT };
        return .{ own, beyond };
    }
};

/// Keeps the hit nearer the vertex. Two segments sharing a vertex are ordered as the
/// overlay ordered them about it (`orderAtSharedVertex`), the order its cycles were walked
/// by: the segments of an arrangement cross nowhere but at their ends, so along any height
/// between their shared vertex and their other ends their order is the one they leave the
/// vertex in, whatever the exact crossings say where an arc's welded end is a rounding off
/// its circle (the overlay fuzz target, 2026-11-12: a ray a rounding above a vertex an arc
/// and a line leave upward found the arc west of the line, its radius rounded). Otherwise
/// the greater x, exactly. A tie with no shared vertex the order knows takes the ray a
/// hair above, the segments fanning up from the point: the one leaning east going up, then, level and opposite (an arc's two pieces
/// at its lowest point on the ray, an extreme and no vertex), the one pointing east, then
/// of two tangent the same way the one bending east. (Re-deriving the order at a shared
/// vertex from tangents got two cases wrong, both fuzz finds of 2026-11-12: a vertex a
/// rounding above the ray, which the segments fan down from, and two arcs level and
/// opposite at their common lowest point, whose cross product is 0. A tie at an extreme
/// on the ray fans up only: pieces from an extreme at the ray's height and down are not
/// crossings, by the half-open rule.)
fn consider(best: *?Hit, hit: Hit, y: f64) void {
    const b = best.* orelse {
        best.* = hit;
        return;
    };
    if (orderAtSharedVertex(hit, b, y)) |hit_nearer| {
        if (hit_nearer) best.* = hit;
        return;
    }
    const order = compareCrossings(hit.at, b.at, y);
    if (order != 0) {
        if (order > 0) best.* = hit;
        return;
    }
    const turn = vec.cross2(hit.up, b.up);
    if (turn != 0) {
        if (turn > 0) best.* = hit;
        return;
    }
    if (vec.dot2(hit.up, b.up) < 0) {
        if (hit.up[0] > 0) best.* = hit;
        return;
    }
    if (hit.bend > b.bend) best.* = hit;
}

/// Two hits at height `y` that share a vertex, ordered as the overlay ordered their
/// half-edges about it (the slots, counter-clockwise from east by the direction to a point
/// a few zones along each, `order()`): fanning up from a vertex on or below the ray, the
/// one leaving it further east (the lower slot) is the nearer just above; fanning down
/// from one above it (a rounding above, where their circles cross at its height), the one
/// leaving it further east going down (the higher slot, the lower half running from west
/// round to east) is the nearer. When they share both ends, the end nearer the ray. Null
/// when they share no vertex the order knows: the lean and the bend decide.
///
/// An arc's piece up from its lowest point on the ray shares its arc's end past that point
/// too (`Hit.past`), as the arc's other piece there does: left to its own ends, the piece
/// was ordered against a line from that end by their exact crossings, the lowest point's
/// x against the line's, while the piece that ends there was ordered about the vertex,
/// and the two answers differed where the vertex is a rounding off the lowest point (the
/// overlay fuzz target, 2026-11-20, bo: a line through a circle's lowest point, their
/// welded vertex 1.8e-15 east of it and 4e-15 above; the line crossed the ray 2e-16 west
/// of the point, east of it about the vertex. The line beat the east piece, the west
/// piece beat the line, the east piece the west: the hit kept was whichever came last,
/// and an island east of the line was placed west of it).
fn orderAtSharedVertex(p: Hit, q: Hit, y: f64) ?bool {
    const top = sharedEnd(p.ends(true, y), q.ends(true, y));
    const bottom = sharedEnd(p.ends(false, y), q.ends(false, y));
    if (top == null and bottom == null) return null;
    const down = if (top != null and bottom != null) top.?.y - y < y - bottom.?.y else top != null;
    if (down) {
        if (top.?.p == top.?.q) return null;
        return top.?.p > top.?.q;
    }
    if (bottom.?.p == bottom.?.q) return null;
    return bottom.?.p < bottom.?.q;
}

/// The first vertex two hits' segments both leave, among `ps` of the one and `qs` of the
/// other, with its height and the slot each leaves it by; null when they share none the
/// overlay's order knows.
fn sharedEnd(ps: [2]Hit.End, qs: [2]Hit.End) ?struct { y: f64, p: u32, q: u32 } {
    for (ps) |a| for (qs) |b| {
        if (a.slot != NO_SLOT and b.slot != NO_SLOT and a.at[0] == b.at[0] and a.at[1] == b.at[1]) return .{ .y = a.at[1], .p = a.slot, .q = b.slot };
    };
    return null;
}

/// The slot of segment `s` at its end `at` (exactly `s.a` or `s.b`), or `NO_SLOT` at a
/// point between them (an arc's extreme).
fn slotAt(s: Segment, at: Vec2) u32 {
    if (at[0] == s.a[0] and at[1] == s.a[1]) return s.slot_a;
    if (at[0] == s.b[0] and at[1] == s.b[1]) return s.slot_b;
    return NO_SLOT;
}

/// Whether `p` is left of `q`: by x, then by y.
/// How far the segment `a`–`b` strays from the circle of `arc`, inside or out: the
/// distance from the centre is convex along a line, least at the foot of the
/// perpendicular (or an end), greatest at an end.
fn segmentApart(a: Vec2, b: Vec2, arc: Arc) f64 {
    const d = vec.sub2(b, a);
    const len_sq = vec.dot2(d, d);
    const s = if (len_sq == 0) 0 else std.math.clamp(vec.dot2(vec.sub2(arc.c, a), d) / len_sq, 0, 1);
    const nearest = vec.distance2(vec.addScaled2(a, d, s), arc.c);
    const farthest = @max(vec.distance2(a, arc.c), vec.distance2(b, arc.c));
    return @max(arc.r - nearest, farthest - arc.r);
}

/// How far the stretch from `a` to `b` of the arc `on` (run as it runs) strays from the
/// circle of `other`, inside or out: a point going round a circle is nearest and farthest
/// from another centre on the line of the two centres, so the stretch's ends and those
/// two points of it, where it holds them, bound it.
fn arcStretchApart(a: Vec2, b: Vec2, on: Arc, other: Arc) f64 {
    var apart = @max(@abs(vec.distance2(a, other.c) - other.r), @abs(vec.distance2(b, other.c) - other.r));
    const between = vec.sub2(other.c, on.c);
    const dist = vec.length2(between);
    if (dist == 0) return apart;
    for ([_]f64{ on.r, -on.r }) |along| {
        const q = vec.addScaled2(on.c, between, along / dist);
        if (onArcStrictly(a, b, on, q)) apart = @max(apart, @abs(vec.distance2(q, other.c) - other.r));
    }
    return apart;
}

/// The size of a point's larger coordinate: what its distances are rounded at.
fn magnitude2(p: Vec2) f64 {
    return @max(@abs(p[0]), @abs(p[1]));
}

fn lefter(p: Vec2, q: Vec2) bool {
    return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]);
}
