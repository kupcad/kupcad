//! Mass properties (docs/architecture.md §7.6): the volume and the area of a body by the
//! divergence theorem, face by face. A planar face is exact: its vector area is half the
//! boundary integral of `p × dp` (closed forms for lines, arcs and ellipses, Gauss
//! quadrature along a free-form edge), and `p · n` is one number on a plane. A curved face
//! is integrated over its UV region, the polygon of its loops' pcurves (or projections),
//! as signed fans of triangles from a corner, each triangle by Gauss quadrature refined
//! until two rules agree; what they still differ by is the error estimate. Independent of
//! any tessellation. Genus by Euler–Poincaré over every shell, as the mesh engine counts
//! it: `1 − χ/2`.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const bbox = @import("bbox.zig");
const Body = body_mod.Body;
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// Points per coedge of a curved face's UV polygon: one per end for a straight pcurve,
/// which is what every pcurve is today; a curved one is sampled this finely.
const UV_SAMPLES: usize = 8;
/// How closely the two Gauss rules on a triangle must agree, relative to the body's
/// measure, before the finer one is taken.
const AGREEMENT: f64 = 1e-11;
/// How deep a triangle is split in four before its estimate is taken as it is.
const MAX_SPLITS: u32 = 10;
/// Gauss–Legendre points along a free-form edge, per span of the curve's parameter.
pub const EDGE_SPANS: usize = 8;

/// What a body measures: its volume (0 for a sheet), its area (a sheet's is its faces'),
/// and what the quadrature's two rules still differed by, a bound on their error.
pub const Mass = struct {
    volume: f64,
    area: f64,
    volume_error: f64,
    area_error: f64,
};

/// The mass properties of `body`.
pub fn mass(body: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!Mass {
    try options.checkCancel();
    const extent = extentOf(body);
    var total = Totals{ .scale_volume = extent * extent * extent, .scale_area = extent * extent, .max_splits = @min(MAX_SPLITS, options.limits.subdivision_depth) };
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        var faces = traverse.Faces.init(body, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            try options.checkCancel();
            if (body.face(f).surface.kind == .plane) try planarFace(body, f, &total, diag) else try curvedFace(body, f, &total, diag);
        }
    }
    return .{
        .volume = if (body.kind == .sheet) 0 else total.volume / 3.0,
        .area = total.area,
        .volume_error = total.volume_error / 3.0,
        .area_error = total.area_error,
    };
}

/// The genus of `body` as the mesh engine counts it over every shell at once: `1 − χ/2`
/// for χ the sum of the shells' Euler characteristics (a sphere 0, a torus 1, two
/// spheres −1); a sheet has none and answers 0. Degenerate edges are points of the
/// surface, not edges of the graph.
pub fn genus(body: *const Body, diag: *Diagnostics) Error!i32 {
    if (body.kind == .sheet) return 0;
    var chi: i64 = 0;
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        if (body.shell(s).kind == .sheet) continue;
        chi += shellCharacteristic(body, s) catch return corrupt(diag);
    }
    if (@mod(chi, 2) != 0) return diag.fail(error.NotValid, .{ .code = .euler_poincare, .entity = .of(.body, 0), .measured = @floatFromInt(chi) });
    return @intCast(1 - @divExact(chi, 2));
}

/// `V − E + F − (L − F)` of one shell, its vertices and edges counted once each through
/// its faces.
fn shellCharacteristic(body: *const Body, s: types.ShellIndex) !i64 {
    var faces_n: i64 = 0;
    var loops_n: i64 = 0;
    var vertex_seen = std.AutoHashMapUnmanaged(u32, void).empty;
    defer vertex_seen.deinit(body.allocator);
    var edge_seen = std.AutoHashMapUnmanaged(u32, void).empty;
    defer edge_seen.deinit(body.allocator);
    var faces = traverse.Faces.init(body, s);
    while (try faces.next()) |f| {
        faces_n += 1;
        var loops = traverse.Loops.init(body, f);
        while (try loops.next()) |l| {
            loops_n += 1;
            if (body.loop(l).vertex != .none) try vertex_seen.put(body.allocator, @backingInt(body.loop(l).vertex), {});
            var it = traverse.Coedges.init(body, l);
            while (try it.next()) |c| {
                const e = body.coedge(c).edge;
                if (!body.edge(e).flags.degenerate) try edge_seen.put(body.allocator, @backingInt(e), {});
                try vertex_seen.put(body.allocator, @backingInt(body.coedgeStart(c)), {});
            }
        }
    }
    const v: i64 = @intCast(vertex_seen.count());
    const e: i64 = @intCast(edge_seen.count());
    return v - e + faces_n - (loops_n - faces_n);
}

/// The running sums: `volume` is `∮ p · n dA` (a third of it is the volume), `area` is
/// `∮ dA`, each with the quadrature's disagreement.
const Totals = struct {
    volume: f64 = 0,
    area: f64 = 0,
    volume_error: f64 = 0,
    area_error: f64 = 0,
    scale_volume: f64,
    scale_area: f64,
    max_splits: u32,
};

/// The body's size, what the quadrature's agreement is measured against.
fn extentOf(body: *const Body) f64 {
    const box = bbox.bodyBounds(body) catch return 1;
    if (box.isEmpty()) return 1;
    const extent = vec.length(vec.sub(box.max, box.min));
    return if (extent > 0) extent else 1;
}

/// A planar face: its vector area from its loops' boundary integrals, its `p · n` the
/// plane's.
fn planarFace(body: *const Body, f: types.FaceIndex, total: *Totals, diag: *Diagnostics) Error!void {
    const face = body.face(f);
    const plane = body.geometry.planes.items[face.surface.index];
    const outward = vec.scale(plane.frame.z, plane.frame.sign() * sense(face.same_sense));
    var twice_area = vec.ZERO3;
    var loops = traverse.Loops.init(body, f);
    while (loops.next() catch return corrupt(diag)) |l| {
        var it = traverse.Coedges.init(body, l);
        while (it.next() catch return corrupt(diag)) |c| {
            const coedge = body.coedge(c);
            const e = body.edge(coedge.edge);
            const integral = crossIntegral(body.geometry.curve(e.curve), e.t0, e.t1);
            twice_area = vec.addScaled(twice_area, integral, sense(coedge.same_sense));
        }
    }
    const area = vec.dot(twice_area, outward) / 2.0;
    total.area += area;
    total.volume += vec.dot(plane.frame.origin, outward) * area;
}

/// `∫ p × p' dt` over `[t0, t1]` of a curve: closed for a line, a circle and an ellipse
/// (`c × (p(t1) − p(t0))` plus the swept sector's `ab (t1 − t0) x × y`), by composite
/// Gauss quadrature for a free-form curve.
fn crossIntegral(curve: curves.Curve, t0: f64, t1: f64) Vec3 {
    switch (curve) {
        .line => |l| return vec.scale(vec.cross(l.o, l.d), t1 - t0),
        .circle => |c| return vec.add(vec.cross(c.c, vec.sub(c.eval(t1), c.eval(t0))), vec.scale(vec.cross(c.x, c.y), c.r * c.r * (t1 - t0))),
        .ellipse => |e| return vec.add(vec.cross(e.c, vec.sub(e.eval(t1), e.eval(t0))), vec.scale(vec.cross(e.x, e.y), e.a * e.b * (t1 - t0))),
        .nurbs => {
            var sum = vec.ZERO3;
            const step = (t1 - t0) / @as(f64, @floatFromInt(EDGE_SPANS));
            for (0..EDGE_SPANS) |k| {
                const a = t0 + step * @as(f64, @floatFromInt(k));
                for (GAUSS_10.nodes, GAUSS_10.weights) |x, w| {
                    const t = a + step * (x + 1.0) / 2.0;
                    sum = vec.addScaled(sum, vec.cross(curve.eval(t), curve.d1(t)), w * step / 2.0);
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
            var q = Quadrature{ .surface = surface, .max_splits = total.max_splits, .scale_volume = total.scale_volume, .scale_area = total.scale_area };
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
                surface.project(body.geometry.curve(e.curve).eval(t), body.tol.approx, 50)
            else
                body.geometry.pcurve(coedge.pcurve).eval(t);
            try polygon.append(body.allocator, uv);
        }
    }
}

fn sense(same_sense: bool) f64 {
    return if (same_sense) 1 else -1;
}

/// The integrals over one UV triangle, refined by splitting in four until a 5-point and
/// a 10-point rule (tensor Gauss–Legendre on the collapsed square) agree.
const Quadrature = struct {
    surface: surfaces.Surface,
    max_splits: u32,
    scale_volume: f64,
    scale_area: f64,
    volume: f64 = 0,
    area: f64 = 0,
    volume_error: f64 = 0,
    area_error: f64 = 0,

    const Pair = struct { volume: f64, area: f64 };

    fn triangle(self: *Quadrature, a: Vec2, b: Vec2, c: Vec2, splits: u32) void {
        const coarse = self.rule(a, b, c, GAUSS_5);
        const fine = self.rule(a, b, c, GAUSS_10);
        const dv = @abs(fine.volume - coarse.volume);
        const da = @abs(fine.area - coarse.area);
        if (splits < self.max_splits and (dv > AGREEMENT * self.scale_volume or da > AGREEMENT * self.scale_area)) {
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
                volume += weight * vec.dot(sample.p, n);
                area += weight * vec.length(n);
            }
        }
        return .{ .volume = volume, .area = area };
    }
};

pub const Gauss = struct { nodes: []const f64, weights: []const f64 };

/// Gauss–Legendre rules on [−1, 1].
const GAUSS_5 = Gauss{
    .nodes = &.{ -0.9061798459386640, -0.5384693101056831, 0.0, 0.5384693101056831, 0.9061798459386640 },
    .weights = &.{ 0.2369268850561891, 0.4786286704993665, 0.5688888888888889, 0.4786286704993665, 0.2369268850561891 },
};
pub const GAUSS_10 = Gauss{
    .nodes = &.{ -0.9739065285171717, -0.8650633666889845, -0.6794095682990244, -0.4333953941292472, -0.1488743389816312, 0.1488743389816312, 0.4333953941292472, 0.6794095682990244, 0.8650633666889845, 0.9739065285171717 },
    .weights = &.{ 0.0666713443086881, 0.1494513491505806, 0.2190863625159820, 0.2692667193099963, 0.2955242247147529, 0.2955242247147529, 0.2692667193099963, 0.2190863625159820, 0.1494513491505806, 0.0666713443086881 },
};

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
