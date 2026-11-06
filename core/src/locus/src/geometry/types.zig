//! The kinds of geometry and the references to them: one array per kind in the arena
//! (arena.zig), addressed by a packed `{kind, index}` (docs/architecture.md §3, §5.1), and
//! the small plain types the contract shares (a parameter domain, a box).

const std = @import("std");
const vec = @import("../math/vec.zig");
const trig = @import("../math/trig.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

pub const CurveKind = enum(u8) { line, circle, ellipse, nurbs };
pub const SurfaceKind = enum(u8) { plane, cylinder, cone, sphere, torus, extrusion, revolution, nurbs };
pub const PCurveKind = enum(u8) { line2, circle2, nurbs2 };

/// The most entities of one kind an arena addresses: a 24-bit index.
pub const MAX_PER_KIND: u32 = 1 << 24;

/// A curve of the arena: its kind, and its index in that kind's array.
pub const CurveRef = packed struct(u32) {
    index: u24,
    kind: CurveKind,

    pub fn of(kind: CurveKind, index: usize) CurveRef {
        return .{ .kind = kind, .index = @intCast(index) };
    }

    pub fn eql(a: CurveRef, b: CurveRef) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

pub const SurfaceRef = packed struct(u32) {
    index: u24,
    kind: SurfaceKind,

    pub fn of(kind: SurfaceKind, index: usize) SurfaceRef {
        return .{ .kind = kind, .index = @intCast(index) };
    }

    pub fn eql(a: SurfaceRef, b: SurfaceRef) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

/// A coedge's curve in its face's UV box; `none` on a plane, where it is computed.
pub const PCurveRef = packed struct(u32) {
    index: u24,
    kind: PCurveKind,

    /// No pcurve stored (a coedge of a planar face).
    pub const none: PCurveRef = .{ .index = std.math.maxInt(u24), .kind = .line2 };

    pub fn of(kind: PCurveKind, index: usize) PCurveRef {
        return .{ .kind = kind, .index = @intCast(index) };
    }

    pub fn isNone(self: PCurveRef) bool {
        return @as(u32, @bitCast(self)) == @as(u32, @bitCast(none));
    }
};

/// An interned point of the arena.
pub const PointIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn of(index: usize) PointIndex {
        return @fromBackingInt(@intCast(index));
    }
};

/// A curve's parameter range: `[t0, t1]`; periodic when `t1` wraps to `t0`. A line is
/// unbounded: its range is ±inf and every edge on it gives its own.
pub const Domain = struct {
    t0: f64,
    t1: f64,
    periodic: bool = false,

    pub const unbounded: Domain = .{ .t0 = -std.math.inf(f64), .t1 = std.math.inf(f64) };

    pub fn span(self: Domain) f64 {
        return self.t1 - self.t0;
    }

    pub fn contains(self: Domain, t: f64) bool {
        return t >= self.t0 and t <= self.t1;
    }

    /// `t` moved into the domain: wrapped by whole periods when periodic (bounded: a
    /// parameter is never more than a few periods out), clamped otherwise.
    pub fn fit(self: Domain, t: f64) f64 {
        if (!self.periodic) return std.math.clamp(t, self.t0, self.t1);
        const period = self.span();
        if (!(period > 0.0)) return self.t0;
        var u = t;
        var guard: u8 = 0;
        while (u < self.t0 and guard < 64) : (guard += 1) u += period;
        while (u >= self.t1 and guard < 64) : (guard += 1) u -= period;
        return std.math.clamp(u, self.t0, self.t1);
    }
};

/// An axis-aligned box. `empty` has its min above its max; `grow` and `merge` extend it.
pub const Box3 = struct {
    min: Vec3,
    max: Vec3,

    pub const empty: Box3 = .{
        .min = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) },
        .max = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) },
    };

    pub fn isEmpty(self: Box3) bool {
        return self.min[0] > self.max[0] or self.min[1] > self.max[1] or self.min[2] > self.max[2];
    }

    pub fn ofPoint(p: Vec3) Box3 {
        return .{ .min = p, .max = p };
    }

    pub fn grow(self: *Box3, p: Vec3) void {
        self.min = vec.min(self.min, p);
        self.max = vec.max(self.max, p);
    }

    pub fn merge(a: Box3, b: Box3) Box3 {
        return .{ .min = vec.min(a.min, b.min), .max = vec.max(a.max, b.max) };
    }

    /// The box moved out by `d` on every side.
    pub fn inflated(self: Box3, d: f64) Box3 {
        return .{ .min = vec.sub(self.min, .{ d, d, d }), .max = vec.add(self.max, .{ d, d, d }) };
    }

    pub fn overlaps(a: Box3, b: Box3) bool {
        return a.min[0] <= b.max[0] and b.min[0] <= a.max[0] and
            a.min[1] <= b.max[1] and b.min[1] <= a.max[1] and
            a.min[2] <= b.max[2] and b.min[2] <= a.max[2];
    }

    pub fn contains(self: Box3, p: Vec3) bool {
        return p[0] >= self.min[0] and p[0] <= self.max[0] and
            p[1] >= self.min[1] and p[1] <= self.max[1] and
            p[2] >= self.min[2] and p[2] <= self.max[2];
    }

    pub fn size(self: Box3) Vec3 {
        return vec.sub(self.max, self.min);
    }

    pub fn center(self: Box3) Vec3 {
        return vec.scale(vec.add(self.min, self.max), 0.5);
    }

    /// The longest side.
    pub fn extent(self: Box3) f64 {
        const s = self.size();
        return @max(s[0], @max(s[1], s[2]));
    }

    /// The box of `a` plus `b` for every pair (Minkowski sum).
    pub fn sum(a: Box3, b: Box3) Box3 {
        return .{ .min = vec.add(a.min, b.min), .max = vec.add(a.max, b.max) };
    }
};

pub const Box2 = struct {
    min: Vec2,
    max: Vec2,

    pub const empty: Box2 = .{
        .min = .{ std.math.inf(f64), std.math.inf(f64) },
        .max = .{ -std.math.inf(f64), -std.math.inf(f64) },
    };

    pub fn isEmpty(self: Box2) bool {
        return self.min[0] > self.max[0] or self.min[1] > self.max[1];
    }

    pub fn grow(self: *Box2, p: Vec2) void {
        self.min = .{ @min(self.min[0], p[0]), @min(self.min[1], p[1]) };
        self.max = .{ @max(self.max[0], p[0]), @max(self.max[1], p[1]) };
    }

    pub fn merge(a: Box2, b: Box2) Box2 {
        return .{
            .min = .{ @min(a.min[0], b.min[0]), @min(a.min[1], b.min[1]) },
            .max = .{ @max(a.max[0], b.max[0]), @max(a.max[1], b.max[1]) },
        };
    }

    pub fn contains(self: Box2, p: Vec2) bool {
        return p[0] >= self.min[0] and p[0] <= self.max[0] and p[1] >= self.min[1] and p[1] <= self.max[1];
    }

    pub fn overlaps(a: Box2, b: Box2) bool {
        return a.min[0] <= b.max[0] and b.min[0] <= a.max[0] and a.min[1] <= b.max[1] and b.min[1] <= a.max[1];
    }

    pub fn size(self: Box2) Vec2 {
        return .{ self.max[0] - self.min[0], self.max[1] - self.min[1] };
    }
};

/// An orthonormal frame at `origin`: the placement of every analytic surface (STEP's
/// AXIS2_PLACEMENT_3D: `z` is its axis, `x` its reference direction). Right-handed as
/// built; left-handed after a mirror (transform.zig), which keeps every parameterization
/// exact: the kinds' normals carry `sign`.
pub const Frame = struct {
    origin: Vec3,
    x: Vec3,
    y: Vec3,
    z: Vec3,

    /// The frame with axis `z` and reference direction `x`, both unit and orthogonal.
    pub fn init(origin: Vec3, x: Vec3, z: Vec3) Frame {
        return .{ .origin = origin, .x = x, .y = vec.cross(z, x), .z = z };
    }

    /// The frame with axis `z` (unit) and a reference direction chosen deterministically.
    pub fn fromAxis(origin: Vec3, z: Vec3) Frame {
        return init(origin, vec.perpendicular(z), z);
    }

    /// The world frame at the origin.
    pub const world: Frame = .{ .origin = vec.ZERO3, .x = vec.X3, .y = vec.Y3, .z = vec.Z3 };

    /// +1 for a right-handed frame (`x × y = z`), −1 for a left-handed one.
    pub fn sign(self: Frame) f64 {
        return if (vec.dot(vec.cross(self.x, self.y), self.z) < 0.0) -1.0 else 1.0;
    }

    /// `p` in the frame's coordinates.
    pub fn toLocal(self: Frame, p: Vec3) Vec3 {
        const d = vec.sub(p, self.origin);
        return .{ vec.dot(d, self.x), vec.dot(d, self.y), vec.dot(d, self.z) };
    }

    /// A direction in the frame's coordinates.
    pub fn toLocalDir(self: Frame, d: Vec3) Vec3 {
        return .{ vec.dot(d, self.x), vec.dot(d, self.y), vec.dot(d, self.z) };
    }

    /// The world point of local coordinates `l`.
    pub fn toWorld(self: Frame, l: Vec3) Vec3 {
        return vec.add(self.origin, self.toWorldDir(l));
    }

    pub fn toWorldDir(self: Frame, l: Vec3) Vec3 {
        return vec.add(vec.add(vec.scale(self.x, l[0]), vec.scale(self.y, l[1])), vec.scale(self.z, l[2]));
    }
};

/// The angle of the local direction `(x, y)` in `[0, 2π)`, the way every periodic parameter
/// is wrapped; 0 on the axis.
pub fn angleOf(x: f64, y: f64) f64 {
    if (x == 0.0 and y == 0.0) return 0.0;
    const a = trig.atan2(y, x);
    return if (a < 0.0) a + TWO_PI else a;
}

pub const TWO_PI: f64 = 2.0 * std.math.pi;
