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

pub const Relation = enum {
    /// The faces share no point.
    apart,
    /// Their planes cross; what they share is in the pieces (maybe none).
    crossing,
    /// One lies in the other's plane: what they share is a region, a segment or a point of
    /// that plane, for the overlay to find.
    coplanar,
};

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

/// What planar faces `fa` of `a` and `fb` of `b` share, the pieces appended to `pieces`
/// in order along the line. Both faces must be planar.
pub fn meet(allocator: std.mem.Allocator, a: *const Body, fa: types.FaceIndex, b: *const Body, fb: types.FaceIndex, tol: Tolerance, pieces: *std.ArrayList(Piece), diag: *Diagnostics) Error!Relation {
    const frame_a = frameOf(a, fa) orelse return notPlanar(diag, fa);
    const frame_b = frameOf(b, fb) orelse return notPlanar(diag, fb);
    var marks: std.ArrayList(Mark) = .empty;
    defer marks.deinit(allocator);
    // Each face's boundary on the other's plane
    const in_b = try crossings(allocator, a, fa, planeOf(frame_b), tol, &marks, diag);
    const in_a = try crossings(allocator, b, fb, planeOf(frame_a), tol, &marks, diag);
    if (in_b or in_a) return .coplanar;
    if (marks.items.len == 0) return .apart;
    const along = vec.normalized(vec.cross(frame_a.z, frame_b.z)) orelse return .apart;

    // Along the line, a mark within the zone of the one before it being that one
    const Order = struct {
        along: Vec3,
        fn lessThan(self: @This(), p: Mark, q: Mark) bool {
            return vec.dot(p.p, self.along) < vec.dot(q.p, self.along);
        }
    };
    std.mem.sort(Mark, marks.items, Order{ .along = along }, Order.lessThan);
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

    // A piece is a run of crossings each in both faces, every gap between them in both by
    // its middle: a gap's middle can be within the zone of a face whose end of it is twice
    // that outside, and a piece reaching that end put a point of one face's boundary on
    // the other face (the overlap rules' find in the solids fuzzer, 2026-11-13: a box's
    // corner the intersection tolerance and a rounding from a triangle's corner)
    const first = pieces.items.len;
    var open: ?Mark = null;
    for (points, 0..) |m, i| {
        if (!try inBoth(a, fa, b, fb, m.p, m.gap, tol, diag)) {
            if (open) |start| try pieces.append(allocator, .{ .a = start.p, .b = points[i - 1].p, .gap_a = start.gap, .gap_b = points[i - 1].gap });
            open = null;
            continue;
        }
        if (open == null) open = m;
        if (i + 1 < points.len and try inBoth(a, fa, b, fb, vec.lerp(m.p, points[i + 1].p, 0.5), @max(m.gap, points[i + 1].gap), tol, diag)) continue;
        try pieces.append(allocator, .{ .a = open.?.p, .b = m.p, .gap_a = open.?.gap, .gap_b = m.gap });
        open = null;
    }
    return if (pieces.items.len > first) .crossing else .apart;
}

/// Appends to `marks` where face `f`'s edges meet `plane` (an edge lying in it gives those
/// of its ends on it); true when every edge lies in it, the face then lying in the plane. An
/// end on the plane is within the intersection tolerance and its vertex's gap, as a boolean
/// takes a vertex to lie on a face (`boolean/pave.zig`'s vertex–face): an edge leaving such a
/// vertex at a shallow angle crosses the plane's exact line far from it, inside the other
/// face, where the boolean, rightly, made no edge (the solids fuzzer, 2026-11-13).
fn crossings(allocator: std.mem.Allocator, body: *const Body, f: types.FaceIndex, plane: Plane, tol: Tolerance, marks: *std.ArrayList(Mark), diag: *Diagnostics) Error!bool {
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
                end_on.* = @abs(plane.height(p)) <= incidence.reach(tol, body.vertex(v).gap);
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
/// (`in_face.placeWithin`), on the boundary when at the reach to rounding, since this
/// reads a body that exists and refuses nothing (`incidence.holds`).
pub fn place(body: *const Body, f: types.FaceIndex, p: Vec3, gap: f64, tol: Tolerance, diag: *Diagnostics) Error!in_face.Place {
    const decide: incidence.Decider = .{ .tol = tol, .scale = canonical.magnitude(&.{p}) };
    return switch (try in_face.placeWithin(decide, body, f, p, gap, null, diag)) {
        .inside => .inside,
        .outside => .outside,
        .boundary, .at_tolerance => .boundary,
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

/// A fixed order of planes, whichever way they face: by their normal (turned so its first
/// non-zero component is positive), then their offset along it. What a choice between
/// planes that hold a region alike falls back on, so that both orders of a boolean's
/// operands choose alike (`boolean/classify.zig`'s twins, `boolean/pipeline.zig`'s
/// coplanar groups).
pub fn planeBefore(a: Frame, b: Frame) bool {
    const na = canonicalNormal(a.z);
    const nb = canonicalNormal(b.z);
    for (na, nb) |x, y| if (x != y) return x < y;
    return vec.dot(na, a.origin) < vec.dot(nb, b.origin);
}

fn canonicalNormal(n: Vec3) Vec3 {
    for (n) |c| {
        if (c > 0) return n;
        if (c < 0) return vec.neg(n);
    }
    return n;
}

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
