//! The curve kinds and their parametric contract (docs/architecture.md §5.1, STEP Part 42's
//! parameterizations): `domain`, `eval`, `d1`, `d2`, `project` (closed form here; Newton for
//! NURBS, in nurbs.zig), `bounds` over a parameter range, and `toNurbs`. `Curve` dispatches
//! over the kinds with one `switch` per function.

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const types = @import("types.zig");
const nurbs = @import("nurbs.zig");
const Vec3 = vec.Vec3;
const Domain = types.Domain;
const Box3 = types.Box3;
const TWO_PI = types.TWO_PI;

/// The most halvings of the bracket of an ellipse's nearest point (`Ellipse.project`):
/// enough to reach any double's ulp from any start, the double's digits and exponents.
const MAX_BISECTIONS: usize = 1100;

/// A sample of a curve: the point and its first two derivatives.
pub const Sample = nurbs.Sample;

/// `o + t·d`, `d` unit, `t` in millimetres over all reals.
pub const Line = struct {
    o: Vec3,
    d: Vec3,

    /// Through `a` and `b`, `t = 0` at `a` and `t = |b − a|` at `b`; null when they coincide.
    pub fn through(a: Vec3, b: Vec3) ?Line {
        const d = vec.normalized(vec.sub(b, a)) orelse return null;
        return .{ .o = a, .d = d };
    }

    pub fn domain(_: Line) Domain {
        return Domain.unbounded;
    }

    pub fn eval(self: Line, t: f64) Vec3 {
        return vec.addScaled(self.o, self.d, t);
    }

    pub fn sample(self: Line, t: f64) Sample {
        return .{ .p = self.eval(t), .d1 = self.d, .d2 = vec.ZERO3 };
    }

    pub fn project(self: Line, p: Vec3) f64 {
        return vec.dot(vec.sub(p, self.o), self.d);
    }

    pub fn bounds(self: Line, t0: f64, t1: f64) Box3 {
        var box = Box3.ofPoint(self.eval(t0));
        box.grow(self.eval(t1));
        return box;
    }
};

/// `c + r(cos θ·x + sin θ·y)`, `θ ∈ [0, 2π)`, periodic; `x`, `y` unit and orthogonal, the
/// circle counter-clockwise about `x × y`.
pub const Circle = struct {
    c: Vec3,
    x: Vec3,
    y: Vec3,
    r: f64,

    /// In the plane with unit normal `n`, about `c`, the reference direction chosen
    /// deterministically from `n`.
    pub fn inPlane(c: Vec3, n: Vec3, r: f64) Circle {
        const x = vec.perpendicular(n);
        return .{ .c = c, .x = x, .y = vec.cross(n, x), .r = r };
    }

    pub fn normal(self: Circle) Vec3 {
        return vec.cross(self.x, self.y);
    }

    pub fn domain(_: Circle) Domain {
        return .{ .t0 = 0, .t1 = TWO_PI, .periodic = true };
    }

    pub fn eval(self: Circle, t: f64) Vec3 {
        return vec.add(self.c, vec.add(vec.scale(self.x, self.r * @cos(t)), vec.scale(self.y, self.r * @sin(t))));
    }

    pub fn sample(self: Circle, t: f64) Sample {
        const c = @cos(t);
        const s = @sin(t);
        const radial = vec.add(vec.scale(self.x, self.r * c), vec.scale(self.y, self.r * s));
        return .{
            .p = vec.add(self.c, radial),
            .d1 = vec.add(vec.scale(self.x, -self.r * s), vec.scale(self.y, self.r * c)),
            .d2 = vec.neg(radial),
        };
    }

    /// The angle of the point nearest `p`, in `[0, 2π)`; 0 for a point on the axis, where
    /// every angle is as near.
    pub fn project(self: Circle, p: Vec3) f64 {
        const d = vec.sub(p, self.c);
        return types.angleOf(vec.dot(d, self.x), vec.dot(d, self.y));
    }

    /// The box of the arc from `t0` to `t1` (`t0 < t1`, up to one turn): its ends and
    /// every extreme of an axis inside it.
    pub fn bounds(self: Circle, t0: f64, t1: f64) Box3 {
        var box = Box3.ofPoint(self.eval(t0));
        box.grow(self.eval(t1));
        for (0..3) |axis| {
            // The axis's component r(cos t·x[k] + sin t·y[k]) is extreme at atan2(y[k], x[k]) + nπ
            const base = trig.atan2(self.y[axis], self.x[axis]);
            var candidate = base - TWO_PI * 2.0;
            while (candidate <= t1) : (candidate += std.math.pi) {
                if (candidate >= t0) box.grow(self.eval(candidate));
            }
        }
        return box;
    }
};

/// `c + a cos θ·x + b sin θ·y`, periodic, `x`, `y` unit and orthogonal, `a` along `x`.
pub const Ellipse = struct {
    c: Vec3,
    x: Vec3,
    y: Vec3,
    a: f64,
    b: f64,

    pub fn normal(self: Ellipse) Vec3 {
        return vec.cross(self.x, self.y);
    }

    pub fn domain(_: Ellipse) Domain {
        return .{ .t0 = 0, .t1 = TWO_PI, .periodic = true };
    }

    pub fn eval(self: Ellipse, t: f64) Vec3 {
        return vec.add(self.c, vec.add(vec.scale(self.x, self.a * @cos(t)), vec.scale(self.y, self.b * @sin(t))));
    }

    pub fn sample(self: Ellipse, t: f64) Sample {
        const c = @cos(t);
        const s = @sin(t);
        return .{
            .p = vec.add(self.c, vec.add(vec.scale(self.x, self.a * c), vec.scale(self.y, self.b * s))),
            .d1 = vec.add(vec.scale(self.x, -self.a * s), vec.scale(self.y, self.b * c)),
            .d2 = vec.add(vec.scale(self.x, -self.a * c), vec.scale(self.y, -self.b * s)),
        };
    }

    /// The parameter of the point of the ellipse nearest `p` (of the ellipse's plane, or
    /// over it: the nearest to its foot). Not Newton's from a seed, which stops where the
    /// tangent is square to the way to `p`, as at the farthest point or the nearer end of
    /// the major axis seen from inside: the point 1.25 along the major axis of an ellipse
    /// 2 by 1 got that end, 0.75 away, where the nearest is 0.69 (the audit of 2026-11-22,
    /// kind 7, site 8). Eberly's method ("Distance from a point to an ellipse, an
    /// ellipsoid, or a hyperellipsoid"; OCCT's `Extrema_ExtPElC` finds every extremum by
    /// its trigonometric roots): in the quadrant of `p`, the nearest point is
    /// `(a²u/(s + a²), b²v/(s + b²))` for the one root `s` of a function monotone on its
    /// bracket, found by halving it to the last bit; on an axis, closed form.
    pub fn project(self: Ellipse, p: Vec3) f64 {
        const d = vec.sub(p, self.c);
        const u = vec.dot(d, self.x);
        const v = vec.dot(d, self.y);
        // In the frame whose first axis is the major one
        const swap = self.b > self.a;
        const e0 = if (swap) self.b else self.a;
        const e1 = if (swap) self.a else self.b;
        const y0 = @abs(if (swap) v else u);
        const y1 = @abs(if (swap) u else v);
        var x0: f64 = undefined;
        var x1: f64 = undefined;
        if (y1 > 0) {
            if (y0 > 0) {
                const z0 = y0 / e0;
                const z1 = y1 / e1;
                const g = z0 * z0 + z1 * z1 - 1;
                if (g != 0) {
                    const r0 = (e0 / e1) * (e0 / e1);
                    const s = nearestRoot(r0, z0, z1, g);
                    x0 = r0 * y0 / (s + r0);
                    x1 = y1 / (s + 1);
                } else {
                    x0 = y0;
                    x1 = y1;
                }
            } else {
                x0 = 0;
                x1 = e1;
            }
        } else {
            const numerator = e0 * y0;
            const denominator = e0 * e0 - e1 * e1;
            if (numerator < denominator) {
                const share = numerator / denominator;
                x0 = e0 * share;
                x1 = e1 * @sqrt(@max(1 - share * share, 0));
            } else {
                x0 = e0;
                x1 = 0;
            }
        }
        // Back to the ellipse's own axes and the quadrant of `p`
        const along_x = std.math.copysign(if (swap) x1 else x0, u);
        const along_y = std.math.copysign(if (swap) x0 else x1, v);
        return types.angleOf(along_x / self.a, along_y / self.b);
    }

    /// The root of `(r0·z0/(s + r0))² + (z1/(s + 1))² − 1` (Eberly's `GetRoot`), `g` its
    /// value at 0: the function falls on the bracket, so halving it finds the root.
    fn nearestRoot(r0: f64, z0: f64, z1: f64, g: f64) f64 {
        const n0 = r0 * z0;
        var s0 = z1 - 1;
        var s1: f64 = if (g < 0) 0 else std.math.hypot(n0, z1) - 1;
        var s: f64 = 0;
        for (0..MAX_BISECTIONS) |_| {
            s = (s0 + s1) / 2;
            if (s == s0 or s == s1) break;
            const ratio0 = n0 / (s + r0);
            const ratio1 = z1 / (s + 1);
            const value = ratio0 * ratio0 + ratio1 * ratio1 - 1;
            if (value > 0) s0 = s else if (value < 0) s1 = s else break;
        }
        return s;
    }

    pub fn bounds(self: Ellipse, t0: f64, t1: f64) Box3 {
        var box = Box3.ofPoint(self.eval(t0));
        box.grow(self.eval(t1));
        for (0..3) |axis| {
            // a cos t·x[k] + b sin t·y[k] is extreme at atan2(b·y[k], a·x[k]) + nπ
            const base = trig.atan2(self.b * self.y[axis], self.a * self.x[axis]);
            var candidate = base - TWO_PI * 2.0;
            while (candidate <= t1) : (candidate += std.math.pi) {
                if (candidate >= t0) box.grow(self.eval(candidate));
            }
        }
        return box;
    }
};

/// A curve of any kind, as a view: analytic kinds by value, a NURBS as slices into the
/// arena's pools (valid until the arena changes).
pub const Curve = union(types.CurveKind) {
    line: Line,
    circle: Circle,
    ellipse: Ellipse,
    nurbs: nurbs.Curve,

    pub fn domain(self: Curve) Domain {
        return switch (self) {
            .line => |c| c.domain(),
            .circle => |c| c.domain(),
            .ellipse => |c| c.domain(),
            .nurbs => |c| c.domain(),
        };
    }

    pub fn eval(self: Curve, t: f64) Vec3 {
        return switch (self) {
            .line => |c| c.eval(t),
            .circle => |c| c.eval(t),
            .ellipse => |c| c.eval(t),
            .nurbs => |c| c.eval(t),
        };
    }

    /// The point and its first two derivatives.
    pub fn sample(self: Curve, t: f64) Sample {
        return switch (self) {
            .line => |c| c.sample(t),
            .circle => |c| c.sample(t),
            .ellipse => |c| c.sample(t),
            .nurbs => |c| c.sample(t),
        };
    }

    pub fn d1(self: Curve, t: f64) Vec3 {
        return self.sample(t).d1;
    }

    pub fn d2(self: Curve, t: f64) Vec3 {
        return self.sample(t).d2;
    }

    /// The parameter of the point nearest `p`: closed form for lines and circles, Newton
    /// from a seed (`max_steps` at most, `eps` the point tolerance) for the rest. The
    /// result lies in the domain.
    pub fn project(self: Curve, p: Vec3, eps: f64, max_steps: u32) f64 {
        return switch (self) {
            .line => |c| c.project(p),
            .circle => |c| c.project(p),
            .ellipse => |c| c.project(p),
            .nurbs => |c| c.project(p, eps, max_steps),
        };
    }

    /// A box around the curve between `t0` and `t1` (`t0 < t1`, within the domain).
    pub fn bounds(self: Curve, t0: f64, t1: f64) Box3 {
        return switch (self) {
            .line => |c| c.bounds(t0, t1),
            .circle => |c| c.bounds(t0, t1),
            .ellipse => |c| c.bounds(t0, t1),
            .nurbs => |c| c.bounds(t0, t1),
        };
    }

    pub fn isPeriodic(self: Curve) bool {
        return self.domain().periodic;
    }

    /// The piece over `[t0, t1]` as a NURBS (exact: a line is degree 1, a circle or ellipse
    /// arc a rational quadratic by A7.1, a NURBS its own segment), for STEP's fallback and
    /// for parity tests. The NURBS form's parameter runs over `[t0, t1]` but is the curve's
    /// own only at the pieces' ends and middles of an arc.
    pub fn toNurbs(self: Curve, allocator: std.mem.Allocator, t0: f64, t1: f64) nurbs.Error!nurbs.CurveData {
        return switch (self) {
            .line => |c| nurbs.lineSegment(allocator, c.eval(t0), c.eval(t1), t0, t1),
            .circle => |c| nurbs.circleArc(allocator, c.c, c.x, c.y, c.r, t0, t1),
            .ellipse => |c| nurbs.ellipseArc(allocator, c.c, c.x, c.y, c.a, c.b, t0, t1),
            .nurbs => |c| blk: {
                var whole = try c.toOwned(allocator);
                defer whole.deinit(allocator);
                break :blk whole.segment(allocator, t0, t1);
            },
        };
    }

    /// A point of the curve, finite for every kind (a line's origin; the start of the
    /// others' domains): a reference where the domain's start would be ±inf.
    pub fn anyPoint(self: Curve) Vec3 {
        return switch (self) {
            .line => |c| c.o,
            else => self.eval(self.domain().t0),
        };
    }
};
