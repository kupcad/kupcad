//! Geometry under an affine map (docs/architecture.md §5.1, the transforms item of M0).
//! A similarity (a rigid move, a uniform scale, a mirror) maps every kind exactly, with its
//! parameterization kept: frames move with the map and may turn left-handed under a mirror
//! (STEP and OCCT allow such placements; the normals follow `Frame.sign`), radii scale,
//! and a line's or an extrusion's length parameter scales by the map's factor. Under any
//! other affine map (a non-uniform scale, a shear) a plane stays a plane and NURBS stay
//! NURBS with their parameters, a line's parameter scales, the extrusion of a line or a
//! NURBS curve survives, and every other kind is `error.NotRepresentable`: its NURBS form
//! has another parameterization, which the pcurves on it would no longer fit.

const std = @import("std");
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const surfaces = @import("surfaces.zig");
const nurbs = @import("nurbs.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;
const Affine = mat.Affine;
const Frame = types.Frame;

pub const Error = error{ OutOfMemory, NotRepresentable };

/// What an affine map is, as far as geometry cares.
pub const Shape = union(enum) {
    /// Orthogonal up to one factor: every length times `scale`, mirrored when `mirror`.
    similarity: struct { scale: f64, mirror: bool },
    /// Anything else: lengths depend on direction.
    general,
    /// Not invertible: every body collapses.
    singular,
};

/// How many times the rounding of 1 a matrix's columns may differ in length, or fail to be
/// square to each other, and the matrix still be a similarity as given: the rounding of
/// composing a few dozen turns.
const SIMILAR_ULPS: f64 = 64;
/// Newton–Schulz steps to the orthogonal matrix nearest one within the tolerance of it:
/// each squares the departure, so from 1e-3 the third is past rounding.
const SNAP_STEPS: usize = 3;

/// How far `a`'s linear part is from a similarity, as a share of its factor: the most a
/// column's length differs from the columns' mean, or two columns' cosine. Null for a map
/// that is singular or not finite.
const Departure = struct { scale: f64, share: f64 };

fn departure(a: *const Affine) ?Departure {
    const det = a.determinant();
    if (!(det != 0.0) or !(det - det == 0)) return null;
    const lengths = a.columnLengths();
    const dots = a.columnDots();
    const scale = (lengths[0] + lengths[1] + lengths[2]) / 3.0;
    if (!(scale > 0.0)) return null;
    var share: f64 = 0;
    for (lengths) |l| share = @max(share, @abs(l - scale) / scale);
    for (dots) |d| share = @max(share, @abs(d) / (scale * scale));
    return .{ .scale = scale, .share = share };
}

/// Classifies `a`: a similarity when its columns are of one length and square to each
/// other to rounding (`SIMILAR_ULPS`), whatever the tolerance. A similarity's frames are
/// mapped as they are and stay orthonormal only as far as the matrix is one: a matrix
/// stretched 9e-6 along an axis or sheared 9e-5 passed for a similarity while the limits
/// were the body's zone as a share and its angular tolerance as a cosine, its circles'
/// and cylinders' frames off by that much, on a body of 100 an error of 1e-3, and the
/// answer went by the zone (the audit of 2026-11-22). OCCT's `gp_GTrsf::SetForm` holds
/// `MᵀM/s² − I` to 1e-12. A matrix a little further off is `nearSimilarity`'s.
pub fn classify(a: *const Affine) Shape {
    const d = departure(a) orelse return .singular;
    if (d.share > SIMILAR_ULPS * std.math.floatEps(f64)) return .general;
    return .{ .similarity = .{ .scale = d.scale, .mirror = a.determinant() < 0.0 } };
}

/// The similarity nearest `a`, when taking it for `a` moves no point within `reach` of the
/// origin by more than the zone (at the map's scale): `a`'s departure from a similarity
/// times `reach` within `tol.zone`. A matrix typed to a few digits, or composed of many
/// turns, is one the host meant; past that limit the map is the stretch or shear it is
/// (null, `classify`'s `general`). The nearest is the matrix's orthogonal polar factor
/// at its mean column length, by Newton–Schulz steps `Q ← Q(3I − QᵀQ)/2`; the translation
/// is kept.
pub fn nearSimilarity(a: *const Affine, tol: Tolerance, reach: f64) ?Affine {
    const d = departure(a) orelse return null;
    if (!(d.share * reach <= tol.zone)) return null;
    var q: mat.Mat3 = undefined;
    for (a.linear, &q) |v, *o| o.* = v / d.scale;
    for (0..SNAP_STEPS) |_| {
        const qt = mat.transpose3(&q);
        var correction = mat.mul3(&qt, &q);
        for (&correction, 0..) |*v, k| v.* = ((if (k % 4 == 0) @as(f64, 3) else 0) - v.*) / 2;
        q = mat.mul3(&q, &correction);
    }
    var out = a.*;
    for (&out.linear, q) |*o, v| o.* = v * d.scale;
    return out;
}

/// A frame under a similarity: axes mapped and renormalized, left-handed after a mirror.
pub fn frame(f: Frame, a: *const Affine, scale: f64) Frame {
    return .{
        .origin = a.point(f.origin),
        .x = vec.scale(a.vector(f.x), 1.0 / scale),
        .y = vec.scale(a.vector(f.y), 1.0 / scale),
        .z = vec.scale(a.vector(f.z), 1.0 / scale),
    };
}

/// An extrusion's direction `d` mapped (`a.vector` of it), and the factor its v scales by.
/// Under a similarity by the map's factor, as a line's direction (find er): measured again,
/// a direction whose length rounds to 1 − 1 ulp was renormalized and its v rescaled under a
/// mirror, the extrusion and its points off the mirror image (the audit of order and frame,
/// 2026-11-27). Under another map by its length, as the line's. Null when it collapses.
pub fn extrusionAlong(d: Vec3, shape: Shape) ?struct { d: Vec3, v_scale: f64 } {
    if (shape == .similarity) return .{ .d = vec.scale(d, 1.0 / shape.similarity.scale), .v_scale = shape.similarity.scale };
    const len = vec.length(d);
    if (!(len > 0.0)) return null;
    return .{ .d = vec.scale(d, 1.0 / len), .v_scale = len };
}

/// A homogeneous control point under `a`: the point mapped, the weight kept.
fn controlPoint(q: Vec4, a: *const Affine) Vec4 {
    const p = a.point(vec.project4(q));
    return vec.weighted(p, q[3]);
}

/// A curve under a map: the curve, and the factor its parameter was scaled by (`t' = t ·
/// t_scale`; 1 but for lines).
pub const Curve = struct {
    curve: curves.Curve,
    /// Owned NURBS data when the result is one; the view in `curve` borrows it.
    owned: ?nurbs.CurveData = null,
    t_scale: f64 = 1.0,

    pub fn deinit(self: *Curve, allocator: std.mem.Allocator) void {
        if (self.owned) |*d| d.deinit(allocator);
        self.* = undefined;
    }
};

/// `c` under `a`, exact (see the module doc). `t0`, `t1`: the parameter range in use, which
/// a general map needs for the NURBS form of an arc. The result's `t_scale` applies to
/// them: a line's range becomes `[t0 · s, t1 · s]`.
pub fn curve(allocator: std.mem.Allocator, c: curves.Curve, t0: f64, t1: f64, a: *const Affine, shape: Shape) Error!Curve {
    switch (c) {
        .line => |l| {
            const d = a.vector(l.d);
            // Under a similarity the direction by the map's factor and the parameter by it,
            // as frames and circles take theirs: measured again, the direction's length
            // rounded, a mirror's line was renormalized and its edges' ranges rescaled by
            // it, its end 1 ulp off the mirror image of the line's, and a distance at the
            // edge of D27's band was refused in place and made mirrored (the locus
            // session's find er on 621b9ee0)
            if (shape == .similarity) return .{ .curve = .{ .line = .{ .o = a.point(l.o), .d = vec.scale(d, 1.0 / shape.similarity.scale) } }, .t_scale = shape.similarity.scale };
            const len = vec.length(d);
            if (!(len > 0.0)) return error.NotRepresentable;
            return .{ .curve = .{ .line = .{ .o = a.point(l.o), .d = vec.scale(d, 1.0 / len) } }, .t_scale = len };
        },
        .circle => |ci| switch (shape) {
            .similarity => |s| return .{ .curve = .{ .circle = .{ .c = a.point(ci.c), .x = vec.scale(a.vector(ci.x), 1.0 / s.scale), .y = vec.scale(a.vector(ci.y), 1.0 / s.scale), .r = ci.r * s.scale } } },
            else => return mapped(allocator, c, t0, t1, a),
        },
        .ellipse => |e| switch (shape) {
            .similarity => |s| return .{ .curve = .{ .ellipse = .{ .c = a.point(e.c), .x = vec.scale(a.vector(e.x), 1.0 / s.scale), .y = vec.scale(a.vector(e.y), 1.0 / s.scale), .a = e.a * s.scale, .b = e.b * s.scale } } },
            else => return mapped(allocator, c, t0, t1, a),
        },
        .nurbs => return mapped(allocator, c, t0, t1, a),
    }
}

/// The NURBS form of `c` over `[t0, t1]` with its control points mapped: exact under any
/// affine map, the parameter kept.
fn mapped(allocator: std.mem.Allocator, c: curves.Curve, t0: f64, t1: f64, a: *const Affine) Error!Curve {
    var data = if (c == .nurbs) try c.nurbs.toOwned(allocator) else try c.toNurbs(allocator, t0, t1);
    errdefer data.deinit(allocator);
    for (data.points) |*q| q.* = controlPoint(q.*, a);
    return .{ .curve = .{ .nurbs = data.view() }, .owned = data };
}

/// A surface under a map: the surface, and the factors its parameters were scaled by.
pub const Surface = struct {
    surface: surfaces.Surface,
    owned: ?nurbs.SurfaceData = null,
    /// The generator of a swept kind, when it had to be converted.
    owned_curve: ?nurbs.CurveData = null,
    u_scale: f64 = 1.0,
    v_scale: f64 = 1.0,
    /// A plane under a general map: its UV axes are rebuilt and the old parameters mean
    /// nothing on it (pcurves on planes are computed, never stored, so nothing is lost).
    reparameterized: bool = false,

    pub fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
        if (self.owned) |*d| d.deinit(allocator);
        if (self.owned_curve) |*d| d.deinit(allocator);
        self.* = undefined;
    }
};

/// `s` under `a` (see the module doc). `box`: the UV range in use, for the generator of a
/// swept kind under a general map. `error.NotRepresentable` names what cannot be mapped
/// exactly; the caller refuses the operation.
pub fn surface(allocator: std.mem.Allocator, s: surfaces.Surface, box: types.Box2, a: *const Affine, shape: Shape) Error!Surface {
    const similarity: ?f64 = switch (shape) {
        .similarity => |sim| sim.scale,
        .general => null,
        .singular => return error.NotRepresentable,
    };
    switch (s) {
        .plane => |p| {
            // Its parameters are lengths along the axes: they scale with the map
            if (similarity) |k| return .{ .surface = .{ .plane = .{ .frame = frame(p.frame, a, k) } }, .u_scale = k, .v_scale = k };
            // A plane stays a plane: the normal by the inverse transpose, the axes rebuilt
            // (pcurves on planes are computed, never stored, so the parameterization is free)
            const nm = a.normalMatrix() orelse return error.NotRepresentable;
            const n = vec.normalized(mat.apply3(&nm, p.frame.z)) orelse return error.NotRepresentable;
            const x_image = a.vector(p.frame.x);
            const x = vec.normalized(vec.sub(x_image, vec.scale(n, vec.dot(x_image, n)))) orelse return error.NotRepresentable;
            return .{ .surface = .{ .plane = .{ .frame = Frame.init(a.point(p.frame.origin), x, n) } }, .reparameterized = true };
        },
        .cylinder => |c| {
            const k = similarity orelse return error.NotRepresentable;
            return .{ .surface = .{ .cylinder = .{ .frame = frame(c.frame, a, k), .r = c.r * k } }, .v_scale = k };
        },
        .cone => |c| {
            const k = similarity orelse return error.NotRepresentable;
            return .{ .surface = .{ .cone = .{ .frame = frame(c.frame, a, k), .r = c.r * k, .half_angle = c.half_angle } }, .v_scale = k };
        },
        .sphere => |sp| {
            const k = similarity orelse return error.NotRepresentable;
            return .{ .surface = .{ .sphere = .{ .frame = frame(sp.frame, a, k), .r = sp.r * k } } };
        },
        .torus => |t| {
            const k = similarity orelse return error.NotRepresentable;
            return .{ .surface = .{ .torus = .{ .frame = frame(t.frame, a, k), .major = t.major * k, .minor = t.minor * k } } };
        },
        .extrusion => |e| {
            // The generator under its own rule; the direction's length scales v
            var gen = try curve(allocator, e.curve, box.min[0], box.max[0], a, shape);
            errdefer gen.deinit(allocator);
            // A line generator's u would scale, and an arc's NURBS form has another
            // parameterization: only a generator that keeps its parameters survives
            if (gen.t_scale != 1.0 or (gen.owned != null and e.curve != .nurbs)) return error.NotRepresentable;
            const d = a.vector(e.d);
            const along = extrusionAlong(d, shape) orelse return error.NotRepresentable;
            return .{ .surface = .{ .extrusion = .{ .curve = gen.curve, .d = along.d } }, .owned_curve = gen.owned, .v_scale = along.v_scale };
        },
        .revolution => |r| {
            const k = similarity orelse return error.NotRepresentable;
            var gen = try curve(allocator, r.curve, box.min[1], box.max[1], a, shape);
            errdefer gen.deinit(allocator);
            if (gen.t_scale != 1.0) return .{ .surface = .{ .revolution = .{ .curve = gen.curve, .frame = frame(r.frame, a, k) } }, .owned_curve = gen.owned, .v_scale = gen.t_scale };
            return .{ .surface = .{ .revolution = .{ .curve = gen.curve, .frame = frame(r.frame, a, k) } }, .owned_curve = gen.owned };
        },
        .nurbs => |n| {
            var data = try n.toOwned(allocator);
            errdefer data.deinit(allocator);
            for (data.points) |*q| q.* = controlPoint(q.*, a);
            return .{ .surface = .{ .nurbs = data.view() }, .owned = data };
        },
    }
}
