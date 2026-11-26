//! Where two planar faces meet (docs/architecture.md §7.2, §9.1): the closed set the two
//! faces share, as points and segments of the line their planes meet in, or the word that
//! they lie in one plane (whose overlap is the overlay's to find, §7.3). The faces may be
//! of one body (the checker's overlap rules, `query/overlap.zig`) or of two.
//!
//! On the line `L` the planes meet in, each face's share is bounded where its boundary
//! crosses the other face's plane, so those crossings (each edge's, by
//! `curve_surface.curvePlane`, an edge lying in the plane giving its ends) are every
//! point where "in both faces" can change along `L`. Sorted along `L`, each crossing and
//! the middle of each gap between two is classified against both faces
//! (`query/in_face.zig`); a run of crossings in both, each gap between them in both by its
//! middle, is a segment, and a crossing in both next to no such gap is a point. Tolerant
//! classification of 3D points (§6's second tier), never an angle: two faces are coplanar
//! when every edge of one lies in the other's plane, each of its ends within the
//! intersection tolerance and its vertex's gap of it (`crossings`).

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const in_face = @import("../query/in_face.zig");
const curve_surface = @import("curve_surface.zig");
const incidence = @import("../geometry/incidence.zig");
const canonical = @import("../geometry/canonical.zig");
const overlay_mod = @import("../sketch/overlay.zig");
const Body = body_mod.Body;
const Frame = geometry.Frame;
const Plane = curve_surface.Plane;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// A point where a face's boundary meets the other's plane, and its reach beyond the
/// tolerance: the gap of the vertex it is, 0 for an edge's crossing.
const Mark = struct { p: Vec3, gap: f64 };

pub const Relation = union(enum) {
    /// The faces share no point.
    apart,
    /// Their planes cross; what they share is in the pieces (maybe none).
    crossing,
    /// One lies in the other's plane: what they share is a region, a segment or a point of
    /// that plane, the one named, for the overlay to find there.
    coplanar: Holder,
};

/// Which of two faces' planes holds both, one face lying in the other's (its every edge
/// within the tolerance of it, `crossings`): the first's when the second lies in it (each
/// in the other's too, two faces of one plane), else the second's. A face narrower than
/// the tolerance over the sine of its angle to a plane lies in that plane at any angle,
/// and the plane holds it; its own plane does not hold the other face. What the two share
/// is a region of the holding plane only: flattened into the narrow face's own plane, a
/// face 64.7° off it covered it, where the narrow face, flattened into the other's, is a
/// strip 9e-6 wide along their shared edge, within the zone of it (the overlap rules on
/// the nightly's extruded sheet, 2026-11-21, bu: the narrow face first, the faces
/// overlapped; the other way round, they did not).
pub const Holder = enum { first, second };

/// A piece of what two faces share: the segment from `a` to `b` along their planes'
/// line, or the point `a` when `b` is `a`; each end with the gap of the vertex it is (0
/// for a crossing, which is none), by which it reaches (`incidence.reach`).
pub const Piece = struct {
    a: Vec3,
    b: Vec3,
    gap_a: f64 = 0,
    gap_b: f64 = 0,

    /// The reach beyond the tolerance of a point between the ends: the larger end's, the
    /// segment between two vertices lying within it of whatever both lie on.
    pub fn gapBetween(self: Piece) f64 {
        return @max(self.gap_a, self.gap_b);
    }

    pub fn isPoint(self: Piece) bool {
        return self.a[0] == self.b[0] and self.a[1] == self.b[1] and self.a[2] == self.b[2];
    }
};

/// The frame of planar face `f`'s plane, or null when its surface is not a plane.
pub fn frameOf(body: *const Body, f: types.FaceIndex) ?Frame {
    const surface = body.face(f).surface;
    if (surface.kind != .plane) return null;
    return body.geometry.planes.items[surface.index].frame;
}

/// The plane of a frame's `xy`.
pub fn planeOf(frame: Frame) Plane {
    return .{ .n = frame.z, .d = vec.dot(frame.z, frame.origin) };
}

/// The direction `d` of a line given its sign by the line alone, its largest component
/// positive: two planes' normals crossed the other way round give the exact negation (each
/// component's products subtracted the other way), so a pair of faces taken in either order
/// orders its points along one direction (`alongBefore`).
pub fn lineDirection(d: Vec3) Vec3 {
    return if (d[vec.maxAxis(d)] < 0) vec.scale(d, -1) else d;
}

/// Points in lexicographic order (x, then y, then z): an order of the points themselves,
/// which a choice among points takes so that it is not the order they were made in, which
/// follows the operands'.
pub fn pointBefore(p: Vec3, q: Vec3) bool {
    for (0..3) |i| if (p[i] != q[i]) return p[i] < q[i];
    return false;
}

/// Whether point `p` comes before `q` along a line of direction `line` (`lineDirection`'s):
/// by their positions along it, two at one position by the points themselves
/// (`pointBefore`). The first, exact pass of `Along.sort`, which takes positions the same to
/// rounding as one and orders those across the line.
pub fn alongBefore(line: Vec3, p: Vec3, q: Vec3) bool {
    const sp = vec.dot(p, line);
    const sq = vec.dot(q, line);
    if (sp != sq) return sp < sq;
    return pointBefore(p, q);
}

/// The order of points two planar faces share along their line (D28's ties): by their
/// positions along it; positions the same to rounding (`canonical.sameToRounding`) by their
/// positions across it, along `line × (n_a + n_b)`, the faces' outward normals summed.
/// Points on two faces lie within the tolerance of the faces' line, not on it, so two can
/// be at one position and apart across it, and their order decides which gaps are pieces.
/// The order does not change when the faces are swapped (the line's direction is the line's
/// own, `lineDirection`, and the sum is symmetric) nor when they are moved whole: a move
/// that turns the line's direction over reverses the positions along it and across it
/// together, so the whole order reverses and the same consecutive pairs are gaps. By their
/// numbering, which follows the operands', a hull's bottom edge on a box's bottom face and
/// the box's edge on the hull's side, their ends at the box's side 3.2e-5 apart, were
/// joined one way round and not the other (the sessions on 3681979b, be); by their
/// coordinates, which a turn changes, the same two were joined in place and not turned an
/// eighth about (1, 2, 3), where the two positions are one to rounding only and the line's
/// direction turned over (audit of the ties, 2026-11-22). Faces facing opposite ways have
/// no across direction either way round would agree on (their normals summed are noise),
/// and two at one position along their line are refused (`at_tolerance`); so are two at
/// one position across it too. Points within `one` of each other are one point, in any
/// order (the overlap rules' marks, each face's corner on the other's plane once from each
/// face, before they are merged), and tie with nothing.
///
/// With `steep` given (the paves' merged vertices: the sine of the angular tolerance), two
/// points whose separation lies across the line within that angle (along it at most
/// `steep` times across it) are at one place along it, ordered across, whatever their
/// positions round to; a pair at that angle to rounding is refused (`at_tolerance`, D27),
/// and so is a run ordered across that reverses a pair of it the angle does not join. One
/// place to rounding alone is a window that moves with the points: rounding at a point's
/// coordinates, 64 ulps of them, is 1e-13 in place and 4e-9 at 3e5, and a hull's corner
/// and a plate's merged vertex 2.7e-5 apart across the faces' line and 7e-10 along it were
/// two places in place and one moved whole, so the gaps differed and a sliver 2.7e-5 wide
/// was made in place only (the ReleaseSafe session on ff515852, cx). The angle between two
/// points is the solids' own, the same wherever they are; a fixed distance along the line
/// would chain (a notch's apex 1.9e-5 along from each of the points either side, those two
/// 3.8e-5 apart, all three taken for one place).
pub const Along = struct {
    line: Vec3,
    across: ?Vec3,
    /// How near two points are one point.
    one: f64,
    /// Along the line at most this many times across it, two points are at one place;
    /// null: one place to rounding.
    steep: ?f64 = null,

    pub fn init(line: Vec3, out_a: Vec3, out_b: Vec3, one: f64, tol: Tolerance) Along {
        const opposite = vec.dot(out_a, out_b) < 0 and tol.parallel(out_a, out_b);
        return .{ .line = line, .across = if (opposite) null else vec.normalized(vec.cross(line, vec.add(out_a, out_b))), .one = one };
    }

    /// What `sort` refuses: two points at one place along the line and across it, or along
    /// it with no across (`at`); or, with `steep`, two whose order hangs on the angle
    /// between them to rounding, or a run ordered across that reverses a pair of it
    /// (`steep`, with its comparison).
    pub fn Refusal(comptime T: type) type {
        return union(enum) { at: [2]T, steep: struct { pair: [2]T, comparison: canonical.Comparison } };
    }

    /// Whether `p` and `q` are at one place along the line by `steep` (`ratio`): along it
    /// at most `ratio` times across it; at that to rounding, the comparison.
    fn steepPair(self: Along, ratio: f64, across: Vec3, p: Vec3, q: Vec3, scale: f64) union(enum) { yes, no, at: canonical.Comparison } {
        const along = @abs(vec.dot(vec.sub(q, p), self.line));
        const limit = ratio * @abs(vec.dot(vec.sub(q, p), across));
        const c = canonical.Comparison.distance(along, limit, scale);
        if (@abs(along - limit) <= c.band) return .{ .at = c };
        return if (along < limit) .yes else .no;
    }

    /// Whether `x` and `y` are two points, more than `one` apart.
    fn two(self: Along, x: Vec3, y: Vec3) bool {
        return vec.distance(x, y) > self.one;
    }

    /// Sorts `items`, each a point by `pointOf(context, item)`, in this order; what it
    /// refuses first (`Refusal`), or null. Two tied along and across keep the exact order
    /// (`alongBefore`) among themselves.
    pub fn sort(self: Along, comptime T: type, items: []T, context: anytype, comptime pointOf: fn (@TypeOf(context), T) Vec3) ?Refusal(T) {
        const Exact = struct {
            ctx: @TypeOf(context),
            line: Vec3,
            fn lessThan(o: @This(), x: T, y: T) bool {
                return alongBefore(o.line, pointOf(o.ctx, x), pointOf(o.ctx, y));
            }
        };
        std.mem.sort(T, items, Exact{ .ctx = context, .line = self.line }, Exact.lessThan);
        var scale: f64 = 0;
        for (items) |item| scale = @max(scale, canonical.magnitude(&.{pointOf(context, item)}));
        var tie: ?Refusal(T) = null;
        var i: usize = 0;
        while (i < items.len) {
            var j = i + 1;
            while (j < items.len) : (j += 1) {
                const px = pointOf(context, items[j - 1]);
                const py = pointOf(context, items[j]);
                const one_place = if (self.steep) |ratio| if (self.across) |across| switch (self.steepPair(ratio, across, px, py, scale)) {
                    .yes => true,
                    .no => false,
                    .at => |c| return .{ .steep = .{ .pair = .{ items[j - 1], items[j] }, .comparison = c } },
                } else canonical.sameToRounding(vec.dot(px, self.line), vec.dot(py, self.line), scale) else canonical.sameToRounding(vec.dot(px, self.line), vec.dot(py, self.line), scale);
                if (!one_place) break;
            }
            defer i = j;
            if (j - i < 2) continue;
            const run = items[i..j];
            const across = self.across orelse {
                for (run, 0..) |x, k| for (run[k + 1 ..]) |y| {
                    if (tie == null and self.two(pointOf(context, x), pointOf(context, y))) tie = .{ .at = .{ x, y } };
                };
                continue;
            };
            // Across, as far to rounding in the exact order (a stable sort of a short run)
            const Across = struct {
                ctx: @TypeOf(context),
                across: Vec3,
                scale: f64,
                fn lessThan(o: @This(), x: T, y: T) bool {
                    const kx = vec.dot(pointOf(o.ctx, x), o.across);
                    const ky = vec.dot(pointOf(o.ctx, y), o.across);
                    return kx < ky and !canonical.sameToRounding(kx, ky, o.scale);
                }
            };
            std.sort.insertion(T, run, Across{ .ctx = context, .across = across, .scale = scale }, Across.lessThan);
            // A run chained by the angle keeps the exact order of each pair of it the angle
            // does not join: reversed, the order hangs on which pairs chain
            if (self.steep) |ratio| for (run, 0..) |x, k| for (run[k + 1 ..]) |y| {
                const px = pointOf(context, x);
                const py = pointOf(context, y);
                switch (self.steepPair(ratio, across, px, py, scale)) {
                    .yes => {},
                    .no => if (!alongBefore(self.line, px, py)) return .{ .steep = .{ .pair = .{ x, y }, .comparison = canonical.Comparison.distance(@abs(vec.dot(vec.sub(py, px), self.line)), ratio * @abs(vec.dot(vec.sub(py, px), across)), scale) } },
                    .at => |c| return .{ .steep = .{ .pair = .{ x, y }, .comparison = c } },
                }
            };
            for (run[0 .. run.len - 1], run[1..]) |x, y| {
                const px = pointOf(context, x);
                const py = pointOf(context, y);
                if (tie == null and self.two(px, py) and canonical.sameToRounding(vec.dot(px, across), vec.dot(py, across), scale)) tie = .{ .at = .{ x, y } };
            }
        }
        return tie;
    }
};

/// What planar faces `fa` of `a` and `fb` of `b` share, the pieces appended to `pieces`
/// in order along the line. Both faces must be planar.
pub fn meet(allocator: std.mem.Allocator, a: *const Body, fa: types.FaceIndex, b: *const Body, fb: types.FaceIndex, tol: Tolerance, pieces: *std.ArrayList(Piece), diag: *Diagnostics) Error!Relation {
    const frame_a = frameOf(a, fa) orelse return notPlanar(diag, fa);
    const frame_b = frameOf(b, fb) orelse return notPlanar(diag, fb);
    var marks: std.ArrayList(Mark) = .empty;
    defer marks.deinit(allocator);
    // Each face's boundary on the other's plane
    const in_b = try crossings(allocator, a, fa, b, fb, planeOf(frame_b), tol, &marks, diag);
    const in_a = try crossings(allocator, b, fb, a, fa, planeOf(frame_a), tol, &marks, diag);
    if (in_b or in_a) return .{ .coplanar = if (in_a) .first else .second };
    if (marks.items.len == 0) return .apart;
    const along = lineDirection(vec.normalized(vec.cross(frame_a.z, frame_b.z)) orelse return .apart);

    // Along the line, a mark within the zone of the one before it being that one. Planes
    // parallel within the angular tolerance have no line of their own (their normals'
    // cross product is noise), and what the rules find of such faces is their distance
    // (`nearest`), so their marks keep the exact order, whatever ties it has
    const order = Along.init(along, outward(a, fa), outward(b, fb), tol.zone, tol);
    if (tol.parallel(frame_a.z, frame_b.z)) {
        const Exact = struct {
            fn lessThan(line: Vec3, p: Mark, q: Mark) bool {
                return alongBefore(line, p.p, q.p);
            }
        };
        std.mem.sort(Mark, marks.items, along, Exact.lessThan);
    } else {
        // A body made: two marks at one place along and across the line to rounding (apart
        // along the normals' sum) keep the exact order, their gaps either way round within
        // the tolerance of each other; the boolean refuses them when it makes the body
        // (`boolean/pave.zig`'s face–face)
        _ = order.sort(Mark, marks.items, {}, markPoint);
    }
    var kept: usize = 0;
    for (marks.items) |m| {
        if (kept > 0 and tol.samePoint(m.p, marks.items[kept - 1].p)) {
            marks.items[kept - 1].gap = @max(marks.items[kept - 1].gap, m.gap);
            continue;
        }
        marks.items[kept] = m;
        kept += 1;
    }
    const points = marks.items[0..kept];

    // A piece is a gap between crossings, each end in both faces and the gap in both by its
    // middle, as the paves cut a section (`boolean/pave.zig`'s face–face): a gap's middle
    // can be within the zone of a face whose end of it is twice that outside, and a piece
    // reaching that end put a point of one face's boundary on the other face (the overlap
    // rules' find in the solids fuzzer, 2026-11-13: a box's corner the intersection
    // tolerance and a rounding from a triangle's corner); a crossing in both with no such
    // gap either side is a piece of its own, a point. A run of gaps was one piece, judged by
    // its ends and its middle as one straight segment, while a crossing in the band where
    // planes at a shallow angle stay within the tolerance of each other lies off their line:
    // a notch's apex 6e-5 under a plate's edge, the plate turned 0.3 rad, in both faces, the
    // run's middle over the notch in neither (the edge-case matrix, 2026-11-16). A gap's
    // middle is a point that is no vertex, placed with no gap, as the paves place it: the
    // ends' gaps reach the curve both lie on, not another edge one of them ends (a slit's
    // mouth 9e-5 along the line, its sides at 26.6° to it, its middle 2.01e-5 from them,
    // was on the slit's face by the ends' gaps of 2.5e-6 and in the other face: the faces
    // "touched", a pinch; the 10K session on b1053969)
    const first = pieces.items.len;
    var joined = false;
    for (points, 0..) |m, i| {
        if (!try inBoth(a, fa, b, fb, m.p, m.gap, tol, diag)) {
            joined = false;
            continue;
        }
        const next_joined = i + 1 < points.len and try inBoth(a, fa, b, fb, points[i + 1].p, points[i + 1].gap, tol, diag) and try inBoth(a, fa, b, fb, vec.lerp(m.p, points[i + 1].p, 0.5), 0, tol, diag);
        if (next_joined) {
            try pieces.append(allocator, .{ .a = m.p, .b = points[i + 1].p, .gap_a = m.gap, .gap_b = points[i + 1].gap });
        } else if (!joined) {
            try pieces.append(allocator, .{ .a = m.p, .b = m.p, .gap_a = m.gap, .gap_b = m.gap });
        }
        joined = next_joined;
    }
    return if (pieces.items.len > first) .crossing else .apart;
}

fn markPoint(_: void, m: Mark) Vec3 {
    return m.p;
}

/// Planar face `f`'s outward normal: its plane's, turned by the face's sense; the one
/// definition (`in_face.outwardNormal`), the plane's normal its frame's z turned by the
/// frame's handedness. The frame's z alone, turned by the sense, pointed every face of a
/// mirrored body inward (a mirror leaves the frames left-handed and flips the senses), and
/// the tie rule took the outer of two planes a hair apart mirrored, the inner in place
/// (the solids oracle's mirrored replay, 2026-11-26).
pub fn outward(body: *const Body, f: types.FaceIndex) Vec3 {
    return in_face.outwardNormal(body, f, .{ 0, 0 });
}

/// Appends to `marks` where face `f`'s edges meet `plane`, face `g` of `other`'s (an edge
/// lying in it gives those of its ends on it); true when every edge lies in it, the face
/// then lying in the plane. An end on the plane is within the intersection tolerance and its
/// vertex's gap (`onPlaneOf`), as a boolean takes a vertex to lie on a face
/// (`boolean/pave.zig`'s vertex–face): an edge leaving such a vertex at a shallow angle
/// crosses the plane's exact line far from it, inside the other face, where the boolean,
/// rightly, made no edge (the solids fuzzer, 2026-11-13).
fn crossings(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, other: *const Body, g: types.FaceIndex, plane: Plane, tol: Tolerance, marks: *std.ArrayList(Mark), diag: *Diagnostics) Error!bool {
    var every_in = true;
    var any = false;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const edge = body.edge(body.coedge(c).edge);
            if (edge.flags.degenerate) continue;
            any = true;
            const curve = body.geometry.curve(edge.curve);
            // Its ends on the plane by their own reach, as the paves put a vertex on a face:
            // the edge's reach is its larger end gap's, measured at its curve's ends, which
            // lie off the vertices by their gaps. A section along a wall 1.25 tolerances
            // thick, its other end merged with a gap, put its end with none on the wall's
            // far side 2.5e-5 off (the 10K fuzz session, 2026-11-14: a union's outer shell
            // touching its void); a hull's edge ending 3.1e-5 over a slot's bottom, its
            // curve 2.4e-5, at a vertex with a gap of 6.8e-6, touched it (the nightly,
            // 2026-11-15: the slot's bottom and the hull's top "touching", pinched)
            var on: [2]bool = undefined;
            for ([_]types.VertexIndex{ edge.start, edge.end }, &on) |v, *end_on| {
                const p = body.point(v);
                end_on.* = try onPlaneOf(other, g, plane, p, body.vertex(v).gap, tol, diag);
                if (end_on.*) try marks.append(allocator, .{ .p = p, .gap = body.vertex(v).gap });
            }
            // The edge lies in the plane when both its ends do, as a section takes a line
            // to (`boolean/section.zig`), a curved one's curve between them within its
            // reach too. By the edge's reach at both ends, a needle's end with no gap
            // 2.6e-5 off its other face's plane lay in it by its far end's gap of 7.4e-6,
            // and its two faces lay in one plane (the nightly, 2026-11-15: a hull's
            // ridge and a flat tetrahedron's intersection "lying on" its own face)
            if (on[0] and on[1] and (curve == .line or (try curve_surface.curvePlane(curve, edge.t0, edge.t1, plane, edgeReach(body, edge, tol), diag)).lies_in)) continue;
            every_in = false;
            // An end on the plane is where the edge meets it (once); else its curve's
            // crossings inside its range
            if (on[0] or on[1]) continue;
            const crossed = try curve_surface.curvePlane(curve, edge.t0, edge.t1, plane, 0, diag);
            for (crossed.params()) |t| {
                // A crossing within the zone of an end is that vertex, exactly
                var mark: Mark = .{ .p = curve.eval(t), .gap = 0 };
                for ([_]types.VertexIndex{ edge.start, edge.end }) |v| {
                    if (tol.samePoint(mark.p, body.point(v))) mark = .{ .p = body.point(v), .gap = body.vertex(v).gap };
                }
                try marks.append(allocator, mark);
            }
        }
    }
    return any and every_in;
}

/// How near an edge a plane or a point with no gap must come to be on it: the
/// intersection tolerance and the edge's gap (`incidence.edgeGap`, the larger of its ends'),
/// as a boolean puts a vertex on an edge (`incidence.Decider.onEdge`). For a curved edge
/// between its ends lying in a plane (`crossings`, its ends by their own) and an edge kept
/// apart from a plane (`boolean/pipeline.zig`'s `keepsApart`).
pub fn edgeReach(body: *const Body, edge: *const types.Edge, tol: Tolerance) f64 {
    return incidence.reach(tol, incidence.edgeGap(body.vertex(edge.start).gap, body.vertex(edge.end).gap));
}

/// Whether `p`, reaching `gap` beyond the tolerance, lies in both faces, their boundaries
/// included.
fn inBoth(a: *const Body, fa: types.FaceIndex, b: *const Body, fb: types.FaceIndex, p: Vec3, gap: f64, tol: Tolerance, diag: *Diagnostics) Error!bool {
    if (try place(a, fa, p, gap, tol, diag) == .outside) return false;
    return try place(b, fb, p, gap, tol, diag) != .outside;
}

/// Where `p` (near face `f`'s plane), reaching `gap` beyond the tolerance (a vertex's gap,
/// 0 for a point that is none), lies against the face: the paves' decision
/// (`in_face.placeWithin`). At its reach of the boundary to rounding it is refused
/// (`at_tolerance`, naming the face; D27), for the boolean and for the rules that read a
/// body that exists alike: taken for the boundary there, a body moved far, its distances
/// rounded into the band, read as overlapping itself where in place it did not, and was
/// called invalid (the solids oracle's moved results on 9015ab26, dt and dy, 2026-11-26).
pub fn place(body: *const Body, f: types.FaceIndex, p: Vec3, gap: f64, tol: Tolerance, diag: *Diagnostics) Error!in_face.Place {
    const decide: incidence.Decider = .{ .tol = tol, .scale = canonical.magnitude(&.{p}) };
    return switch (try in_face.placeWithin(decide, body, f, p, gap, null, diag)) {
        .inside => .inside,
        .outside => .outside,
        .boundary => .boundary,
        .at_tolerance => |c| diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.face, @backingInt(f)), .label = "a point on a face's boundary or not", .measured = c.measured, .threshold = c.limit }),
    };
}

/// Whether `p`, reaching `gap` beyond the tolerance (its vertex's, 0 for a point that is
/// none), lies on `plane`, face `g` of `body`'s: within its reach of it
/// (`incidence.Decider.onPlane`), as the paves put a vertex on a face. At its reach to
/// rounding it is refused (`at_tolerance`, naming `g`; D27) where the height decides, `p`
/// in `g` or on its boundary (`place`); outside `g` it is off the plane, as the paves take
/// it (`boolean/pave.zig`'s `faceVerdict`). The one decision of a point on a face's plane
/// for the overlap rules (`meet`, `query/overlap.zig`'s `onShell`). Read as within, a box's
/// bottom the tolerance over another's top to rounding once moved far lay in its plane,
/// and the two solids' faces "lay on each other" (`faces_intersect`; dt, dy).
pub fn onPlaneOf(body: *const Body, g: types.FaceIndex, plane: Plane, p: Vec3, gap: f64, tol: Tolerance, diag: *Diagnostics) Error!bool {
    const decide: incidence.Decider = .{ .tol = tol, .scale = @max(canonical.magnitude(&.{p}), @abs(plane.d)) };
    const height = plane.height(p);
    return switch (decide.onPlane(height, gap)) {
        .same => true,
        .apart => false,
        .at_tolerance => |c| if (try place(body, g, p, gap, tol, diag) == .outside) false else diag.fail(error.Degenerate, .{ .code = .at_tolerance, .entity = .of(.face, @backingInt(g)), .label = "a point on a face's plane or not", .measured = c.measured, .threshold = c.limit }),
    };
}

/// Face `f`'s loops (planar, lines and arcs) as edges of the overlay's current input, in
/// the coordinates of `frame`'s plane: each coedge from its start to its end, a circle's
/// as an arc running the way the coedge does.
pub fn addFace(o: *overlay_mod.Overlay, body: *const Body, f: types.FaceIndex, frame: Frame, diag: *Diagnostics) Error!void {
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const e = body.edge(coedge.edge);
            if (e.flags.degenerate) continue;
            const pa = flat(frame, body.point(body.coedgeStart(c)));
            const pb = flat(frame, body.point(body.coedgeEnd(c)));
            const edge: overlay_mod.InputEdge = switch (body.geometry.curve(e.curve)) {
                .line => .{ .a = pa, .b = pb },
                .circle => |circle| .{ .a = pa, .b = pb, .arc = .{ .c = flat(frame, circle.c), .r = circle.r, .ccw = (vec.dot(circle.normal(), frame.z) > 0) == coedge.same_sense } },
                else => return diagnostics.notImplemented(diag, "a planar face's edge that is neither a line nor an arc, overlaid", 5),
            };
            o.addEdge(edge) catch |err| return overlayError(diag, err);
        }
    }
}

/// A face of an operand as the last resort of a tie between faces' planes sees it
/// (`TieFace.before`).
pub const TieFace = struct {
    frame: Frame,
    /// The face's outward normal.
    outward: Vec3,
    /// The zone of the operand it is a face of.
    zone: f64,
    operand: u1,
    face: u32,

    pub fn of(body: *const Body, operand: u1, face: u32) TieFace {
        const f = types.FaceIndex.of(face);
        const frame = frameOf(body, f).?;
        return .{ .frame = frame, .outward = outward(body, f), .zone = body.tol.zone, .operand = operand, .face = face };
    }

    /// The order a choice between faces' planes that hold what it measures alike (to
    /// rounding) falls back on, the one tie rule of the boolean (D28; `Provenance`'s
    /// coplanar groups, `classify`'s twins, as `blockLines` breaks a tie between lines):
    /// - faces facing alike (within the angular tolerance): the inner plane, the one point
    ///   `at` (the region's or the group's, which the two hold) lies farther outside of
    ///   along its outward normal;
    /// - else, or as far to rounding (`canonical.sameToRounding` at `scale`): the face of
    ///   the operand built at the finer zone, whose plane is stated the more closely;
    /// - else the first operand's, then the lower face of one operand.
    /// None of it changes when the solids are moved whole; only the operands' order, for
    /// two faces of the two at one zone tied exactly, which OCCT's same-domain faces take
    /// the first argument's too. By the planes' normals made canonical (their first
    /// non-zero component positive) and their offsets, it was the operands' order that
    /// changed nothing and a turn that changed the choice: two boxes side by side, their
    /// tops 5e-6 apart and each kept alike, took the lower top in place and the upper
    /// turned 0.3 about x (the audit of the ties, finding 4, 2026-11-22).
    pub fn before(x: TieFace, y: TieFace, at: Vec3, scale: f64, tol: Tolerance) bool {
        if (tol.sameDirection(x.outward, y.outward)) {
            const hx = vec.dot(vec.sub(at, x.frame.origin), x.outward);
            const hy = vec.dot(vec.sub(at, y.frame.origin), y.outward);
            if (!canonical.sameToRounding(hx, hy, scale)) return hx > hy;
        }
        if (x.zone != y.zone) return x.zone < y.zone;
        if (x.operand != y.operand) return x.operand < y.operand;
        return x.face < y.face;
    }
};

/// `p` in the coordinates of `frame`'s plane.
pub fn flat(frame: Frame, p: Vec3) Vec2 {
    const l = frame.toLocal(p);
    return .{ l[0], l[1] };
}

pub fn overlayError(diag: *Diagnostics, err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "a face's edges in the overlay" }),
        error.OutOfRange => diag.fail(error.InvalidInput, .{ .code = .too_large_for_tolerance, .label = "a coordinate" }),
        error.AtTolerance => diag.fail(error.Degenerate, .{ .code = .at_tolerance, .label = "two curves of a face the zone apart to within rounding, touching or not," }),
        else => unreachable,
    };
}

fn notPlanar(diag: *Diagnostics, f: types.FaceIndex) Error {
    return diag.fail(error.InvalidInput, .{ .code = .not_implemented, .entity = .of(.face, @backingInt(f)), .label = "a face meeting another as a plane (it is curved)" });
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "a face" });
}
