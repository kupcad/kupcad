//! The integrals over a body's faces by the divergence theorem (docs/architecture.md
//! §7.6): the flux of `p − centre` through each face, a third of which summed over a
//! closed shell is the volume it encloses, and each face's area. The one measure of what a
//! shell encloses: mass properties (`measure/mass.zig`), a shell found inside out made a
//! void (`construct/primitives.zig`'s `markVoids`) and the checker's rule that a closed
//! shell is wound outward (`check.zig`) all take it. The checker once summed its own fans
//! of triangles from a point of each face's UV box: over an L-shaped face 2.5e-4 wide
//! across a 100 by 150 plate, its corners within the zone of its plane but 1e-4 apart in
//! height, the fans swept 7500 of area whose heights did not cancel, and a sound
//! difference measured −0.376 for 0.155 (the 10K session on c3a83ee8, locus).
//!
//! A planar face is exact: its vector area is half the boundary integral of `p × dp`
//! (closed forms for lines, arcs and ellipses, Gauss quadrature along a free-form edge),
//! and `p · n` is one number on a plane. A curved face is integrated over its UV region,
//! the polygon of its loops' pcurves (or projections), as signed fans of triangles from a
//! corner, each triangle by Gauss quadrature refined until two rules agree; what they
//! still differ by is the error estimate. A planar face is its plane's region with ribbons
//! down to it from its loops, closed where a boolean left consecutive curves a gap apart
//! (`planarFace`), so a shell's faces close but for the gaps squared and `∮ n dA` is that
//! small: the volume is the same about any point to that. Every `p` of a shell is taken
//! from the centre of the shell's box, where its terms are the shell's size, not its
//! distance from the origin (a 2-unit box 3.7e5 out measured 4.5e-7 off about the origin)
//! nor from another part of the body (a union measured 1.4e-4 over itself about a centre
//! 70 units off beside a far part, its loops then open; the nightly solids fuzzer, run
//! 43585380964). Independent of any tessellation.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("types.zig");
const body_mod = @import("body.zig");
const traverse = @import("traverse.zig");
const bbox = @import("bbox.zig");
const Body = body_mod.Body;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// Points per coedge of a curved face's UV polygon: one per end for a straight pcurve,
/// which is what every pcurve is today; a curved one is sampled this finely.
const UV_SAMPLES: usize = 8;
/// How deep a triangle is split in four before its estimate is taken as it is.
const MAX_SPLITS: u32 = 10;
/// Gauss–Legendre points along a free-form edge, per span of the curve's parameter.
pub const EDGE_SPANS: usize = 8;

pub const Gauss = struct { nodes: []const f64, weights: []const f64 };

/// Gauss–Legendre rules on [−1, 1].
const GAUSS_3 = Gauss{
    .nodes = &.{ -0.7745966692414834, 0.0, 0.7745966692414834 },
    .weights = &.{ 0.5555555555555556, 0.8888888888888888, 0.5555555555555556 },
};
const GAUSS_5 = Gauss{
    .nodes = &.{ -0.9061798459386640, -0.5384693101056831, 0.0, 0.5384693101056831, 0.9061798459386640 },
    .weights = &.{ 0.2369268850561891, 0.4786286704993665, 0.5688888888888889, 0.4786286704993665, 0.2369268850561891 },
};
pub const GAUSS_10 = Gauss{
    .nodes = &.{ -0.9739065285171717, -0.8650633666889845, -0.6794095682990244, -0.4333953941292472, -0.1488743389816312, 0.1488743389816312, 0.4333953941292472, 0.6794095682990244, 0.8650633666889845, 0.9739065285171717 },
    .weights = &.{ 0.0666713443086881, 0.1494513491505806, 0.2190863625159820, 0.2692667193099963, 0.2955242247147529, 0.2955242247147529, 0.2692667193099963, 0.2190863625159820, 0.1494513491505806, 0.0666713443086881 },
};

/// How finely a curved face is integrated (OCCT's `BRepGProp` takes its `Eps` from the
/// caller alike): the two Gauss rules a UV triangle is taken by, and how closely they must
/// agree, relative to the body's measure, before the finer one is taken.
const Precision = struct { coarse: Gauss, fine: Gauss, agreement: f64 };
/// The measure itself (`shell`).
const MEASURE = Precision{ .coarse = GAUSS_5, .fine = GAUSS_10, .agreement = 1e-11 };
/// The first pass of `shellSense`, which only asks which way a shell faces.
const SENSE = Precision{ .coarse = GAUSS_3, .fine = GAUSS_5, .agreement = 1e-6 };

/// One shell's integrals: the volume it encloses (signed by its faces' outward sense:
/// negative for a void's), its area, and what the quadrature's two rules still differed by
/// for each, a bound on their error.
pub const Integrals = struct {
    volume: f64 = 0,
    area: f64 = 0,
    volume_error: f64 = 0,
    area_error: f64 = 0,
};

/// Shell `s` of `body`'s integrals, its faces' terms taken about the shell's own centre;
/// `place` is the body's (`placeOf`), what the quadrature's agreement is measured against
/// and the centre of a shell of no extent.
pub fn shell(body: *const Body, s: types.ShellIndex, place: Place, options: diagnostics.Options, diag: *Diagnostics) Error!Integrals {
    return measure(body, s, place, MEASURE, options, diag);
}

/// The volume shell `s` of `body` encloses, signed by its faces' outward sense (negative
/// for a void's, a cavity's faces facing into it), measured only as finely as its sign
/// needs: what tells a closed shell a void (`markVoids`) and one wound inward (the
/// checker). The quadrature's coarse pass settles the sign unless the volume is within
/// what its two rules differed by; then the measure's own precision does. A planar face
/// is exact either way. The checker takes it of every body built, so a cylinder no longer
/// pays the measure's 125 points a UV triangle to be found facing out (34 here).
pub fn shellSense(body: *const Body, s: types.ShellIndex, options: diagnostics.Options, diag: *Diagnostics) Error!f64 {
    const place = placeOf(body);
    const coarse = try measure(body, s, place, SENSE, options, diag);
    if (@abs(coarse.volume) > coarse.volume_error) return coarse.volume;
    return (try measure(body, s, place, MEASURE, options, diag)).volume;
}

fn measure(body: *const Body, s: types.ShellIndex, place: Place, precision: Precision, options: diagnostics.Options, diag: *Diagnostics) Error!Integrals {
    try options.checkCancel();
    const extent = place.extent;
    var total = Totals{ .centre = try shellCentre(body, s, diag) orelse place.centre, .precision = precision, .allowed_volume = precision.agreement * extent * extent * extent, .allowed_area = precision.agreement * extent * extent, .max_splits = @min(MAX_SPLITS, options.limits.subdivision_depth) };
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| {
        try options.checkCancel();
        if (body.face(f).surface.kind == .plane) try planarFace(body, f, &total, diag) else try curvedFace(body, f, &total, diag);
    }
    return .{ .volume = total.volume / 3.0, .area = total.area, .volume_error = total.volume_error / 3.0, .area_error = total.area_error };
}

/// The running sums: `volume` is `∮ (p − centre) · n dA` (a third of it is the volume),
/// `area` is `∮ dA`, each with the quadrature's disagreement.
const Totals = struct {
    centre: Vec3,
    volume: f64 = 0,
    area: f64 = 0,
    volume_error: f64 = 0,
    area_error: f64 = 0,
    precision: Precision,
    /// What the rules on one triangle may differ by: the agreement times the body's measure
    allowed_volume: f64,
    allowed_area: f64,
    max_splits: u32,
};

/// Where the body is: the centre of its box, which the integrals are taken from, and its
/// size, what the quadrature's agreement is measured against.
pub const Place = struct { centre: Vec3, extent: f64 };

/// The centre of shell `s`'s box, its faces'; null for a shell of no extent.
fn shellCentre(body: *const Body, s: types.ShellIndex, diag: *Diagnostics) Error!?Vec3 {
    var box = geometry.Box3.empty;
    var faces = traverse.Faces.init(body, s);
    while (faces.next() catch return corrupt(diag)) |f| box = geometry.Box3.merge(box, bbox.faceBounds(body, f) catch return corrupt(diag));
    if (box.isEmpty()) return null;
    return vec.scale(vec.add(box.min, box.max), 0.5);
}

/// The body's place: the centre and the diagonal of its box (1 for an empty one).
pub fn placeOf(body: *const Body) Place {
    const box = bbox.bodyBounds(body) catch return .{ .centre = vec.ZERO3, .extent = 1 };
    if (box.isEmpty()) return .{ .centre = vec.ZERO3, .extent = 1 };
    const extent = vec.length(vec.sub(box.max, box.min));
    return .{ .centre = vec.scale(vec.add(box.min, box.max), 0.5), .extent = if (extent > 0) extent else 1 };
}

/// A planar face: the region of its plane its loops bound (their projection), with the
/// ribbons from each piece of a loop down to that projection. A boolean's result is
/// geometry by provenance (D28): each face on its source's plane, each edge on its
/// source's line, its ends at a merged vertex's foot on that line. So a loop's consecutive
/// curves may end a little apart at a vertex with a gap (the step from one's end to the
/// next one's start is part of the loop), and an edge of one operand lying on a face of the
/// other within the tolerance is that edge's line, off the face's plane by its distance.
/// The region and the ribbons together meet the next face's along every edge, so a shell's
/// faces close but for the steps' little cycles about each vertex, the gaps squared, and
/// its volume is the same about any point to that. The region alone left them open, and
/// taken about the centre of a union, a plate's 50 units from a hull's corner and edge
/// 1.95e-4 off the plate's side, it measured the union 0.0084 over the plate and the hull's
/// part outside it (the 10K fuzz session, 2026-11-14). Where every edge lies in the plane
/// (any face built, not merged), the ribbons are nothing and the face is its region.
fn planarFace(body: *const Body, f: types.FaceIndex, total: *Totals, diag: *Diagnostics) Error!void {
    const face = body.face(f);
    const frame = body.geometry.planes.items[face.surface.index].frame;
    const outward = vec.scale(frame.z, frame.sign() * sense(face.same_sense));
    var twice_area = vec.ZERO3;
    var ribbons: f64 = 0;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        // Where the loop's first curve starts and the last one so far ended, the coedges' way
        var first: ?Vec3 = null;
        var last: Vec3 = undefined;
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const e = body.edge(coedge.edge);
            const curve = body.geometry.curve(e.curve);
            const from = curve.eval(if (coedge.same_sense) e.t0 else e.t1);
            if (first == null) {
                first = from;
            } else {
                twice_area = vec.add(twice_area, stepIntegral(last, from, total.centre));
                ribbons += stepRibbon(last, from, frame, total.centre);
            }
            twice_area = vec.addScaled(twice_area, crossIntegral(curve, e.t0, e.t1, total.centre), sense(coedge.same_sense));
            ribbons += sense(coedge.same_sense) * curveRibbon(curve, e.t0, e.t1, frame, total.centre);
            last = curve.eval(if (coedge.same_sense) e.t1 else e.t0);
        }
        if (first) |p| {
            twice_area = vec.add(twice_area, stepIntegral(last, p, total.centre));
            ribbons += stepRibbon(last, p, frame, total.centre);
        }
    }
    const area = vec.dot(twice_area, outward) / 2.0;
    total.area += area;
    total.volume += vec.dot(vec.sub(frame.origin, total.centre), outward) * area + ribbons;
}

/// `∫ (p − centre) × dp` along the segment from `a` to `b`.
fn stepIntegral(a: Vec3, b: Vec3, centre: Vec3) Vec3 {
    return vec.cross(vec.sub(a, centre), vec.sub(b, a));
}

/// The flux of `p − centre` through the ribbon from the segment `a b` down to its foot on
/// `frame`'s plane, `∫ h (p − centre) · (n × dp)` for `h` the height over the plane along
/// its axis `n` (either way up gives the same): along a segment `h` is linear and
/// `(p − m) · (n × dp)` nothing, so it is the mean height times `(m − centre) · (n × (b − a))`.
fn stepRibbon(a: Vec3, b: Vec3, frame: geometry.Frame, centre: Vec3) f64 {
    const height = (vec.dot(vec.sub(a, frame.origin), frame.z) + vec.dot(vec.sub(b, frame.origin), frame.z)) / 2.0;
    if (height == 0) return 0;
    const middle = vec.scale(vec.add(a, b), 0.5);
    return height * vec.dot(vec.sub(middle, centre), vec.cross(frame.z, vec.sub(b, a)));
}

/// `stepRibbon` along a curve over `[t0, t1]`: closed for a line, nothing for a circle or an
/// ellipse in the plane, by composite Gauss quadrature for any other.
fn curveRibbon(curve: curves.Curve, t0: f64, t1: f64, frame: geometry.Frame, centre: Vec3) f64 {
    switch (curve) {
        .line => |l| return stepRibbon(l.eval(t0), l.eval(t1), frame, centre),
        // The height along a conic is `h(c) + a cos t (x · n) + b sin t (y · n)`: none
        // anywhere when its centre and both axes lie in the plane (a face built, not merged)
        .circle => |c| if (inPlane(c.c, c.x, c.y, frame)) return 0 else return gaussRibbon(curve, t0, t1, frame, centre),
        .ellipse => |e| if (inPlane(e.c, e.x, e.y, frame)) return 0 else return gaussRibbon(curve, t0, t1, frame, centre),
        .nurbs => return gaussRibbon(curve, t0, t1, frame, centre),
    }
}

/// Whether a conic about `c` with axes `x` and `y` lies in `frame`'s plane exactly.
fn inPlane(c: Vec3, x: Vec3, y: Vec3, frame: geometry.Frame) bool {
    return vec.dot(vec.sub(c, frame.origin), frame.z) == 0 and vec.dot(x, frame.z) == 0 and vec.dot(y, frame.z) == 0;
}

/// `stepRibbon` along a curve by composite Gauss quadrature.
fn gaussRibbon(curve: curves.Curve, t0: f64, t1: f64, frame: geometry.Frame, centre: Vec3) f64 {
    var sum: f64 = 0;
    const step = (t1 - t0) / @as(f64, @floatFromInt(EDGE_SPANS));
    for (0..EDGE_SPANS) |k| {
        const a = t0 + step * @as(f64, @floatFromInt(k));
        for (GAUSS_10.nodes, GAUSS_10.weights) |x, w| {
            const t = a + step * (x + 1.0) / 2.0;
            const p = curve.eval(t);
            const height = vec.dot(vec.sub(p, frame.origin), frame.z);
            sum += w * step / 2.0 * height * vec.dot(vec.sub(p, centre), vec.cross(frame.z, curve.d1(t)));
        }
    }
    return sum;
}

/// `∫ (p − centre) × p' dt` over `[t0, t1]` of a curve: closed for a line, a circle and an
/// ellipse (`(c − centre) × (p(t1) − p(t0))` plus the swept sector's `ab (t1 − t0) x × y`),
/// by composite Gauss quadrature for a free-form curve.
fn crossIntegral(curve: curves.Curve, t0: f64, t1: f64, centre: Vec3) Vec3 {
    switch (curve) {
        .line => |l| return vec.scale(vec.cross(vec.sub(l.o, centre), l.d), t1 - t0),
        .circle => |c| return vec.add(vec.cross(vec.sub(c.c, centre), vec.sub(c.eval(t1), c.eval(t0))), vec.scale(vec.cross(c.x, c.y), c.r * c.r * (t1 - t0))),
        .ellipse => |e| return vec.add(vec.cross(vec.sub(e.c, centre), vec.sub(e.eval(t1), e.eval(t0))), vec.scale(vec.cross(e.x, e.y), e.a * e.b * (t1 - t0))),
        .nurbs => {
            var sum = vec.ZERO3;
            const step = (t1 - t0) / @as(f64, @floatFromInt(EDGE_SPANS));
            for (0..EDGE_SPANS) |k| {
                const a = t0 + step * @as(f64, @floatFromInt(k));
                for (GAUSS_10.nodes, GAUSS_10.weights) |x, w| {
                    const t = a + step * (x + 1.0) / 2.0;
                    sum = vec.addScaled(sum, vec.cross(vec.sub(curve.eval(t), centre), curve.d1(t)), w * step / 2.0);
                }
            }
            return sum;
        },
    }
}

/// A curved face: the integrals of `|N|` and `p · N` over its UV region, as signed fans
/// of triangles from the first corner of each loop (an outer loop adds, a hole takes away).
/// The loops run counter-clockwise in UV when the face's outward normal is the surface's,
/// so the fans' sign is the flux's sign already, and the area's sign to undo.
fn curvedFace(body: *const Body, f: types.FaceIndex, total: *Totals, diag: *Diagnostics) Error!void {
    const face = body.face(f);
    const surface = body.geometry.surface(face.surface);
    const s = sense(face.same_sense);
    var polygon = std.ArrayList(Vec2).empty;
    defer polygon.deinit(body.allocator);
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        try loopPolygon(body, l, surface, &polygon, diag);
        if (polygon.items.len < 3) continue;
        const apex = polygon.items[0];
        for (1..polygon.items.len - 1) |i| {
            var q = Quadrature{ .surface = surface, .centre = total.centre, .precision = total.precision, .max_splits = total.max_splits, .allowed_volume = total.allowed_volume, .allowed_area = total.allowed_area };
            q.triangle(apex, polygon.items[i], polygon.items[i + 1], 0);
            total.volume += q.volume;
            total.area += s * q.area;
            total.volume_error += q.volume_error;
            total.area_error += q.area_error;
        }
    }
}

/// The loop's UV polygon: its coedges' pcurves sampled, else their edges projected.
fn loopPolygon(body: *const Body, l: types.LoopIndex, surface: surfaces.Surface, polygon: *std.ArrayList(Vec2), diag: *Diagnostics) Error!void {
    polygon.clearRetainingCapacity();
    var it = traverse.Coedges.init(body, l);
    while (it.next() catch return corrupt(diag)) |c| {
        const coedge = body.coedge(c);
        const e = body.edge(coedge.edge);
        const from: f64 = if (coedge.same_sense) e.t0 else e.t1;
        const to: f64 = if (coedge.same_sense) e.t1 else e.t0;
        const samples: usize = if (!coedge.pcurve.isNone() and coedge.pcurve.kind == .line2) 1 else UV_SAMPLES;
        for (0..samples) |k| {
            const t = from + (to - from) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(samples));
            const uv = if (coedge.pcurve.isNone())
                surface.project(body.geometry.curve(e.curve).eval(t), body.tol.approx, geometry.PROJECT_STEPS)
            else
                body.geometry.pcurve(coedge.pcurve).eval(t);
            try polygon.append(body.allocator, uv);
        }
    }
}

fn sense(same_sense: bool) f64 {
    return if (same_sense) 1 else -1;
}

/// The integrals over one UV triangle, refined by splitting in four until the precision's
/// two rules (tensor Gauss–Legendre on the collapsed square) agree.
const Quadrature = struct {
    surface: surfaces.Surface,
    centre: Vec3,
    precision: Precision,
    max_splits: u32,
    allowed_volume: f64,
    allowed_area: f64,
    volume: f64 = 0,
    area: f64 = 0,
    volume_error: f64 = 0,
    area_error: f64 = 0,

    const Pair = struct { volume: f64, area: f64 };

    fn triangle(self: *Quadrature, a: Vec2, b: Vec2, c: Vec2, splits: u32) void {
        const coarse = self.rule(a, b, c, self.precision.coarse);
        const fine = self.rule(a, b, c, self.precision.fine);
        const dv = @abs(fine.volume - coarse.volume);
        const da = @abs(fine.area - coarse.area);
        if (splits < self.max_splits and (dv > self.allowed_volume or da > self.allowed_area)) {
            const ab = vec.scale2(vec.add2(a, b), 0.5);
            const bc = vec.scale2(vec.add2(b, c), 0.5);
            const ca = vec.scale2(vec.add2(c, a), 0.5);
            self.triangle(a, ab, ca, splits + 1);
            self.triangle(ab, b, bc, splits + 1);
            self.triangle(ca, bc, c, splits + 1);
            self.triangle(ab, bc, ca, splits + 1);
            return;
        }
        self.volume += fine.volume;
        self.area += fine.area;
        self.volume_error += dv;
        self.area_error += da;
    }

    /// The signed integrals over the triangle (positive when `a, b, c` turn
    /// counter-clockwise): `(u, v) = a + s (b − a) + s t (c − b)`, the Jacobian `2 A s`.
    fn rule(self: *const Quadrature, a: Vec2, b: Vec2, c: Vec2, g: Gauss) Pair {
        const twice_signed_area = (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]);
        var volume: f64 = 0;
        var area: f64 = 0;
        for (g.nodes, g.weights) |xs, ws| {
            const s = (xs + 1.0) / 2.0;
            for (g.nodes, g.weights) |xt, wt| {
                const t = (xt + 1.0) / 2.0;
                const u = a[0] + s * ((b[0] - a[0]) + t * (c[0] - b[0]));
                const v = a[1] + s * ((b[1] - a[1]) + t * (c[1] - b[1]));
                const sample = self.surface.sample(u, v);
                const n = vec.cross(sample.du, sample.dv);
                const weight = ws * wt / 4.0 * twice_signed_area * s;
                volume += weight * vec.dot(vec.sub(sample.p, self.centre), n);
                area += weight * vec.length(n);
            }
        }
        return .{ .volume = volume, .area = area };
    }
};

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
