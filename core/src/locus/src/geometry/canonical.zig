//! When two records are the same geometry (docs/architecture.md §5.1, KNOWLEDGE §5): a
//! `keyPoint` per kind that two equal records share (the foot of a plane, a line or an axis
//! from a point `at`, a sphere's centre), so a welding grid narrows the candidates, and
//! `same` per kind, which compares the records within the tolerance (lengths within `zone`,
//! directions within `angle`). A rotation of a surface about its own axis is a
//! reparameterization, not a different surface, so a cylinder's `x` is not compared.
//!
//! Each `same` is the comparisons it rests on (`Comparison`, decided together by
//! `verdict`): a measure within rounding of its limit is the limit to rounding, which one
//! computation finds within and another beyond (a rigid move found it, 2026-11-13: two
//! planes 1e-5 apart were one record moved and two in place), so it is neither the same
//! nor apart but at the tolerance, and the interner refuses it (D27, as the boolean's
//! paves refuse a distance at the intersection tolerance).
//!
//! `at` is a point of the model (the interner's first), never the world's origin: a foot
//! moves by a direction's rounding times its distance from `at`, so from the origin two
//! pieces of one line 3.7e5 out had feet 1.5e-4 apart, past the zone, and were two lines
//! where the same model at the origin had one (rigid moves must not change a result,
//! architecture §9.2). From a point of the model the factor is the model's size.

const std = @import("std");
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const surfaces = @import("surfaces.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec3 = vec.Vec3;

/// How near its limit a measure may come, in ulps of the quantities it is measured from,
/// and still be decided: D27's 64, as the boolean's paves take it.
pub const AT_TOLERANCE_ULPS: f64 = 64;

/// One comparison a sameness rests on: `measured ≤ limit`, unless `measured` is within
/// `band` of `limit`, the limit to rounding.
pub const Comparison = struct {
    measured: f64,
    limit: f64,
    band: f64,

    /// A distance between points, or a difference of lengths, of size at most `scale`.
    pub fn distance(measured: f64, limit: f64, scale: f64) Comparison {
        return .{ .measured = measured, .limit = limit, .band = AT_TOLERANCE_ULPS * std.math.floatEps(f64) * @max(scale, limit) };
    }

    /// `1 − cos` of two unit directions, or a difference of angles, against `limit`.
    pub fn angle(measured: f64, limit: f64) Comparison {
        return .{ .measured = measured, .limit = limit, .band = AT_TOLERANCE_ULPS * std.math.floatEps(f64) };
    }
};

/// What comparisons say together: the same, apart, or at the tolerance (the comparison
/// within rounding of its limit).
pub const Verdict = union(enum) { same, apart, at_tolerance: Comparison };

/// Apart when any comparison is clearly past its limit (a NaN is), else at the tolerance
/// when any is within rounding of it, else the same.
pub fn verdict(comparisons: []const Comparison) Verdict {
    var tally: Tally = .{};
    for (comparisons) |c| tally.add(c);
    return tally.verdict();
}

/// `verdict` over comparisons given one at a time (a plane's, one per point it must hold).
pub const Tally = struct {
    apart: bool = false,
    at: ?Comparison = null,

    pub fn add(self: *Tally, c: Comparison) void {
        if (self.apart) return;
        if (!(c.measured <= c.limit + c.band)) {
            self.apart = true;
            return;
        }
        if (self.at == null and @abs(c.measured - c.limit) <= c.band) self.at = c;
    }

    pub fn verdict(self: Tally) Verdict {
        if (self.apart) return .apart;
        return if (self.at) |c| .{ .at_tolerance = c } else .same;
    }
};

/// The size of the largest coordinate of `points`: what their distances are rounded at.
pub fn magnitude(points: []const Vec3) f64 {
    var m: f64 = 0;
    for (points) |p| for (p) |c| {
        m = @max(m, @abs(c));
    };
    return m;
}

fn oneMinusAbsCos(a: Vec3, b: Vec3) f64 {
    return 1.0 - @abs(vec.dot(a, b));
}

/// The point of the line nearest `at`, from `at`: the same for the same line however it is
/// placed or directed.
pub fn lineKey(line: curves.Line, at: Vec3) Vec3 {
    const o = vec.sub(line.o, at);
    return vec.addScaled(o, line.d, -vec.dot(o, line.d));
}

/// Line `b`, asked for over `p` to `q`, against kept line `a`: parallel, the same key, and
/// `a` holding both ends (a line is shared only over the extent that asks for it).
pub fn sameLine(a: curves.Line, b: curves.Line, at: Vec3, p: Vec3, q: Vec3, tol: Tolerance) [4]Comparison {
    const scale = magnitude(&.{ a.o, b.o, p, q, at });
    return .{
        Comparison.angle(oneMinusAbsCos(a.d, b.d), tol.angle),
        Comparison.distance(vec.distance(lineKey(a, at), lineKey(b, at)), tol.zone, scale),
        Comparison.distance(lineOffset(a, p), tol.zone, scale),
        Comparison.distance(lineOffset(a, q), tol.zone, scale),
    };
}

/// How far `p` lies from the line.
pub fn lineOffset(line: curves.Line, p: Vec3) f64 {
    const d = vec.sub(p, line.o);
    return vec.length(vec.addScaled(d, line.d, -vec.dot(d, line.d)));
}

/// The same circle: the same centre and radius, and its plane tilted so little that its
/// rim moves within the zone, the radius times the tilt's sine (a circle's extent is its
/// radius; by the angular tolerance alone, 0.014 rad, two circles of radius 2 tilted 0.005
/// rad were one, their rims 0.01 apart). Either way round is the same circle.
pub fn sameCircle(a: curves.Circle, b: curves.Circle, tol: Tolerance) [3]Comparison {
    const scale = @max(magnitude(&.{ a.c, b.c }), @max(a.r, b.r));
    return .{
        Comparison.distance(vec.distance(a.c, b.c), tol.zone, scale),
        Comparison.distance(@abs(a.r - b.r), tol.zone, scale),
        Comparison.distance(@max(a.r, b.r) * vec.length(vec.cross(a.normal(), b.normal())), tol.zone, scale),
    };
}

pub fn sameEllipse(a: curves.Ellipse, b: curves.Ellipse, tol: Tolerance) [5]Comparison {
    const scale = @max(magnitude(&.{ a.c, b.c }), @max(a.a, b.a));
    return .{
        Comparison.distance(vec.distance(a.c, b.c), tol.zone, scale),
        Comparison.distance(@abs(a.a - b.a), tol.zone, scale),
        Comparison.distance(@abs(a.b - b.b), tol.zone, scale),
        Comparison.angle(oneMinusAbsCos(a.normal(), b.normal()), tol.angle),
        Comparison.angle(oneMinusAbsCos(a.x, b.x), tol.angle),
    };
}

/// The foot of the perpendicular from `at`, from `at`: the same for the same plane
/// whichever way its normal points.
pub fn planeKey(plane: surfaces.Plane, at: Vec3) Vec3 {
    const n = plane.frame.z;
    return vec.scale(n, vec.dot(vec.sub(plane.frame.origin, at), n));
}

/// Plane `b` against kept plane `a`: parallel, the same key, `b`'s origin on `a`; and `a`
/// holding every point the face asking for `b` spans (`planeHolds`), as a line is shared
/// only over the extent that asks for it: two planes a fraction of a degree apart through
/// one point are one plane there and apart across a face (a flattened hull's, the solids
/// fuzzer's find of 2026-11-13: an edge 0.0039 off the plane its face was given).
pub fn samePlane(a: surfaces.Plane, b: surfaces.Plane, at: Vec3, tol: Tolerance) [3]Comparison {
    const scale = magnitude(&.{ a.frame.origin, b.frame.origin, at });
    return .{
        Comparison.angle(oneMinusAbsCos(a.frame.z, b.frame.z), tol.angle),
        Comparison.distance(vec.distance(planeKey(a, at), planeKey(b, at)), tol.zone, scale),
        Comparison.distance(@abs(a.height(b.frame.origin)), tol.zone, scale),
    };
}

/// The point of the axis nearest `at`, from `at`.
/// Whether kept plane `a` holds `p`, the corner of a face asking for a plane like it.
pub fn planeHolds(a: surfaces.Plane, p: Vec3, tol: Tolerance) Comparison {
    return Comparison.distance(@abs(a.height(p)), tol.zone, magnitude(&.{ a.frame.origin, p }));
}

pub fn axisKey(frame: types.Frame, at: Vec3) Vec3 {
    const o = vec.sub(frame.origin, at);
    return vec.addScaled(o, frame.z, -vec.dot(o, frame.z));
}

pub fn sameCylinder(a: surfaces.Cylinder, b: surfaces.Cylinder, at: Vec3, tol: Tolerance) [3]Comparison {
    const scale = @max(magnitude(&.{ a.frame.origin, b.frame.origin, at }), @max(a.r, b.r));
    return .{
        Comparison.distance(@abs(a.r - b.r), tol.zone, scale),
        Comparison.angle(oneMinusAbsCos(a.frame.z, b.frame.z), tol.angle),
        Comparison.distance(vec.distance(axisKey(a.frame, at), axisKey(b.frame, at)), tol.zone, scale),
    };
}

/// The apex of the cone.
pub fn coneKey(cone: surfaces.Cone) Vec3 {
    return vec.addScaled(cone.frame.origin, cone.frame.z, cone.apexV() * @cos(cone.half_angle));
}

pub fn sameCone(a: surfaces.Cone, b: surfaces.Cone, tol: Tolerance) [3]Comparison {
    // The same cone: the same apex, the same axis line, the same half-angle, opening the
    // same way (a reversed axis with the same apex is the opposite nappe)
    const apex_a = coneKey(a);
    const apex_b = coneKey(b);
    return .{
        Comparison.distance(vec.distance(apex_a, apex_b), tol.zone, magnitude(&.{ apex_a, apex_b, a.frame.origin, b.frame.origin })),
        Comparison.angle(1.0 - vec.dot(a.frame.z, b.frame.z), tol.angle),
        Comparison.angle(@abs(a.half_angle - b.half_angle), tol.angle),
    };
}

pub fn sameSphere(a: surfaces.Sphere, b: surfaces.Sphere, tol: Tolerance) [2]Comparison {
    const scale = @max(magnitude(&.{ a.frame.origin, b.frame.origin }), @max(a.r, b.r));
    return .{
        Comparison.distance(vec.distance(a.frame.origin, b.frame.origin), tol.zone, scale),
        Comparison.distance(@abs(a.r - b.r), tol.zone, scale),
    };
}

pub fn sameTorus(a: surfaces.Torus, b: surfaces.Torus, tol: Tolerance) [4]Comparison {
    const scale = @max(magnitude(&.{ a.frame.origin, b.frame.origin }), @max(a.major + a.minor, b.major + b.minor));
    return .{
        Comparison.distance(vec.distance(a.frame.origin, b.frame.origin), tol.zone, scale),
        Comparison.angle(oneMinusAbsCos(a.frame.z, b.frame.z), tol.angle),
        Comparison.distance(@abs(a.major - b.major), tol.zone, scale),
        Comparison.distance(@abs(a.minor - b.minor), tol.zone, scale),
    };
}
