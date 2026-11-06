//! The surface kinds and their parametric contract (docs/architecture.md §5.1, STEP Part
//! 42's parameterizations): `domainU/V`, `eval`, `sample` (first and second derivatives),
//! `normal` (closed form per kind, so poles and apices have one), `project` (closed form
//! for the analytic kinds, Newton from a seed for the swept and NURBS kinds), `bounds` over
//! a UV box, and `toNurbs`. `Surface` dispatches over the kinds with one `switch` per
//! function. Every analytic surface sits in a `Frame`: its origin, `x` reference direction
//! and `z` axis.

const std = @import("std");
const vec = @import("../math/vec.zig");
const types = @import("types.zig");
const curves = @import("curves.zig");
const nurbs = @import("nurbs.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;
const Domain = types.Domain;
const Frame = types.Frame;
const Box2 = types.Box2;
const Box3 = types.Box3;
const Curve = curves.Curve;
const Circle = curves.Circle;
const TWO_PI = types.TWO_PI;
const HALF_PI: f64 = std.math.pi / 2.0;
/// How far along the generator a degenerate point's normal is taken from, as a fraction of
/// its domain.
const NORMAL_NUDGE: f64 = 1e-6;

/// A sample of a surface: the point and its derivatives to second order.
pub const Sample = struct { p: Vec3, du: Vec3, dv: Vec3, duu: Vec3, duv: Vec3, dvv: Vec3 };

const periodic_turn: Domain = .{ .t0 = 0, .t1 = TWO_PI, .periodic = true };

/// `o + u·x + v·y`; normal `z`.
pub const Plane = struct {
    frame: Frame,

    pub fn domainU(_: Plane) Domain {
        return Domain.unbounded;
    }
    pub fn domainV(_: Plane) Domain {
        return Domain.unbounded;
    }

    pub fn eval(self: Plane, u: f64, v: f64) Vec3 {
        return self.frame.toWorld(.{ u, v, 0 });
    }

    pub fn sample(self: Plane, u: f64, v: f64) Sample {
        return .{ .p = self.eval(u, v), .du = self.frame.x, .dv = self.frame.y, .duu = vec.ZERO3, .duv = vec.ZERO3, .dvv = vec.ZERO3 };
    }

    pub fn normal(self: Plane, _: f64, _: f64) Vec3 {
        return vec.scale(self.frame.z, self.frame.sign());
    }

    pub fn project(self: Plane, p: Vec3) Vec2 {
        const l = self.frame.toLocal(p);
        return .{ l[0], l[1] };
    }

    /// The signed distance of `p` above the plane.
    pub fn height(self: Plane, p: Vec3) f64 {
        return vec.dot(vec.sub(p, self.frame.origin), self.frame.z);
    }

    pub fn bounds(self: Plane, box: Box2) Box3 {
        var out = Box3.ofPoint(self.eval(box.min[0], box.min[1]));
        out.grow(self.eval(box.max[0], box.min[1]));
        out.grow(self.eval(box.min[0], box.max[1]));
        out.grow(self.eval(box.max[0], box.max[1]));
        return out;
    }
};

/// `o + r(cos u·x + sin u·y) + v·z`, `u` periodic; normal outward.
pub const Cylinder = struct {
    frame: Frame,
    r: f64,

    pub fn domainU(_: Cylinder) Domain {
        return periodic_turn;
    }
    pub fn domainV(_: Cylinder) Domain {
        return Domain.unbounded;
    }

    pub fn eval(self: Cylinder, u: f64, v: f64) Vec3 {
        return self.frame.toWorld(.{ self.r * @cos(u), self.r * @sin(u), v });
    }

    pub fn sample(self: Cylinder, u: f64, v: f64) Sample {
        const c = @cos(u);
        const s = @sin(u);
        const radial = self.frame.toWorldDir(.{ c, s, 0 });
        return .{
            .p = self.eval(u, v),
            .du = self.frame.toWorldDir(.{ -self.r * s, self.r * c, 0 }),
            .dv = self.frame.z,
            .duu = vec.scale(radial, -self.r),
            .duv = vec.ZERO3,
            .dvv = vec.ZERO3,
        };
    }

    pub fn normal(self: Cylinder, u: f64, _: f64) Vec3 {
        return vec.scale(self.frame.toWorldDir(.{ @cos(u), @sin(u), 0 }), self.frame.sign());
    }

    pub fn project(self: Cylinder, p: Vec3) Vec2 {
        const l = self.frame.toLocal(p);
        return .{ types.angleOf(l[0], l[1]), l[2] };
    }

    /// The circle at height `v`.
    pub fn circleAt(self: Cylinder, v: f64) Circle {
        return .{ .c = vec.addScaled(self.frame.origin, self.frame.z, v), .x = self.frame.x, .y = self.frame.y, .r = self.r };
    }

    pub fn bounds(self: Cylinder, box: Box2) Box3 {
        return Box3.merge(self.circleAt(box.min[1]).bounds(box.min[0], box.max[0]), self.circleAt(box.max[1]).bounds(box.min[0], box.max[0]));
    }
};

/// `o + (r + v sin α)(cos u·x + sin u·y) + v cos α·z`: radius `r` at `v = 0`, half-angle
/// `α` in `(0, π/2)`, the apex at `v = −r / sin α`; normal outward.
pub const Cone = struct {
    frame: Frame,
    r: f64,
    half_angle: f64,

    pub fn domainU(_: Cone) Domain {
        return periodic_turn;
    }
    pub fn domainV(_: Cone) Domain {
        return Domain.unbounded;
    }

    pub fn radiusAt(self: Cone, v: f64) f64 {
        return self.r + v * @sin(self.half_angle);
    }

    pub fn apexV(self: Cone) f64 {
        return -self.r / @sin(self.half_angle);
    }

    pub fn eval(self: Cone, u: f64, v: f64) Vec3 {
        const rad = self.radiusAt(v);
        return self.frame.toWorld(.{ rad * @cos(u), rad * @sin(u), v * @cos(self.half_angle) });
    }

    pub fn sample(self: Cone, u: f64, v: f64) Sample {
        const c = @cos(u);
        const s = @sin(u);
        const sa = @sin(self.half_angle);
        const ca = @cos(self.half_angle);
        const rad = self.radiusAt(v);
        return .{
            .p = self.eval(u, v),
            .du = self.frame.toWorldDir(.{ -rad * s, rad * c, 0 }),
            .dv = self.frame.toWorldDir(.{ sa * c, sa * s, ca }),
            .duu = self.frame.toWorldDir(.{ -rad * c, -rad * s, 0 }),
            .duv = self.frame.toWorldDir(.{ -sa * s, sa * c, 0 }),
            .dvv = vec.ZERO3,
        };
    }

    pub fn normal(self: Cone, u: f64, _: f64) Vec3 {
        const sa = @sin(self.half_angle);
        const ca = @cos(self.half_angle);
        return vec.scale(self.frame.toWorldDir(.{ ca * @cos(u), ca * @sin(u), -sa }), self.frame.sign());
    }

    /// The nearest point's parameters: the angle about the axis, and the position along the
    /// generator line in the meridian plane.
    pub fn project(self: Cone, p: Vec3) Vec2 {
        const l = self.frame.toLocal(p);
        const rho = @sqrt(l[0] * l[0] + l[1] * l[1]);
        const v = (rho - self.r) * @sin(self.half_angle) + l[2] * @cos(self.half_angle);
        return .{ types.angleOf(l[0], l[1]), v };
    }

    pub fn circleAt(self: Cone, v: f64) Circle {
        return .{ .c = vec.addScaled(self.frame.origin, self.frame.z, v * @cos(self.half_angle)), .x = self.frame.x, .y = self.frame.y, .r = self.radiusAt(v) };
    }

    pub fn bounds(self: Cone, box: Box2) Box3 {
        return Box3.merge(self.circleAt(box.min[1]).bounds(box.min[0], box.max[0]), self.circleAt(box.max[1]).bounds(box.min[0], box.max[0]));
    }
};

/// `c + r(cos v cos u·x + cos v sin u·y + sin v·z)`, `u` periodic, `v ∈ [−π/2, π/2]` with
/// the poles at its ends; normal outward.
pub const Sphere = struct {
    frame: Frame,
    r: f64,

    pub fn domainU(_: Sphere) Domain {
        return periodic_turn;
    }
    pub fn domainV(_: Sphere) Domain {
        return .{ .t0 = -HALF_PI, .t1 = HALF_PI };
    }

    pub fn eval(self: Sphere, u: f64, v: f64) Vec3 {
        const cv = @cos(v);
        return self.frame.toWorld(.{ self.r * cv * @cos(u), self.r * cv * @sin(u), self.r * @sin(v) });
    }

    pub fn sample(self: Sphere, u: f64, v: f64) Sample {
        const cu = @cos(u);
        const su = @sin(u);
        const cv = @cos(v);
        const sv = @sin(v);
        const r = self.r;
        return .{
            .p = self.eval(u, v),
            .du = self.frame.toWorldDir(.{ -r * cv * su, r * cv * cu, 0 }),
            .dv = self.frame.toWorldDir(.{ -r * sv * cu, -r * sv * su, r * cv }),
            .duu = self.frame.toWorldDir(.{ -r * cv * cu, -r * cv * su, 0 }),
            .duv = self.frame.toWorldDir(.{ r * sv * su, -r * sv * cu, 0 }),
            .dvv = self.frame.toWorldDir(.{ -r * cv * cu, -r * cv * su, -r * sv }),
        };
    }

    pub fn normal(self: Sphere, u: f64, v: f64) Vec3 {
        const cv = @cos(v);
        return vec.scale(self.frame.toWorldDir(.{ cv * @cos(u), cv * @sin(u), @sin(v) }), self.frame.sign());
    }

    pub fn project(self: Sphere, p: Vec3) Vec2 {
        const l = self.frame.toLocal(p);
        const rho = @sqrt(l[0] * l[0] + l[1] * l[1]);
        return .{ types.angleOf(l[0], l[1]), std.math.atan2(l[2], rho) };
    }

    /// The meridian at angle `u`: a circle through both poles, parameterized by `v`.
    pub fn meridian(self: Sphere, u: f64) Circle {
        return .{ .c = self.frame.origin, .x = self.frame.toWorldDir(.{ @cos(u), @sin(u), 0 }), .y = self.frame.z, .r = self.r };
    }

    /// The parallel at latitude `v`, parameterized by `u`.
    pub fn parallel(self: Sphere, v: f64) Circle {
        return .{ .c = vec.addScaled(self.frame.origin, self.frame.z, self.r * @sin(v)), .x = self.frame.x, .y = self.frame.y, .r = self.r * @cos(v) };
    }

    pub fn bounds(self: Sphere, box: Box2) Box3 {
        var out = Box3.merge(self.meridian(box.min[0]).bounds(box.min[1], box.max[1]), self.meridian(box.max[0]).bounds(box.min[1], box.max[1]));
        out = Box3.merge(out, self.parallel(box.min[1]).bounds(box.min[0], box.max[0]));
        out = Box3.merge(out, self.parallel(box.max[1]).bounds(box.min[0], box.max[0]));
        // The extremes of each world axis over the whole sphere, when inside the patch
        for ([_]Vec3{ vec.X3, vec.Y3, vec.Z3 }) |axis| {
            for ([_]f64{ 1, -1 }) |sign| {
                const d = self.frame.toLocalDir(vec.scale(axis, sign));
                const uv = Vec2{ types.angleOf(d[0], d[1]), std.math.atan2(d[2], @sqrt(d[0] * d[0] + d[1] * d[1])) };
                if (box.contains(uv)) out.grow(self.eval(uv[0], uv[1]));
            }
        }
        return out;
    }
};

/// `c + (R + r cos v)(cos u·x + sin u·y) + r sin v·z`, both periodic; normal outward.
pub const Torus = struct {
    frame: Frame,
    major: f64,
    minor: f64,

    pub fn domainU(_: Torus) Domain {
        return periodic_turn;
    }
    pub fn domainV(_: Torus) Domain {
        return periodic_turn;
    }

    pub fn eval(self: Torus, u: f64, v: f64) Vec3 {
        const rad = self.major + self.minor * @cos(v);
        return self.frame.toWorld(.{ rad * @cos(u), rad * @sin(u), self.minor * @sin(v) });
    }

    pub fn sample(self: Torus, u: f64, v: f64) Sample {
        const cu = @cos(u);
        const su = @sin(u);
        const cv = @cos(v);
        const sv = @sin(v);
        const r = self.minor;
        const rad = self.major + r * cv;
        return .{
            .p = self.eval(u, v),
            .du = self.frame.toWorldDir(.{ -rad * su, rad * cu, 0 }),
            .dv = self.frame.toWorldDir(.{ -r * sv * cu, -r * sv * su, r * cv }),
            .duu = self.frame.toWorldDir(.{ -rad * cu, -rad * su, 0 }),
            .duv = self.frame.toWorldDir(.{ r * sv * su, -r * sv * cu, 0 }),
            .dvv = self.frame.toWorldDir(.{ -r * cv * cu, -r * cv * su, -r * sv }),
        };
    }

    pub fn normal(self: Torus, u: f64, v: f64) Vec3 {
        const cv = @cos(v);
        return vec.scale(self.frame.toWorldDir(.{ cv * @cos(u), cv * @sin(u), @sin(v) }), self.frame.sign());
    }

    pub fn project(self: Torus, p: Vec3) Vec2 {
        const l = self.frame.toLocal(p);
        const rho = @sqrt(l[0] * l[0] + l[1] * l[1]);
        return .{ types.angleOf(l[0], l[1]), types.angleOf(rho - self.major, l[2]) };
    }

    /// The tube's circle at angle `u`, parameterized by `v`.
    pub fn tube(self: Torus, u: f64) Circle {
        const radial = self.frame.toWorldDir(.{ @cos(u), @sin(u), 0 });
        return .{ .c = vec.addScaled(self.frame.origin, radial, self.major), .x = radial, .y = self.frame.z, .r = self.minor };
    }

    /// The ring at tube angle `v`, parameterized by `u`.
    pub fn ring(self: Torus, v: f64) Circle {
        return .{ .c = vec.addScaled(self.frame.origin, self.frame.z, self.minor * @sin(v)), .x = self.frame.x, .y = self.frame.y, .r = self.major + self.minor * @cos(v) };
    }

    pub fn bounds(self: Torus, box: Box2) Box3 {
        var out = Box3.merge(self.tube(box.min[0]).bounds(box.min[1], box.max[1]), self.tube(box.max[0]).bounds(box.min[1], box.max[1]));
        out = Box3.merge(out, self.ring(box.min[1]).bounds(box.min[0], box.max[0]));
        out = Box3.merge(out, self.ring(box.max[1]).bounds(box.min[0], box.max[0]));
        // The interior extremes of each world axis: where the normal is along it
        for ([_]Vec3{ vec.X3, vec.Y3, vec.Z3 }) |axis| {
            for ([_]f64{ 1, -1 }) |sign| {
                const d = self.frame.toLocalDir(vec.scale(axis, sign));
                const u = types.angleOf(d[0], d[1]);
                const rho = d[0] * @cos(u) + d[1] * @sin(u);
                const v = types.angleOf(rho, d[2]);
                if (box.contains(.{ u, v })) out.grow(self.eval(u, v));
            }
        }
        return out;
    }
};

/// `C(u) + v·d`: the generator curve swept along the unit direction `d`.
pub const Extrusion = struct {
    curve: Curve,
    d: Vec3,

    pub fn domainU(self: Extrusion) Domain {
        return self.curve.domain();
    }
    pub fn domainV(_: Extrusion) Domain {
        return Domain.unbounded;
    }

    pub fn eval(self: Extrusion, u: f64, v: f64) Vec3 {
        return vec.addScaled(self.curve.eval(u), self.d, v);
    }

    pub fn sample(self: Extrusion, u: f64, v: f64) Sample {
        const c = self.curve.sample(u);
        return .{ .p = vec.addScaled(c.p, self.d, v), .du = c.d1, .dv = self.d, .duu = c.d2, .duv = vec.ZERO3, .dvv = vec.ZERO3 };
    }

    pub fn normal(self: Extrusion, u: f64, _: f64) Vec3 {
        return vec.normalized(vec.cross(self.curve.d1(u), self.d)) orelse vec.ZERO3;
    }

    /// Seed and refine: `u` from the curve's nearest point to `p` moved into the
    /// generator's plane along `d`, `v` the height there.
    pub fn project(self: Extrusion, p: Vec3, eps: f64, max_steps: u32) Vec2 {
        const base = self.curve.anyPoint();
        const height0 = vec.dot(vec.sub(p, base), self.d);
        const along = self.curve.project(vec.addScaled(p, self.d, -height0), eps, max_steps);
        const height = vec.dot(vec.sub(p, self.curve.eval(along)), self.d);
        return nurbs.refineSurfaceProjection(self, p, .{ along, height }, eps, max_steps);
    }

    pub fn bounds(self: Extrusion, box: Box2) Box3 {
        var sweep = Box3.ofPoint(vec.scale(self.d, box.min[1]));
        sweep.grow(vec.scale(self.d, box.max[1]));
        return Box3.sum(self.curve.bounds(box.min[0], box.max[0]), sweep);
    }
};

/// `rotate(C(v), axis, u)`: the generator turned about the axis through `origin` along
/// unit `axis` by `u`, counter-clockwise seen from the axis's tip; `u` periodic.
pub const Revolution = struct {
    curve: Curve,
    frame: Frame,

    pub fn init(curve: Curve, origin: Vec3, axis: Vec3) Revolution {
        return .{ .curve = curve, .frame = Frame.fromAxis(origin, axis) };
    }

    pub fn domainU(_: Revolution) Domain {
        return periodic_turn;
    }
    pub fn domainV(self: Revolution) Domain {
        return self.curve.domain();
    }

    fn turn(self: Revolution, l: Vec3, u: f64) Vec3 {
        const c = @cos(u);
        const s = @sin(u);
        return self.frame.toWorldDir(.{ l[0] * c - l[1] * s, l[0] * s + l[1] * c, l[2] });
    }

    fn turnDerivative(self: Revolution, l: Vec3, u: f64) Vec3 {
        const c = @cos(u);
        const s = @sin(u);
        return self.frame.toWorldDir(.{ -l[0] * s - l[1] * c, l[0] * c - l[1] * s, 0 });
    }

    pub fn eval(self: Revolution, u: f64, v: f64) Vec3 {
        const l = self.frame.toLocal(self.curve.eval(v));
        return vec.add(self.frame.origin, self.turn(l, u));
    }

    pub fn sample(self: Revolution, u: f64, v: f64) Sample {
        const c = self.curve.sample(v);
        const l = self.frame.toLocal(c.p);
        const l1 = self.frame.toLocalDir(c.d1);
        const l2 = self.frame.toLocalDir(c.d2);
        return .{
            .p = vec.add(self.frame.origin, self.turn(l, u)),
            .du = self.turnDerivative(l, u),
            .dv = self.turn(l1, u),
            .duu = self.turn(.{ -l[0], -l[1], 0 }, u),
            .duv = self.turnDerivative(l1, u),
            .dvv = self.turn(l2, u),
        };
    }

    /// `du × dv`, unit; on the axis (a degenerate point) the limit from a little way along
    /// the generator.
    pub fn normal(self: Revolution, u: f64, v: f64) Vec3 {
        const s = self.sample(u, v);
        if (vec.normalized(vec.cross(s.du, s.dv))) |n| return n;
        const dom = self.curve.domain();
        const step = dom.span() * NORMAL_NUDGE;
        const nudged = if (v + step <= dom.t1) v + step else v - step;
        const t = self.sample(u, nudged);
        return vec.normalized(vec.cross(t.du, t.dv)) orelse vec.ZERO3;
    }

    /// Seed and refine: `u` the angle of `p` about the axis, `v` the generator's nearest
    /// point to `p` turned back into the generator's half-plane.
    pub fn project(self: Revolution, p: Vec3, eps: f64, max_steps: u32) Vec2 {
        const l = self.frame.toLocal(p);
        const angle = types.angleOf(l[0], l[1]);
        const rho = @sqrt(l[0] * l[0] + l[1] * l[1]);
        // The generator's own angle about the axis (its points are not all at angle 0)
        const g = self.frame.toLocal(self.curve.anyPoint());
        const phase = types.angleOf(g[0], g[1]);
        const back = vec.add(self.frame.origin, self.frame.toWorldDir(.{ rho * @cos(phase), rho * @sin(phase), l[2] }));
        const v0 = self.curve.project(back, eps, max_steps);
        const u_seed = types.angleOf(@cos(angle - phase), @sin(angle - phase));
        return nurbs.refineSurfaceProjection(self, p, .{ u_seed, v0 }, eps, max_steps);
    }

    /// The generator's box over the `v` range, each corner swept over the `u` range.
    pub fn bounds(self: Revolution, box: Box2) Box3 {
        const gen = self.curve.bounds(box.min[1], box.max[1]);
        var out = Box3.empty;
        for ([_]f64{ gen.min[0], gen.max[0] }) |x| {
            for ([_]f64{ gen.min[1], gen.max[1] }) |y| {
                for ([_]f64{ gen.min[2], gen.max[2] }) |z| {
                    const l = self.frame.toLocal(.{ x, y, z });
                    const rho = @sqrt(l[0] * l[0] + l[1] * l[1]);
                    const phase = types.angleOf(l[0], l[1]);
                    const circle = Circle{ .c = vec.addScaled(self.frame.origin, self.frame.z, l[2]), .x = self.frame.x, .y = self.frame.y, .r = rho };
                    out = Box3.merge(out, circle.bounds(box.min[0] + phase, box.max[0] + phase));
                }
            }
        }
        return out;
    }
};

/// A surface of any kind, as a view.
pub const Surface = union(types.SurfaceKind) {
    plane: Plane,
    cylinder: Cylinder,
    cone: Cone,
    sphere: Sphere,
    torus: Torus,
    extrusion: Extrusion,
    revolution: Revolution,
    nurbs: nurbs.Surface,

    pub fn domainU(self: Surface) Domain {
        return switch (self) {
            inline else => |s| s.domainU(),
        };
    }

    pub fn domainV(self: Surface) Domain {
        return switch (self) {
            inline else => |s| s.domainV(),
        };
    }

    pub fn eval(self: Surface, u: f64, v: f64) Vec3 {
        return switch (self) {
            inline else => |s| s.eval(u, v),
        };
    }

    /// The point and its derivatives to second order.
    pub fn sample(self: Surface, u: f64, v: f64) Sample {
        return switch (self) {
            .nurbs => |s| blk: {
                const r = s.sample(u, v);
                break :blk .{ .p = r.p, .du = r.du, .dv = r.dv, .duu = r.duu, .duv = r.duv, .dvv = r.dvv };
            },
            inline else => |s| s.sample(u, v),
        };
    }

    /// The unit normal of the surface (before any face's `same_sense`): `du × dv` made unit,
    /// which is outward for the closed analytic kinds in a right-handed frame and inward
    /// in a left-handed one (a mirrored body's faces flip `same_sense` to stay outward).
    pub fn normal(self: Surface, u: f64, v: f64) Vec3 {
        return switch (self) {
            .nurbs => |s| blk: {
                const r = s.sample(u, v);
                break :blk vec.normalized(vec.cross(r.du, r.dv)) orelse vec.ZERO3;
            },
            inline else => |s| s.normal(u, v),
        };
    }

    /// The parameters of the point nearest `p`, in the domain: closed form for the analytic
    /// kinds; Newton from a seed for the swept and NURBS kinds, `eps` the point tolerance
    /// and `max_steps` its bound.
    pub fn project(self: Surface, p: Vec3, eps: f64, max_steps: u32) Vec2 {
        return switch (self) {
            .plane => |s| s.project(p),
            .cylinder => |s| s.project(p),
            .cone => |s| s.project(p),
            .sphere => |s| s.project(p),
            .torus => |s| s.project(p),
            .extrusion => |s| s.project(p, eps, max_steps),
            .revolution => |s| s.project(p, eps, max_steps),
            .nurbs => |s| s.project(p, eps, max_steps),
        };
    }

    /// A box around the patch over the UV box (inside both domains, no wrap).
    pub fn bounds(self: Surface, box: Box2) Box3 {
        return switch (self) {
            inline else => |s| s.bounds(box),
        };
    }

    /// The patch over `box` as a NURBS (exact: a plane is bilinear, a cylinder or cone is
    /// ruled between two circle arcs, a sphere or torus the revolution of an arc, the swept
    /// kinds their generator's NURBS swept, a NURBS its own segment), for STEP's fallback
    /// and for parity tests. The parameters run over the box; an arc's is the angle at its
    /// pieces' ends and middles only.
    pub fn toNurbs(self: Surface, allocator: std.mem.Allocator, box: Box2) nurbs.Error!nurbs.SurfaceData {
        const u_lo = box.min[0];
        const u_hi = box.max[0];
        const v_lo = box.min[1];
        const v_hi = box.max[1];
        switch (self) {
            .plane => |s| return nurbs.bilinear(allocator, s.eval(u_lo, v_lo), s.eval(u_hi, v_lo), s.eval(u_lo, v_hi), s.eval(u_hi, v_hi), .{ u_lo, u_hi }, .{ v_lo, v_hi }),
            .cylinder, .cone => {
                var bottom = try (Curve{ .circle = if (self == .cylinder) self.cylinder.circleAt(v_lo) else self.cone.circleAt(v_lo) }).toNurbs(allocator, u_lo, u_hi);
                defer bottom.deinit(allocator);
                var top = try (Curve{ .circle = if (self == .cylinder) self.cylinder.circleAt(v_hi) else self.cone.circleAt(v_hi) }).toNurbs(allocator, u_lo, u_hi);
                defer top.deinit(allocator);
                return nurbs.ruled(allocator, bottom.view(), top.view(), v_lo, v_hi);
            },
            .sphere => |s| {
                var meridian = try (Curve{ .circle = s.meridian(0) }).toNurbs(allocator, v_lo, v_hi);
                defer meridian.deinit(allocator);
                return nurbs.revolution(allocator, meridian.view(), s.frame.origin, s.frame.z, u_lo, u_hi);
            },
            .torus => |s| {
                var tube = try (Curve{ .circle = s.tube(0) }).toNurbs(allocator, v_lo, v_hi);
                defer tube.deinit(allocator);
                return nurbs.revolution(allocator, tube.view(), s.frame.origin, s.frame.z, u_lo, u_hi);
            },
            .extrusion => |s| {
                var generator = try s.curve.toNurbs(allocator, u_lo, u_hi);
                defer generator.deinit(allocator);
                return nurbs.extrusion(allocator, generator.view(), s.d, v_lo, v_hi);
            },
            .revolution => |s| {
                var generator = try s.curve.toNurbs(allocator, v_lo, v_hi);
                defer generator.deinit(allocator);
                return nurbs.revolution(allocator, generator.view(), s.frame.origin, s.frame.z, u_lo, u_hi);
            },
            .nurbs => |s| {
                var whole = try s.toOwned(allocator);
                defer whole.deinit(allocator);
                return whole.segment(allocator, box);
            },
        }
    }

    pub fn isPeriodicU(self: Surface) bool {
        return self.domainU().periodic;
    }

    pub fn isPeriodicV(self: Surface) bool {
        return self.domainV().periodic;
    }
};
