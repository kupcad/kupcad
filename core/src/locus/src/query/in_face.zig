//! Whether a point of a face's surface lies in the face (docs/architecture.md §7.6): on its
//! boundary when within a distance of one of its edges (measured in space, on the exact
//! edge curves), else inside when its loops wind about the point's parameters in UV. The
//! winding is the angle the loops sweep about the point, each coedge's image in UV (its
//! pcurve, or on a plane its curve projected; a coedge on a curved face without one, its
//! curve projected onto the surface) summed piece by piece, a piece halved until the angle
//! it subtends is small and its midpoint agrees, so no polyline of the boundary is ever
//! taken for it: a point away from the boundary is classified on the exact curves, and the
//! one test covers lines, circles, ellipses and NURBS alike. Used by every solid query.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const geometry = @import("../geometry/types.zig");
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
/// A piece's swept angle is taken from its chord when below this (radians) and when its
/// halves' angles sum to the chord's within `AGREE`.
const PIECE_ANGLE: f64 = 0.25;
const AGREE: f64 = 1e-9;
/// The Newton bound of the free-form kinds' projections in the queries (the tessellator's).
pub const NEWTON_STEPS: u32 = 50;

pub const Place = enum { inside, outside, boundary };

/// Where `p` (a point on face `f`'s surface, at parameters `uv`, unwrapped by `uvOf`)
/// lies against the face: on its boundary when within `within` of an edge, else inside
/// or outside by the winding of its loops.
pub fn classify(body: *const Body, f: types.FaceIndex, p: Vec3, uv: Vec2, within: f64, diag: *Diagnostics) Error!Place {
    if (try nearEdge(body, f, p, within, diag)) return .boundary;
    return if (try winds(body, f, uv, diag)) .inside else .outside;
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

/// The distance from `p` to edge `e`: to the nearest point of its curve within its range,
/// a periodic curve's parameter taken over a period when that brings it into the range,
/// else to the nearer end.
pub fn edgeDistance(body: *const Body, e: types.EdgeIndex, p: Vec3) f64 {
    return vec.distance(nearestOnEdge(body, e, p), p);
}

/// The nearest point to `p` on edge `e` (`edgeDistance`'s).
pub fn nearestOnEdge(body: *const Body, e: types.EdgeIndex, p: Vec3) Vec3 {
    const edge = body.edge(e);
    const curve = body.geometry.curve(edge.curve);
    if (edge.flags.degenerate) return curve.eval(edge.t0);
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
    if (t >= edge.t0 and t <= edge.t1) return curve.eval(t);
    const a = curve.eval(edge.t0);
    const b = curve.eval(edge.t1);
    return if (vec.distance(a, p) <= vec.distance(b, p)) a else b;
}

/// Whether the loops of face `f` wind about `uv`: the angle they sweep about it, a whole
/// number of turns, is not zero (holes wind back).
fn winds(body: *const Body, f: types.FaceIndex, uv: Vec2, diag: *Diagnostics) Error!bool {
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
            total += sweptAngle(image, from, to, a, b, 0);
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
};

/// The angle the image sweeps about the origin from parameter `ta` (at `a`) to `tb` (at
/// `b`), halving the piece until it subtends under `PIECE_ANGLE` and its halves agree.
fn sweptAngle(image: Image, ta: f64, tb: f64, a: Vec2, b: Vec2, depth: u8) f64 {
    const whole = angleBetween(a, b);
    if (depth >= MAX_DEPTH) return whole;
    const tm = ta + (tb - ta) / 2;
    const m = image.at(tm);
    const left = angleBetween(a, m);
    const right = angleBetween(m, b);
    if (@abs(whole) <= PIECE_ANGLE and @abs(left + right - whole) <= AGREE) return whole;
    return sweptAngle(image, ta, tm, a, m, depth + 1) + sweptAngle(image, tm, tb, m, b, depth + 1);
}

/// The signed angle from `a` to `b` about the origin, in (−π, π].
fn angleBetween(a: Vec2, b: Vec2) f64 {
    return trig.atan2(vec.cross2(a, b), vec.dot2(a, b));
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
