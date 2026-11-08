//! When two records are the same geometry (docs/architecture.md §5.1, KNOWLEDGE §5): a
//! `keyPoint` per kind that two equal records share (the foot of a plane or a line from
//! the origin, a sphere's centre), so a welding grid narrows the candidates, and `same`
//! per kind, which compares the records within the tolerance (lengths within `zone`,
//! directions within `angle`). A rotation of a surface about its own axis is a
//! reparameterization, not a different surface, so a cylinder's `x` is not compared.

const std = @import("std");
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const surfaces = @import("surfaces.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Vec3 = vec.Vec3;

/// The point of the line nearest the origin: the same for the same line however it is
/// placed or directed.
pub fn lineKey(line: curves.Line) Vec3 {
    return vec.addScaled(line.o, line.d, -vec.dot(line.o, line.d));
}

pub fn sameLine(a: curves.Line, b: curves.Line, tol: Tolerance) bool {
    return tol.parallel(a.d, b.d) and tol.samePoint(lineKey(a), lineKey(b));
}

/// Whether `p` lies on the line within `zone`.
pub fn lineHolds(line: curves.Line, p: Vec3, tol: Tolerance) bool {
    const d = vec.sub(p, line.o);
    const off = vec.addScaled(d, line.d, -vec.dot(d, line.d));
    return vec.lengthSq(off) <= tol.zone * tol.zone;
}

pub fn sameCircle(a: curves.Circle, b: curves.Circle, tol: Tolerance) bool {
    return tol.samePoint(a.c, b.c) and @abs(a.r - b.r) <= tol.zone and tol.parallel(a.normal(), b.normal());
}

pub fn sameEllipse(a: curves.Ellipse, b: curves.Ellipse, tol: Tolerance) bool {
    return tol.samePoint(a.c, b.c) and @abs(a.a - b.a) <= tol.zone and @abs(a.b - b.b) <= tol.zone and
        tol.parallel(a.normal(), b.normal()) and tol.parallel(a.x, b.x);
}

/// The foot of the perpendicular from the origin: the same for the same plane whichever
/// way its normal points.
pub fn planeKey(plane: surfaces.Plane) Vec3 {
    const n = plane.frame.z;
    return vec.scale(n, vec.dot(plane.frame.origin, n));
}

pub fn samePlane(a: surfaces.Plane, b: surfaces.Plane, tol: Tolerance) bool {
    if (!tol.parallel(a.frame.z, b.frame.z)) return false;
    // The same plane: b's origin lies on a
    return @abs(a.height(b.frame.origin)) <= tol.zone;
}

/// The point of the axis nearest the origin.
pub fn axisKey(frame: types.Frame) Vec3 {
    return vec.addScaled(frame.origin, frame.z, -vec.dot(frame.origin, frame.z));
}

pub fn sameCylinder(a: surfaces.Cylinder, b: surfaces.Cylinder, tol: Tolerance) bool {
    return @abs(a.r - b.r) <= tol.zone and tol.parallel(a.frame.z, b.frame.z) and tol.samePoint(axisKey(a.frame), axisKey(b.frame));
}

/// The apex of the cone.
pub fn coneKey(cone: surfaces.Cone) Vec3 {
    return vec.addScaled(cone.frame.origin, cone.frame.z, cone.apexV() * @cos(cone.half_angle));
}

pub fn sameCone(a: surfaces.Cone, b: surfaces.Cone, tol: Tolerance) bool {
    // The same cone: the same apex, the same axis line, the same half-angle, opening the
    // same way (a reversed axis with the same apex is the opposite nappe)
    return tol.samePoint(coneKey(a), coneKey(b)) and tol.sameDirection(a.frame.z, b.frame.z) and @abs(a.half_angle - b.half_angle) <= tol.angle;
}

pub fn sameSphere(a: surfaces.Sphere, b: surfaces.Sphere, tol: Tolerance) bool {
    return tol.samePoint(a.frame.origin, b.frame.origin) and @abs(a.r - b.r) <= tol.zone;
}

pub fn sameTorus(a: surfaces.Torus, b: surfaces.Torus, tol: Tolerance) bool {
    return tol.samePoint(a.frame.origin, b.frame.origin) and tol.parallel(a.frame.z, b.frame.z) and
        @abs(a.major - b.major) <= tol.zone and @abs(a.minor - b.minor) <= tol.zone;
}
