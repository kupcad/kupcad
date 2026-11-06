//! Pcurves: a coedge's curve in its face's UV box (docs/architecture.md §5.1). Exact where
//! a closed form exists (a line on a cylinder is a line in UV; a cap circle a horizontal
//! line), an approximating 2D NURBS within `approx` otherwise, flagged on the edge. The 3D
//! edge curve is the truth; pcurves order and triangulate.

const std = @import("std");
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const nurbs = @import("nurbs.zig");
const Vec2 = vec.Vec2;
const Domain = types.Domain;
const Box2 = types.Box2;

/// A sample of a pcurve: the point and its first derivative.
pub const Sample = nurbs.Sample2;

/// `o + t·d` in UV, `d` unit.
pub const Line2 = struct {
    o: Vec2,
    d: Vec2,

    pub fn through(a: Vec2, b: Vec2) ?Line2 {
        const d = vec.normalized2(vec.sub2(b, a)) orelse return null;
        return .{ .o = a, .d = d };
    }

    pub fn eval(self: Line2, t: f64) Vec2 {
        return vec.add2(self.o, vec.scale2(self.d, t));
    }

    pub fn sample(self: Line2, t: f64) Sample {
        return .{ .p = self.eval(t), .d1 = self.d };
    }

    pub fn project(self: Line2, p: Vec2) f64 {
        return vec.dot2(vec.sub2(p, self.o), self.d);
    }
};

/// `c + r(cos θ, sin θ)` in UV, counter-clockwise, periodic.
pub const Circle2 = struct {
    c: Vec2,
    r: f64,

    pub fn eval(self: Circle2, t: f64) Vec2 {
        return .{ self.c[0] + self.r * @cos(t), self.c[1] + self.r * @sin(t) };
    }

    pub fn sample(self: Circle2, t: f64) Sample {
        return .{ .p = self.eval(t), .d1 = .{ -self.r * @sin(t), self.r * @cos(t) } };
    }

    pub fn project(self: Circle2, p: Vec2) f64 {
        return types.angleOf(p[0] - self.c[0], p[1] - self.c[1]);
    }
};

pub const PCurve = union(types.PCurveKind) {
    line2: Line2,
    circle2: Circle2,
    nurbs2: nurbs.Curve2,

    pub fn domain(self: PCurve) Domain {
        return switch (self) {
            .line2 => Domain.unbounded,
            .circle2 => .{ .t0 = 0, .t1 = types.TWO_PI, .periodic = true },
            .nurbs2 => |c| c.domain(),
        };
    }

    pub fn eval(self: PCurve, t: f64) Vec2 {
        return switch (self) {
            .line2 => |c| c.eval(t),
            .circle2 => |c| c.eval(t),
            .nurbs2 => |c| c.eval(t),
        };
    }

    pub fn sample(self: PCurve, t: f64) Sample {
        return switch (self) {
            .line2 => |c| c.sample(t),
            .circle2 => |c| c.sample(t),
            .nurbs2 => |c| c.sample(t),
        };
    }

    /// The box of the pcurve between `t0` and `t1`: exact for lines and circles, the
    /// control points' for NURBS.
    pub fn bounds(self: PCurve, t0: f64, t1: f64) Box2 {
        switch (self) {
            .line2 => |c| {
                var box = Box2.empty;
                box.grow(c.eval(t0));
                box.grow(c.eval(t1));
                return box;
            },
            .circle2 => |c| {
                var box = Box2.empty;
                box.grow(c.eval(t0));
                box.grow(c.eval(t1));
                // The axes' extremes are at multiples of π/2
                var candidate = -types.TWO_PI * 2.0;
                while (candidate <= t1) : (candidate += std.math.pi / 2.0) {
                    if (candidate >= t0) box.grow(c.eval(candidate));
                }
                return box;
            },
            .nurbs2 => |c| return c.bounds(t0, t1),
        }
    }
};
