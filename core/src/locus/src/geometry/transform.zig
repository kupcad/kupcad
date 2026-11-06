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

/// Classifies `a` within `tol`: a similarity when its columns are orthogonal (within
/// `angle`) and of one length (within `zone` relative to that length).
pub fn classify(a: *const Affine, tol: Tolerance) Shape {
    const det = a.determinant();
    if (!(det != 0.0) or !(det - det == 0)) return .singular;
    const lengths = a.columnLengths();
    const dots = a.columnDots();
    const scale = (lengths[0] + lengths[1] + lengths[2]) / 3.0;
    if (!(scale > 0.0)) return .singular;
    for (lengths) |l| if (@abs(l - scale) > tol.zone * scale) return .general;
    for (dots) |d| if (@abs(d) > tol.angle * scale * scale) return .general;
    return .{ .similarity = .{ .scale = scale, .mirror = det < 0.0 } };
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
            const len = vec.length(d);
            if (!(len > 0.0)) return error.NotRepresentable;
            return .{ .surface = .{ .extrusion = .{ .curve = gen.curve, .d = vec.scale(d, 1.0 / len) } }, .owned_curve = gen.owned, .v_scale = len };
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
