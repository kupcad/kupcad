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
const grid = @import("../spatial/grid.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

/// `OutOfRange`: a coordinate too far from the origin for the welder's grid.
pub const Error = error{ OutOfMemory, TooMany, OutOfRange };

/// The most inputs an overlay labels (a batch boolean's operands).
pub const MAX_INPUTS: usize = 1 << 16;
/// Edges meeting at one vertex at most.
const MAX_DEGREE: usize = 1 << 16;
/// How far inside a region its probe point sits, in zones.
const PROBE_ZONES: f64 = 4;
/// How far past an arc's end an angle may be and still count as on it, in radians.
const SPAN_SLACK: f64 = 1e-9;

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
    /// on one curve merged with their contributions summed.
    fn cutAll(self: *Overlay) Error!void {
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
        // The contributions grouped by edge
        std.mem.sort(Contribution, self.contributions.items, {}, Contribution.lessThan);
        for (self.edges.items) |*e| e.contributions = 0;
        for (self.contributions.items, 0..) |c, i| {
            const e = &self.edges.items[c.edge];
            if (e.contributions == 0) e.first_contribution = @intCast(i);
            e.contributions += 1;
        }
    }

    fn byMinX(boxes: []const Box, i: u32, j: u32) bool {
        return boxes[i].min[0] < boxes[j].min[0];
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
            n = self.arcArc(gi, gj, &candidates);
        } else {
            n = self.lineArc(if (gi.arc == null) gi else gj, if (gi.arc == null) gj else gi, &candidates);
        }
        for (candidates[0..n]) |p| {
            const v = try self.vertex(p);
            try self.cutAt(i, v, cuts);
            try self.cutAt(j, v, cuts);
        }
        // Each end of one on the other: a T-junction, or the end of an overlap
        for ([_]u32{ gj.a, gj.b }) |v| try self.cutAt(i, v, cuts);
        for ([_]u32{ gi.a, gi.b }) |v| try self.cutAt(j, v, cuts);
    }

    /// A cut of given edge `i` at vertex `v`, when `v` lies on it and is neither end.
    fn cutAt(self: *Overlay, i: u32, v: u32, cuts: *std.ArrayList(Cut)) Error!void {
        const g = self.given.items[i];
        if (v == g.a or v == g.b) return;
        if (self.paramOn(g, self.point(v))) |t| try cuts.append(self.allocator, .{ .given = i, .t = t, .vertex = v });
    }

    /// The parameter of `p` along a given edge when `p` lies inside it within the zone (a
    /// line's fraction of its length, an arc's angle from its start), else null.
    fn paramOn(self: *const Overlay, g: Given, p: Vec2) ?f64 {
        const a = self.point(g.a);
        const b = self.point(g.b);
        if (g.arc) |arc| {
            if (@abs(vec.length2(vec.sub2(p, arc.c)) - arc.r) > self.tol.zone) return null;
            const span = arcSpan(a, b, arc);
            const t = span.offsetOf(trig.atan2(p[1] - arc.c[1], p[0] - arc.c[0])) orelse return null;
            if (t <= 0 or t >= span.sweep) return null;
            return t;
        }
        const d = vec.sub2(b, a);
        const len = vec.length2(d);
        const t = vec.dot2(vec.sub2(p, a), d) / (len * len);
        if (t <= 0 or t >= 1) return null;
        if (vec.distance2(vec.addScaled2(a, d, t), p) > self.tol.zone) return null;
        return t;
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

    /// The crossings of a line segment and an arc, inside both.
    fn lineArc(self: *const Overlay, line: Given, arc_edge: Given, out: *[4]Vec2) usize {
        const arc = arc_edge.arc.?;
        const a = self.point(line.a);
        const d = vec.sub2(self.point(line.b), a);
        const f = vec.sub2(a, arc.c);
        const qa = vec.dot2(d, d);
        const qb = 2 * vec.dot2(f, d);
        const qc = vec.dot2(f, f) - arc.r * arc.r;
        const disc = qb * qb - 4 * qa * qc;
        if (disc < 0) return 0;
        const root = @sqrt(disc);
        const span = arcSpan(self.point(arc_edge.a), self.point(arc_edge.b), arc);
        var n: usize = 0;
        for ([_]f64{ (-qb - root) / (2 * qa), (-qb + root) / (2 * qa) }) |t| {
            if (t <= 0 or t >= 1) continue;
            const p = vec.addScaled2(a, d, t);
            const s = span.offsetOf(trig.atan2(p[1] - arc.c[1], p[0] - arc.c[0])) orelse continue;
            if (s <= 0 or s >= span.sweep) continue;
            if (n > 0 and vec.distance2(out[0], p) <= self.tol.zone) continue;
            out[n] = p;
            n += 1;
        }
        return n;
    }

    /// The crossings of two arcs inside both (cocircular arcs overlap along their ends).
    fn arcArc(self: *const Overlay, gi: Given, gj: Given, out: *[4]Vec2) usize {
        const ai = gi.arc.?;
        const aj = gj.arc.?;
        const between = vec.sub2(aj.c, ai.c);
        const dist = vec.length2(between);
        if (dist <= self.tol.zone) return 0;
        if (dist > ai.r + aj.r + self.tol.zone or dist < @abs(ai.r - aj.r) - self.tol.zone) return 0;
        // The radical line: `x` along the centres, `h` across it
        const x = (dist * dist + ai.r * ai.r - aj.r * aj.r) / (2 * dist);
        const h2 = ai.r * ai.r - x * x;
        const h = if (h2 > 0) @sqrt(h2) else 0;
        const along = vec.scale2(between, 1.0 / dist);
        const across = Vec2{ -along[1], along[0] };
        const foot = vec.addScaled2(ai.c, along, x);
        const span_i = arcSpan(self.point(gi.a), self.point(gi.b), ai);
        const span_j = arcSpan(self.point(gj.a), self.point(gj.b), aj);
        var n: usize = 0;
        for ([_]f64{ h, -h }) |side| {
            const p = vec.addScaled2(foot, across, side);
            const ti = span_i.offsetOf(trig.atan2(p[1] - ai.c[1], p[0] - ai.c[0])) orelse continue;
            const tj = span_j.offsetOf(trig.atan2(p[1] - aj.c[1], p[0] - aj.c[0])) orelse continue;
            if (ti <= 0 or ti >= span_i.sweep or tj <= 0 or tj >= span_j.sweep) continue;
            if (n > 0 and vec.distance2(out[0], p) <= self.tol.zone) continue;
            out[n] = p;
            n += 1;
        }
        return n;
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

    const Leaving = struct { tangent: Vec2, curvature: f64 };

    /// A half-edge's unit tangent at its origin, and its curvature there (positive
    /// turning left).
    fn leaving(self: *const Overlay, half: u32) Leaving {
        const a = self.point(self.origin(half));
        if (self.arcOf(half)) |arc| {
            const radial = vec.sub2(a, arc.c);
            const tangent = if (arc.ccw) Vec2{ -radial[1], radial[0] } else Vec2{ radial[1], -radial[0] };
            return .{ .tangent = vec.normalized2(tangent) orelse Vec2{ 1, 0 }, .curvature = if (arc.ccw) 1.0 / arc.r else -1.0 / arc.r };
        }
        const d = vec.sub2(self.point(self.target(half)), a);
        return .{ .tangent = vec.normalized2(d) orelse Vec2{ 1, 0 }, .curvature = 0 };
    }

    /// Whether `x` leaves its origin at a smaller angle than `y`, counter-clockwise from
    /// the positive x axis: by half-plane, then by the exact turn between the tangents; two
    /// tangents within the angle tolerance of each other (an arc tangent to a line or to
    /// another arc) by curvature, the one curving left further round. No angle is ever
    /// computed, so a tangent along the negative x axis has no seam to fall across.
    fn lessAbout(self: *const Overlay, x: u32, y: u32) bool {
        const lx = self.leaving(x);
        const ly = self.leaving(y);
        const turn = vec.cross2(lx.tangent, ly.tangent);
        if (vec.dot2(lx.tangent, ly.tangent) > 0 and @abs(turn) <= self.tol.angle) return lx.curvature < ly.curvature;
        const ux = upperHalf(lx.tangent);
        const uy = upperHalf(ly.tangent);
        if (ux != uy) return ux;
        if (turn != 0) return turn > 0;
        return x < y;
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
            while (self.cycle_of.items[h] == UNBOUNDED) : (h = self.next.items[h]) {
                self.cycle_of.items[h] = id;
                try self.cycle_halves.append(allocator, h);
                area += self.areaTerm(h);
            }
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
    /// `a × b`, plus an arc's segment `r² (θ − sin θ)` with the sign of its turn.
    fn areaTerm(self: *const Overlay, half: u32) f64 {
        const a = self.point(self.origin(half));
        const b = self.point(self.target(half));
        var twice = a[0] * b[1] - b[0] * a[1];
        if (self.arcOf(half)) |arc| {
            const theta = arcSpan(a, b, arc).sweep;
            const segment = arc.r * arc.r * (theta - @sin(theta));
            twice += if (arc.ccw) segment else -segment;
        }
        return twice;
    }

    // --- faces ---

    /// Each counter-clockwise cycle bounds a face; each clockwise one is a hole of the
    /// innermost face whose outer cycle holds a point of it, else of the plane.
    fn nest(self: *Overlay) Error!void {
        const allocator = self.allocator;
        self.faces.clearRetainingCapacity();
        self.face_holes.clearRetainingCapacity();
        for (self.cycles.items, 0..) |*c, i| {
            if (c.area > 0) {
                c.face = @intCast(self.faces.items.len);
                try self.faces.append(allocator, .{ .outer = @intCast(i) });
            }
        }
        const owner = try allocator.alloc(u32, self.cycles.items.len);
        defer allocator.free(owner);
        for (self.cycles.items, 0..) |c, i| {
            owner[i] = UNBOUNDED;
            if (c.area > 0) continue;
            const probe = self.insidePoint(@intCast(i));
            var best_area = std.math.inf(f64);
            for (self.faces.items, 0..) |f, fi| {
                const outer = self.cycles.items[f.outer];
                if (outer.area < best_area and self.contains(f.outer, probe)) {
                    best_area = outer.area;
                    owner[i] = @intCast(fi);
                }
            }
            self.cycles.items[i].face = owner[i];
        }
        for (self.faces.items, 0..) |*f, fi| {
            f.first_hole = @intCast(self.face_holes.items.len);
            for (owner, 0..) |o, ci| if (o == fi) try self.face_holes.append(allocator, @intCast(ci));
            f.hole_count = @intCast(self.face_holes.items.len - f.first_hole);
        }
    }

    /// A point just inside a cycle's region: a few zones to the left of its first
    /// half-edge's middle (for a hole, into the surrounding face), less than any edge is
    /// long.
    fn insidePoint(self: *const Overlay, cycle: u32) Vec2 {
        const half = self.cycle_halves.items[self.cycles.items[cycle].first_half];
        const a = self.point(self.origin(half));
        const b = self.point(self.target(half));
        var middle = vec.scale2(vec.add2(a, b), 0.5);
        var tangent = vec.normalized2(vec.sub2(b, a)) orelse Vec2{ 1, 0 };
        if (self.arcOf(half)) |arc| {
            const span = arcSpan(a, b, arc);
            const angle = span.start + span.sweep / 2.0 * (if (arc.ccw) @as(f64, 1) else -1);
            middle = vec.addScaled2(arc.c, .{ @cos(angle), @sin(angle) }, arc.r);
            const radial = vec.sub2(middle, arc.c);
            tangent = vec.normalized2(if (arc.ccw) Vec2{ -radial[1], radial[0] } else Vec2{ radial[1], -radial[0] }).?;
        }
        const left = Vec2{ -tangent[1], tangent[0] };
        return vec.addScaled2(middle, left, PROBE_ZONES * self.tol.zone);
    }

    /// Whether `p` is inside a cycle, by the crossings of the ray to +x with its edges,
    /// each y-monotone piece counted on the half-open rule.
    fn contains(self: *const Overlay, cycle: u32, p: Vec2) bool {
        var inside = false;
        for (self.halvesOf(cycle)) |h| {
            const a = self.point(self.origin(h));
            const b = self.point(self.target(h));
            if (self.arcOf(h)) |arc| {
                inside = inside != arcCrossings(a, b, arc, p);
            } else if ((a[1] > p[1]) != (b[1] > p[1])) {
                const x = a[0] + (p[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
                if (p[0] < x) inside = !inside;
            }
        }
        return inside;
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

fn arcSpan(a: Vec2, b: Vec2, arc: Arc) Span {
    const start = trig.atan2(a[1] - arc.c[1], a[0] - arc.c[0]);
    const end = trig.atan2(b[1] - arc.c[1], b[0] - arc.c[0]);
    var sweep = if (arc.ccw) end - start else start - end;
    sweep = @mod(sweep, 2 * std.math.pi);
    if (sweep < SPAN_SLACK) sweep = 2 * std.math.pi;
    return .{ .start = start, .sweep = sweep, .ccw = arc.ccw };
}

/// Whether the ray from `p` to +x crosses the arc an odd number of times: the arc cut at
/// its topmost and bottommost points into y-monotone pieces, each counted on the half-open
/// rule as a straight edge would be.
pub fn arcCrossings(a: Vec2, b: Vec2, arc: Arc, p: Vec2) bool {
    const span = arcSpan(a, b, arc);
    var cuts: [4]f64 = undefined;
    var n: usize = 0;
    cuts[n] = 0;
    n += 1;
    for ([_]f64{ std.math.pi / 2.0, -std.math.pi / 2.0 }) |extreme| {
        if (span.offsetOf(extreme)) |t| {
            if (t > 0 and t < span.sweep) {
                cuts[n] = t;
                n += 1;
            }
        }
    }
    cuts[n] = span.sweep;
    n += 1;
    std.mem.sort(f64, cuts[0..n], {}, std.sort.asc(f64));
    var odd = false;
    const sign: f64 = if (arc.ccw) 1 else -1;
    for (0..n - 1) |i| {
        const t0 = cuts[i];
        const t1 = cuts[i + 1];
        if (t1 - t0 <= SPAN_SLACK) continue;
        const y0 = arc.c[1] + arc.r * @sin(span.start + sign * t0);
        const y1 = arc.c[1] + arc.r * @sin(span.start + sign * t1);
        if ((y0 > p[1]) == (y1 > p[1])) continue;
        // The piece's x at p's height, on the side of the centre its middle is on
        const mid = span.start + sign * (t0 + t1) / 2.0;
        const dy = p[1] - arc.c[1];
        const dx = @sqrt(@max(arc.r * arc.r - dy * dy, 0));
        const x = if (@cos(mid) >= 0) arc.c[0] + dx else arc.c[0] - dx;
        if (p[0] < x) odd = !odd;
    }
    return odd;
}
