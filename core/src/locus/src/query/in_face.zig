//! Whether a point of a face's surface lies in the face (docs/architecture.md §7.6): on its
//! boundary when within a distance of one of its edges (measured in space, on the exact
//! edge curves), else inside when its loops wind about the point's parameters in UV. The
//! winding is the angle the loops sweep about the point, each coedge's image in UV (its
//! pcurve, or on a plane its curve projected; a coedge on a curved face without one, its
//! curve projected onto the surface) summed piece by piece, a piece halved until the angle
//! it subtends is small and its midpoint agrees, so no polyline of the boundary is ever
//! taken for it: a point away from the boundary is classified on the exact curves, and the
//! one test covers lines, circles, ellipses and NURBS alike. Used by every solid query.
//!
//! A ray's meeting with a face's surface is also at the face's boundary in the sliver of
//! an edge (`meeting`, `inSliver`): between the edge, which a boolean keeps on its source's
//! line (D28), and the line the surfaces of its two faces meet along.

const std = @import("std");
const vec = @import("../math/vec.zig");
const predicates = @import("../math/predicates.zig");
const ray_crossing = @import("../math/ray_crossing.zig");
const trig = @import("../math/trig.zig");
const geometry = @import("../geometry/types.zig");
const canonical = @import("../geometry/canonical.zig");
const incidence = @import("../geometry/incidence.zig");
const face_edges = @import("face_edges.zig");
const surfaces = @import("../geometry/surfaces.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// How many times a coedge's piece may be halved while its swept angle is measured.
const MAX_DEPTH: u8 = 40;
/// The longest piece of a conic's image (a circle's or an ellipse's, in its parameter)
/// whose hull `sweptAngle` takes as the triangle of its ends and its end tangents'
/// meeting point: a quarter turn, the meeting point within √2 of the conic's size.
const CONIC_PIECE: f64 = std.math.pi / 2.0;
/// A free-form image's piece's swept angle is taken from its chord when it and both its
/// halves subtend below this (radians) and the halves' angles sum to the chord's within
/// `AGREE` (`sweptAngle`): sampled, not certified (M5).
const PIECE_ANGLE: f64 = 0.25;
const AGREE: f64 = 1e-9;
/// The Newton bound of the free-form kinds' projections in the queries.
pub const NEWTON_STEPS: u32 = geometry.PROJECT_STEPS;

pub const Place = enum { inside, outside, boundary };

/// Where `p` (a point on face `f`'s surface, at parameters `uv`, unwrapped by `uvOf`)
/// lies against the face: on its boundary when within `within` of an edge, else inside
/// or outside by the winding of its loops.
pub fn classify(body: *const Body, f: types.FaceIndex, p: Vec3, uv: Vec2, within: f64, diag: *Diagnostics) Error!Place {
    if (try nearEdge(body, f, p, within, diag)) return .boundary;
    const inside = try windsPlanar(body, f, uv, diag) orelse (try winds(body, f, uv, diag) orelse return .boundary);
    return if (inside) .inside else .outside;
}

/// Where a ray's meeting `p` with face `f`'s surface (at `uv`) lies against the face, as
/// the ray queries take it: on its boundary within the zone of an edge (`classify`), in an
/// edge's sliver (`inSliver`) or between an edge's line and the chord of its vertices
/// (`betweenLineAndChord`), in the face's loops or not; else inside or outside by the
/// loops.
pub fn meeting(body: *const Body, f: types.FaceIndex, p: Vec3, uv: Vec2, diag: *Diagnostics) Error!Place {
    const place = try classify(body, f, p, uv, body.tol.zone, diag);
    if (place == .boundary) return .boundary;
    if (try betweenLineAndChord(body, f, p, diag)) return .boundary;
    return if (try inSliver(body, f, p, diag)) .boundary else place;
}

/// Whether `p`, a point of planar face `f`'s plane, lies between the line of one of its
/// straight edges and the chord between that edge's vertices, abreast of the edge. The
/// face's loops wind about its vertices' points (`windsPlanar`) while its edges are their
/// lines, and a vertex may lie the intersection tolerance and its gaps off its edge's line
/// (D28: a merged vertex is its own point, the edge its source's line; the checker's
/// `vertex_off_curve`): between the two the face is read both ways, and a meeting there is
/// at the edge. Taken by the loops alone, a box's corner 1.9e-4 off a plate's front edge
/// ended the union's bottom short of the plate's front line, which its top ends on, and a
/// ray up between the two, 1.2e-4 from the line and past the zone, met the top alone (the
/// solids session's find eq on 621b9ee0: a point under the plate inside the union).
pub fn betweenLineAndChord(body: *const Body, f: types.FaceIndex, p: Vec3, diag: *Diagnostics) Error!bool {
    const face = body.face(f);
    if (face.surface.kind != .plane) return false;
    const normal = body.geometry.planes.items[face.surface.index].frame.z;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const edge = body.edge(body.coedge(c).edge);
            if (edge.flags.degenerate) continue;
            const curve = body.geometry.curve(edge.curve);
            if (curve != .line) continue;
            const line_a = curve.eval(edge.t0);
            const line_b = curve.eval(edge.t1);
            const chord_a = body.point(edge.start);
            const chord_b = body.point(edge.end);
            const along = vec.sub(line_b, line_a);
            const length2 = vec.dot(along, along);
            if (length2 == 0) continue;
            const s = vec.dot(vec.sub(p, line_a), along) / length2;
            if (s < 0 or s > 1) continue;
            const across = vec.cross(normal, along);
            const on_line = vec.dot(vec.sub(p, vec.addScaled(line_a, along, s)), across);
            const on_chord = vec.dot(vec.sub(p, vec.add(chord_a, vec.scale(vec.sub(chord_b, chord_a), s))), across);
            if ((on_line <= 0 and on_chord >= 0) or (on_line >= 0 and on_chord <= 0)) return true;
        }
    }
    return false;
}

/// Whether `p`, a point of face `f`'s surface (in the face's loops or not), lies in the
/// sliver of one of the face's edges: between the edge, where the face's boundary is, and
/// the line the face's surface meets the surface of the face across the edge along, where
/// the two faces would end. A boolean keeps an edge on its source's line (D28), off the
/// surface of one of its faces by up to the reach, and the two surfaces' own line then
/// runs that far over the sine of the angle between them from the edge. Between the two
/// the faces do not close: the one whose surface holds the edge runs past the other's
/// surface (in its loops, and no boundary of the solid), or stops short of it (boundary,
/// and outside its loops), and a ray through there meets one face with no other to answer
/// it. A meeting there is at the edge, whichever (`meeting`).
///
/// Measured by the height over the other face's surface: the edge's foot on this face's
/// surface stands the edge's lift over it, the surfaces' line stands at none, and the
/// sliver is what stands between, abreast of the edge; past an end of the edge, what the
/// next edge's sliver holds too (the corner the two lines cut off). An edge on both
/// surfaces to rounding has none.
pub fn inSliver(body: *const Body, f: types.FaceIndex, p: Vec3, diag: *Diagnostics) Error!bool {
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        // Whether the coedge before holds `p` past its end, and the loop's first past its
        // start: a corner is held by both its edges
        var past_end_before = false;
        var past_start_first = false;
        var first = true;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const held = sliverOf(body, f, c, p);
            if (held == .abreast) return true;
            const past_start = held == .past_start;
            if (past_start and past_end_before) return true;
            if (first) past_start_first = past_start;
            first = false;
            past_end_before = held == .past_end;
        }
        if (past_end_before and past_start_first) return true;
    }
    return false;
}

/// How an edge's sliver holds a point: not, abreast of the edge, or past the coedge's
/// start or end (nearest that vertex).
const Held = enum { no, abreast, past_start, past_end };

/// How the sliver of coedge `c`'s edge on face `f` holds `p` (`inSliver`).
fn sliverOf(body: *const Body, f: types.FaceIndex, c: types.CoedgeIndex, p: Vec3) Held {
    const coedge = body.coedge(c);
    if (coedge.partner == .none) return .no;
    const g = body.loop(body.coedge(coedge.partner).loop).face;
    if (g == f) return .no;
    const near = nearestAlongEdge(body, coedge.edge, p);
    const on_face = footOn(body, f, near.point);
    const lift = heightOver(body, g, on_face);
    if (canonical.sameToRounding(lift, 0, canonical.magnitude(&.{ p, near.point }))) return .no;
    const h = heightOver(body, g, p);
    if (if (lift > 0) h < 0 or h > lift else h > 0 or h < lift) return .no;
    return switch (near.end) {
        .none => .abreast,
        .start => if (coedge.same_sense) .past_start else .past_end,
        .end => if (coedge.same_sense) .past_end else .past_start,
    };
}

/// The foot of `p` on face `f`'s surface.
fn footOn(body: *const Body, f: types.FaceIndex, p: Vec3) Vec3 {
    const uv = uvOf(body, f, p);
    return body.geometry.surface(body.face(f).surface).eval(uv[0], uv[1]);
}

/// How far `p` stands over face `g`'s surface, along the surface's normal at its foot.
fn heightOver(body: *const Body, g: types.FaceIndex, p: Vec3) f64 {
    const surface = body.geometry.surface(body.face(g).surface);
    switch (surface) {
        .plane => |plane| return plane.height(p),
        else => {
            const uv = uvOf(body, g, p);
            return vec.dot(vec.sub(p, surface.eval(uv[0], uv[1])), surface.normal(uv[0], uv[1]));
        },
    }
}

/// Where a point lies against a face as the tolerance decides it (`placeWithin`): `Place`,
/// or at the tolerance (D27) when its distance from the boundary is its reach to rounding.
pub const Placed = union(enum) { inside, outside, boundary, at_tolerance: canonical.Comparison };

/// Where `p` (on face `f`'s surface), a point reaching `gap` beyond the intersection
/// tolerance (a vertex's gap; 0 for a point that is none), lies against the face: on its
/// boundary within that reach of it (`incidence.Decider.onCurve`), else inside or outside
/// by its loops' winding. The one decision of a point in a face for the boolean's paves
/// and the rules that check a body (the M0–M4 review, 2026-11-15: the paves decided it
/// by the reach, the overlap rules and the classification again by the zone). `index`:
/// the face's edges in trees, when the caller keeps them (reaching the decider's band
/// beyond the reach).
pub fn placeWithin(decide: incidence.Decider, body: *const Body, f: types.FaceIndex, p: Vec3, gap: f64, index: ?*const face_edges.FaceEdges, diag: *Diagnostics) Error!Placed {
    const distance = if (index) |i| i.boundaryDistance(body, p, incidence.reach(decide.tol, gap) + decide.band()) else try boundaryDistance(body, f, p, diag);
    switch (decide.onCurve(distance, gap)) {
        .same => return .boundary,
        .at_tolerance => |c| return .{ .at_tolerance = c },
        .apart => {},
    }
    return if (try byLoops(body, f, p, index, diag) == .inside) .inside else .outside;
}

/// Where `p` (on face `f`'s surface) lies by the face's loops alone, however near its
/// boundary: inside or outside by their winding, on the boundary only exactly on an edge.
/// What `placeWithin` answers beyond reach of the boundary, and the side of the boundary a
/// point within reach of it is on. `index`: as `placeWithin`'s.
pub fn byLoops(body: *const Body, f: types.FaceIndex, p: Vec3, index: ?*const face_edges.FaceEdges, diag: *Diagnostics) Error!Place {
    const uv = uvOf(body, f, p);
    return if (index) |i| try i.classify(body, p, uv, diag) else try classify(body, f, p, uv, 0, diag);
}

/// The parameters of `p` on face `f`'s surface, a periodic direction's value taken a
/// whole period over when that brings it into the face's UV box (or nearer to it).
pub fn uvOf(body: *const Body, f: types.FaceIndex, p: Vec3) Vec2 {
    const face = body.face(f);
    const surface = body.geometry.surface(face.surface);
    return unwrap(surface, face.uv_box, surface.project(p, body.tol.approx, NEWTON_STEPS));
}

/// `uv` with each periodic direction's value moved by whole periods to the representative
/// nearest `box` (inside it when one is).
pub fn unwrap(surface: surfaces.Surface, box: geometry.Box2, uv: Vec2) Vec2 {
    if (box.isEmpty()) return uv;
    var out = uv;
    const domains = [2]geometry.Domain{ surface.domainU(), surface.domainV() };
    for (domains, 0..) |domain, k| {
        if (!domain.periodic) continue;
        const period = domain.span();
        var best = out[k];
        var best_gap = gapTo(best, box.min[k], box.max[k]);
        for ([_]f64{ -1, 1 }) |sign| {
            const candidate = out[k] + sign * period;
            const gap = gapTo(candidate, box.min[k], box.max[k]);
            if (gap < best_gap) {
                best = candidate;
                best_gap = gap;
            }
        }
        out[k] = best;
    }
    return out;
}

fn gapTo(x: f64, lo: f64, hi: f64) f64 {
    return @max(0, @max(lo - x, x - hi));
}

/// The outward normal of face `f` at `uv`: its surface's, turned by the face's sense.
pub fn outwardNormal(body: *const Body, f: types.FaceIndex, uv: Vec2) Vec3 {
    const face = body.face(f);
    const n = body.geometry.surface(face.surface).normal(uv[0], uv[1]);
    return if (face.same_sense) n else vec.neg(n);
}

/// Whether `p` lies within `within` of an edge of face `f`.
pub fn nearEdge(body: *const Body, f: types.FaceIndex, p: Vec3, within: f64, diag: *Diagnostics) Error!bool {
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        if (body.loop(l).vertex != .none and vec.distance(body.point(body.loop(l).vertex), p) <= within) return true;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            if (edgeDistance(body, body.coedge(c).edge, p) <= within) return true;
        }
    }
    return false;
}

/// How far beyond the tolerance face `f` reaches: the largest gap of its vertices, within
/// which its edges may lie off its surface (a boolean keeps an edge on its source's line,
/// D28).
pub fn reachGap(body: *const Body, f: types.FaceIndex, diag: *Diagnostics) Error!f64 {
    var gap: f64 = 0;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        if (body.loop(l).vertex != .none) gap = @max(gap, body.vertex(body.loop(l).vertex).gap);
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| gap = @max(gap, body.vertex(body.coedgeStart(c)).gap);
    }
    return gap;
}

/// The distance from `p` to face `f`'s boundary: its nearest edge's, or a loop's vertex.
pub fn boundaryDistance(body: *const Body, f: types.FaceIndex, p: Vec3, diag: *Diagnostics) Error!f64 {
    var nearest = std.math.inf(f64);
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        if (body.loop(l).vertex != .none) nearest = @min(nearest, vec.distance(body.point(body.loop(l).vertex), p));
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| nearest = @min(nearest, edgeDistance(body, body.coedge(c).edge, p));
    }
    return nearest;
}

/// The distance from `p` to edge `e`: to the nearest point of its curve within its range,
/// a periodic curve's parameter taken over a period when that brings it into the range,
/// else to the nearer end.
pub fn edgeDistance(body: *const Body, e: types.EdgeIndex, p: Vec3) f64 {
    return vec.distance(nearestOnEdge(body, e, p), p);
}

/// The nearest point to `p` on edge `e` (`edgeDistance`'s).
pub fn nearestOnEdge(body: *const Body, e: types.EdgeIndex, p: Vec3) Vec3 {
    return nearestAlongEdge(body, e, p).point;
}

/// The nearest point to `p` on edge `e`, and the end of the edge it is when `p` lies past
/// that end (none within the edge's range).
fn nearestAlongEdge(body: *const Body, e: types.EdgeIndex, p: Vec3) struct { point: Vec3, end: enum { none, start, end } } {
    const edge = body.edge(e);
    const curve = body.geometry.curve(edge.curve);
    if (edge.flags.degenerate) return .{ .point = curve.eval(edge.t0), .end = .start };
    var t = curve.project(p, body.tol.approx, NEWTON_STEPS);
    const domain = curve.domain();
    if (domain.periodic and (t < edge.t0 or t > edge.t1)) {
        for ([_]f64{ -1, 1, 2 }) |k| {
            const shifted = t + k * domain.span();
            if (shifted >= edge.t0 and shifted <= edge.t1) {
                t = shifted;
                break;
            }
        }
    }
    if (t >= edge.t0 and t <= edge.t1) return .{ .point = curve.eval(t), .end = .none };
    const a = curve.eval(edge.t0);
    const b = curve.eval(edge.t1);
    return if (vec.distance(a, p) <= vec.distance(b, p)) .{ .point = a, .end = .start } else .{ .point = b, .end = .end };
}

/// Whether the loops of face `f` hold `uv`, for a planar face whose edges are lines and
/// circles' arcs: the parity of the crossings of the ray from `uv` to +x with its edges,
/// exact (`math/ray_crossing.zig`: `orient2d` and `inCircle`, the half-open rule at
/// vertices, each edge from its coedge's start vertex to its end); a point exactly on a
/// line's image, its ends included, outside (`ray_crossing.onSegment`: the parity's rules
/// there read the loop's direction and the frame's axes, which a mirror turns; find dp,
/// 2026-11-26). The same answer as
/// the winding for a point off the boundary, without an angle per piece (a boolean's
/// paves ask it of every vertex near a face; on a 1000-sided face the angles took most of
/// a second, 2026-11-12), and with nothing to accept an arc's angle by: a cap of two arcs
/// asked through its angles put a point 0.63 of the radius in outside it (find dg), and
/// the rule that mended that is a circle's, not an ellipse's (the audit of 2026-11-22).
/// Null for any other face (`winds`).
fn windsPlanar(body: *const Body, f: types.FaceIndex, uv: Vec2, diag: *Diagnostics) Error!?bool {
    const face = body.face(f);
    if (face.surface.kind != .plane) return null;
    const frame = body.geometry.planes.items[face.surface.index].frame;
    const up = vec.cross(frame.x, frame.y);
    var inside = false;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const a3 = frame.toLocal(body.point(body.coedgeStart(c)));
            const b3 = frame.toLocal(body.point(body.coedgeEnd(c)));
            const a: Vec2 = .{ a3[0], a3[1] };
            const b: Vec2 = .{ b3[0], b3[1] };
            const crosses = switch (body.geometry.curve(body.edge(coedge.edge).curve)) {
                .line => if (ray_crossing.onSegment(a, b, uv)) return false else ray_crossing.line(a, b, uv),
                .circle => |circle| arc: {
                    const centre = frame.toLocal(circle.c);
                    // Counter-clockwise in UV when the circle turns the plane's way and
                    // the coedge runs the circle's way, or neither
                    const ccw = (vec.dot(circle.normal(), up) > 0) == coedge.same_sense;
                    break :arc ray_crossing.arc(a, b, .{ centre[0], centre[1] }, circle.r, ccw, uv);
                },
                else => return null,
            };
            if (crosses) inside = !inside;
        }
    }
    return inside;
}

/// Whether the loops of face `f` wind about `uv`: the angle they sweep about it, a whole
/// number of turns, is not zero (holes wind back). For a face `windsPlanar` does not
/// answer: a curved one, or a planar one with an elliptic or free-form edge. Null when
/// `uv` is on an edge's image to rounding (`sweptAngle`).
fn winds(body: *const Body, f: types.FaceIndex, uv: Vec2, diag: *Diagnostics) Error!?bool {
    const face = body.face(f);
    const surface = body.geometry.surface(face.surface);
    var total: f64 = 0;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var first: ?Vec2 = null;
        var last: ?Vec2 = null;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const edge = body.edge(coedge.edge);
            const image: Image = .{ .body = body, .surface = surface, .box = face.uv_box, .edge = edge, .pcurve = coedge.pcurve, .p = uv };
            const from = if (coedge.same_sense) edge.t0 else edge.t1;
            const to = if (coedge.same_sense) edge.t1 else edge.t0;
            const a = image.at(from);
            const b = image.at(to);
            // The step across the joint from the coedge before (pcurves join within the
            // tolerance, not to the bit)
            if (last) |prev| total += angleBetween(prev, a);
            if (first == null) first = a;
            total += sweptAngle(image, image.shape(), from, to, a, b, 0) orelse return null;
            last = b;
        }
        if (first) |a| if (last) |b| {
            total += angleBetween(b, a);
        };
    }
    return @abs(total) > std.math.pi;
}

/// A coedge's image in the face's UV, relative to the point the winding is about.
const Image = struct {
    body: *const Body,
    surface: surfaces.Surface,
    box: geometry.Box2,
    edge: *const types.Edge,
    pcurve: geometry.PCurveRef,
    p: Vec2,

    /// The image at the edge's parameter `t`, less the point.
    fn at(self: Image, t: f64) Vec2 {
        const uv: Vec2 = if (!self.pcurve.isNone())
            self.body.geometry.pcurve(self.pcurve).eval(t)
        else switch (self.surface) {
            .plane => |plane| plane.project(self.body.geometry.curve(self.edge.curve).eval(t)),
            else => unwrap(self.surface, self.box, self.surface.project(self.body.geometry.curve(self.edge.curve).eval(t), self.body.tol.approx, NEWTON_STEPS)),
        };
        return vec.sub2(uv, self.p);
    }

    /// What the image is, as far as its pieces' angles are certified: a line's (its
    /// pcurve, or a line on a plane), a conic's (a circle's or an ellipse's, on a plane or
    /// as a circle pcurve: an affine image of a circle in its parameter, its centre less
    /// the point), or sampled (free-form pcurves and curves, and projections onto curved
    /// surfaces, M5).
    fn shape(self: Image) Shape {
        if (!self.pcurve.isNone()) return switch (self.body.geometry.pcurve(self.pcurve)) {
            .line2 => .line,
            .circle2 => |c| .{ .conic = vec.sub2(c.c, self.p) },
            .nurbs2 => .sampled,
        };
        const plane = switch (self.surface) {
            .plane => |plane| plane,
            else => return .sampled,
        };
        return switch (self.body.geometry.curve(self.edge.curve)) {
            .line => .line,
            .circle => |c| .{ .conic = vec.sub2(plane.project(c.c), self.p) },
            .ellipse => |e| .{ .conic = vec.sub2(plane.project(e.c), self.p) },
            .nurbs => .sampled,
        };
    }
};

const Shape = union(enum) { line, conic: Vec2, sampled };

/// The angle the image sweeps about the origin from parameter `ta` (at `a`) to `tb` (at
/// `b`), halving the piece until its chord's angle is certified to be the piece's; null
/// when no halving within `MAX_DEPTH` certifies it, the origin on the image to rounding.
/// Each angle is measured the short way, in (−π, π], so a measure is off by a whole turn
/// exactly when the image it measures winds past a half turn (a disc's cap of two arcs,
/// the long one winding 2π − 0.2 about a point 0.76 inside the rim, measured −0.2: the
/// 2D chain fuzzer's find dg, 2026-11-22). The certificate, as the mesher's chords take
/// theirs (`mesh/chords.zig`), is a hull of the piece the origin lies outside of, exactly
/// (`orient2d`): the piece lies in it, the hull in a half-plane seen from the origin, so
/// the angle from its one end to its other is the chord's. A line's piece is its own
/// hull. A conic's piece of at most a quarter turn of its parameter lies in the triangle of
/// its ends and its end tangents' meeting point, the image of its middle moved out from
/// the centre by `1/cos` of half its span (an affine map keeps tangents' meetings). A
/// piece and both its halves under a quarter radian, the halves agreeing, held for a
/// circle's pieces and not for a thin ellipse's: from a point near one end of an ellipse
/// 12 to 1, a piece's ends and middle all lay one way while it went round the point, which
/// was put outside (the audit of 2026-11-22, kind 7, site 6). A free-form image keeps
/// that sampled rule until its pieces have hulls of their own (M5).
fn sweptAngle(image: Image, shape: Shape, ta: f64, tb: f64, a: Vec2, b: Vec2, depth: u8) ?f64 {
    const whole = angleBetween(a, b);
    const tm = ta + (tb - ta) / 2;
    const m = image.at(tm);
    switch (shape) {
        .line => if (outsideSegment(a, b)) return whole,
        .conic => |centre| if (@abs(tb - ta) <= CONIC_PIECE) {
            const meet = vec.addScaled2(centre, vec.sub2(m, centre), 1 / @cos((tb - ta) / 2));
            if (outsideTriangle(a, meet, b)) return whole;
        },
        .sampled => {
            const left = angleBetween(a, m);
            const right = angleBetween(m, b);
            const small = @abs(whole) <= PIECE_ANGLE and @abs(left) <= PIECE_ANGLE and @abs(right) <= PIECE_ANGLE;
            if (small and @abs(left + right - whole) <= AGREE) return whole;
        },
    }
    if (depth >= MAX_DEPTH) return null;
    const first = sweptAngle(image, shape, ta, tm, a, m, depth + 1) orelse return null;
    return first + (sweptAngle(image, shape, tm, tb, m, b, depth + 1) orelse return null);
}

/// Whether the origin lies off the segment from `a` to `b`, exactly.
fn outsideSegment(a: Vec2, b: Vec2) bool {
    const o: Vec2 = .{ 0, 0 };
    if (predicates.orient2d(a, b, o) != 0) return true;
    // On its line: off it past an end
    return vec.dot2(a, b) > 0;
}

/// Whether the origin lies outside the triangle `a`, `q`, `b` (on its boundary is not
/// outside), exactly; a flat triangle is its segment.
fn outsideTriangle(a: Vec2, q: Vec2, b: Vec2) bool {
    const o: Vec2 = .{ 0, 0 };
    const turn = predicates.orient2d(a, q, b);
    if (turn == 0) return outsideSegment(a, b) and outsideSegment(a, q) and outsideSegment(q, b);
    for ([_][2]Vec2{ .{ a, q }, .{ q, b }, .{ b, a } }) |side| {
        const s = predicates.orient2d(side[0], side[1], o);
        if (s != 0 and (s > 0) != (turn > 0)) return true;
    }
    return false;
}

/// The signed angle from `a` to `b` about the origin, in (−π, π].
fn angleBetween(a: Vec2, b: Vec2) f64 {
    return trig.atan2(vec.cross2(a, b), vec.dot2(a, b));
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
