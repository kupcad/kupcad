//! Where two surfaces meet (docs/architecture.md §7.2). So far a plane against each kind
//! (`planeSurface`), what a plane section needs, exact in closed form: a plane cuts a
//! plane in a line; a cylinder in a circle (its axis along the plane's normal), two lines
//! (its axis in the plane) or an ellipse; a cone along its axis in a circle; a sphere in a
//! circle; a torus along its axis in two circles. A plane that only touches a surface (a
//! sphere's pole, a cylinder's side, a torus's crown, a cone's apex) is `tangent`: no
//! crossing, so a section takes nothing from it. The other cases (a cone or a torus cut
//! across its axis, the swept and NURBS kinds) wait for M5's surface intersections.
//!
//! "Along" and "across" are decided at the size of what is cut (`extent`): an axis is the
//! normal when tilting it by its angle moves no point of the region by more than the zone,
//! so a solid turned a right angle by rounded sines and cosines is cut as the exact one.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const diagnostics = @import("../diagnostics.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const curve_surface = @import("curve_surface.zig");
const Vec3 = vec.Vec3;
const Curve = curves.Curve;
const Surface = surfaces.Surface;
const Plane = curve_surface.Plane;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The milestone of the surface intersections the closed forms here do not cover.
const SURFACE_INTERSECTIONS = 5;

/// What a plane cuts from a surface.
pub const Trace = struct {
    kind: Kind,
    count: u8 = 0,
    /// The curves, in the plane: lines (the point nearest the region given), circles and
    /// ellipses turning counter-clockwise about the plane's normal.
    curves: [2]Curve = undefined,

    pub const Kind = enum {
        /// The plane misses the surface.
        none,
        /// The surface is the plane.
        coincident,
        /// The plane touches the surface without crossing it.
        tangent,
        /// The plane crosses the surface along `curves`.
        curves,
    };

    pub fn slice(self: *const Trace) []const Curve {
        return self.curves[0..self.count];
    }

    fn of(list: []const Curve) Trace {
        var out: Trace = .{ .kind = .curves, .count = @intCast(list.len) };
        @memcpy(out.curves[0..list.len], list);
        return out;
    }
};

/// The trace of `plane` on `surface` about the region of size `extent` around `near`
/// (a face's box: its diagonal and centre), which decides what is parallel and where a
/// line's origin is put.
pub fn planeSurface(plane: Plane, surface: Surface, near: Vec3, extent: f64, tol: Tolerance, diag: *Diagnostics) Error!Trace {
    return switch (surface) {
        .plane => |p| planePlane(plane, p.frame.origin, p.frame.z, near, extent, tol),
        .cylinder => |c| planeCylinder(plane, c, near, extent, tol),
        .cone => |c| try planeCone(plane, c, extent, tol, diag),
        .sphere => |s| planeSphere(plane, s, tol),
        .torus => |t| try planeTorus(plane, t, extent, tol, diag),
        .extrusion, .revolution, .nurbs => diagnostics.notImplemented(diag, "a plane's section of a swept or free-form surface", SURFACE_INTERSECTIONS),
    };
}

/// Whether tilting `axis` onto the plane's normal moves no point of a region of size
/// `extent` by more than the zone.
fn alongNormal(plane: Plane, axis: Vec3, extent: f64, tol: Tolerance) bool {
    return vec.length(vec.cross(plane.n, axis)) * extent <= tol.zone;
}

/// Whether tilting `axis` into the plane moves no point of the region by more than the
/// zone.
fn inPlane(plane: Plane, axis: Vec3, extent: f64, tol: Tolerance) bool {
    return @abs(vec.dot(plane.n, axis)) * extent <= tol.zone;
}

/// Two planes: parallel (coincident within the zone, measured at the point of the
/// surface's plane nearest `near`) or a line through the point nearest `near`.
fn planePlane(plane: Plane, origin: Vec3, normal: Vec3, near: Vec3, extent: f64, tol: Tolerance) Trace {
    if (alongNormal(plane, normal, extent, tol)) {
        const foot = vec.addScaled(near, normal, -vec.dot(normal, vec.sub(near, origin)));
        return .{ .kind = if (@abs(plane.height(foot)) <= tol.zone) .coincident else .none };
    }
    // The line of `n1·x = d1`, `n2·x = d2`: `(d1 (n2 × u) + d2 (u × n1)) / |u|²`, `u = n1 × n2`
    const u = vec.cross(plane.n, normal);
    const d2 = vec.dot(normal, origin);
    const through = vec.scale(vec.add(vec.scale(vec.cross(normal, u), plane.d), vec.scale(vec.cross(u, plane.n), d2)), 1 / vec.lengthSq(u));
    const d = vec.normalized(u).?;
    const o = vec.addScaled(through, d, vec.dot(d, vec.sub(near, through)));
    return Trace.of(&.{.{ .line = .{ .o = o, .d = d } }});
}

/// Where the surface's axis (through `origin` along unit `axis`) crosses the plane, as a
/// distance along it.
fn axisCrossing(plane: Plane, origin: Vec3, axis: Vec3) f64 {
    return -plane.height(origin) / vec.dot(plane.n, axis);
}

/// The circle of radius `r` about `c` in the plane, counter-clockwise about its normal.
fn circleIn(plane: Plane, c: Vec3, r: f64) Curve {
    return .{ .circle = curves.Circle.inPlane(c, plane.n, r) };
}

fn planeCylinder(plane: Plane, cyl: surfaces.Cylinder, near: Vec3, extent: f64, tol: Tolerance) Trace {
    const f = cyl.frame;
    if (alongNormal(plane, f.z, extent, tol)) {
        return Trace.of(&.{circleIn(plane, vec.addScaled(f.origin, f.z, axisCrossing(plane, f.origin, f.z)), cyl.r)});
    }
    if (inPlane(plane, f.z, extent, tol)) {
        // `height(o) + r (cos u·(n·x) + sin u·(n·y)) = 0` for the generators at angle `u`
        const nx = vec.dot(plane.n, f.x);
        const ny = vec.dot(plane.n, f.y);
        const m = cyl.r * @sqrt(nx * nx + ny * ny);
        const k = -plane.height(f.origin);
        if (@abs(k) > m + tol.zone) return .{ .kind = .none };
        if (@abs(k) >= m - tol.zone) return .{ .kind = .tangent };
        const phi = trig.atan2(ny, nx);
        const spread = std.math.acos(k / m);
        var lines: [2]Curve = undefined;
        for ([_]f64{ phi - spread, phi + spread }, &lines) |u, *line| {
            const on = cyl.eval(u, 0);
            line.* = .{ .line = .{ .o = vec.addScaled(on, f.z, vec.dot(f.z, vec.sub(near, on))), .d = f.z } };
        }
        return Trace.of(&lines);
    }
    // An ellipse about the axis's crossing: the semi-minor axis the radius, across the
    // axis in the plane; the semi-major the radius over the cosine of the tilt
    const ca = vec.dot(plane.n, f.z);
    const centre = vec.addScaled(f.origin, f.z, axisCrossing(plane, f.origin, f.z));
    const across = vec.normalized(vec.cross(f.z, plane.n)).?;
    const major = vec.cross(plane.n, across);
    return Trace.of(&.{.{ .ellipse = .{ .c = centre, .x = major, .y = vec.neg(across), .a = cyl.r / @abs(ca), .b = cyl.r } }});
}

fn planeCone(plane: Plane, cone: surfaces.Cone, extent: f64, tol: Tolerance, diag: *Diagnostics) Error!Trace {
    const f = cone.frame;
    if (!alongNormal(plane, f.z, extent, tol)) return diagnostics.notImplemented(diag, "a plane's section of a cone across its axis (a conic)", SURFACE_INTERSECTIONS);
    // The height along the axis is `v·cos α` at the generators' parameter `v`
    const t = axisCrossing(plane, f.origin, f.z);
    const r = @abs(cone.radiusAt(t / @cos(cone.half_angle)));
    if (r <= tol.zone) return .{ .kind = .tangent };
    return Trace.of(&.{circleIn(plane, vec.addScaled(f.origin, f.z, t), r)});
}

fn planeSphere(plane: Plane, sphere: surfaces.Sphere, tol: Tolerance) Trace {
    const h = plane.height(sphere.frame.origin);
    if (@abs(h) > sphere.r + tol.zone) return .{ .kind = .none };
    if (@abs(h) >= sphere.r - tol.zone) return .{ .kind = .tangent };
    return Trace.of(&.{circleIn(plane, vec.addScaled(sphere.frame.origin, plane.n, -h), @sqrt(sphere.r * sphere.r - h * h))});
}

fn planeTorus(plane: Plane, torus: surfaces.Torus, extent: f64, tol: Tolerance, diag: *Diagnostics) Error!Trace {
    const f = torus.frame;
    if (!alongNormal(plane, f.z, extent, tol)) return diagnostics.notImplemented(diag, "a plane's section of a torus across its axis", SURFACE_INTERSECTIONS);
    // The tube's points at height `minor·sin v` along the axis lie at `major ± minor·cos v`
    const t = axisCrossing(plane, f.origin, f.z);
    if (@abs(t) > torus.minor + tol.zone) return .{ .kind = .none };
    if (@abs(t) >= torus.minor - tol.zone) return .{ .kind = .tangent };
    const s = @sqrt(torus.minor * torus.minor - t * t);
    const centre = vec.addScaled(f.origin, f.z, t);
    if (@abs(torus.major - s) <= tol.zone) return Trace.of(&.{circleIn(plane, centre, torus.major + s)});
    return Trace.of(&.{ circleIn(plane, centre, torus.major + s), circleIn(plane, centre, @abs(torus.major - s)) });
}
