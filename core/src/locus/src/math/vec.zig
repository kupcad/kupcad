//! Vectors in 2 and 3 dimensions as plain arrays of `f64`, and the arithmetic on them.
//! Nothing here compares with a tolerance: that is tolerance.zig's, so that every "close
//! enough" in Locus goes through a body's `Tolerance` (README rule 3). The one exception is
//! `normalized`, which refuses a zero vector rather than divide by zero.

pub const Vec2 = [2]f64;
pub const Vec3 = [3]f64;
/// Homogeneous: `(wx, wy, wz, w)` for rational curves and surfaces.
pub const Vec4 = [4]f64;

pub const ZERO3: Vec3 = .{ 0, 0, 0 };
pub const X3: Vec3 = .{ 1, 0, 0 };
pub const Y3: Vec3 = .{ 0, 1, 0 };
pub const Z3: Vec3 = .{ 0, 0, 1 };

pub inline fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub inline fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

pub inline fn neg(a: Vec3) Vec3 {
    return .{ -a[0], -a[1], -a[2] };
}

pub inline fn scale(a: Vec3, s: f64) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

/// `a + b·s`
pub inline fn addScaled(a: Vec3, b: Vec3, s: f64) Vec3 {
    return .{ a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s };
}

pub inline fn dot(a: Vec3, b: Vec3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub inline fn lengthSq(a: Vec3) f64 {
    return dot(a, a);
}

pub inline fn length(a: Vec3) f64 {
    return @sqrt(lengthSq(a));
}

pub inline fn distanceSq(a: Vec3, b: Vec3) f64 {
    return lengthSq(sub(a, b));
}

pub inline fn distance(a: Vec3, b: Vec3) f64 {
    return @sqrt(distanceSq(a, b));
}

/// `a` at unit length, or null for the zero vector (and for one whose length is not a
/// number).
pub fn normalized(a: Vec3) ?Vec3 {
    const len = length(a);
    if (!(len > 0.0)) return null;
    return scale(a, 1.0 / len);
}

/// `a + (b − a)·t`
pub inline fn lerp(a: Vec3, b: Vec3, t: f64) Vec3 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

/// A unit vector perpendicular to the unit vector `n`, chosen the same way every time: the
/// axis `n` leans on least, made orthogonal to it (a fixed choice keeps every frame built
/// from a direction deterministic, §6).
pub fn perpendicular(n: Vec3) Vec3 {
    const ax = @abs(n[0]);
    const ay = @abs(n[1]);
    const az = @abs(n[2]);
    const axis: Vec3 = if (ax <= ay and ax <= az) X3 else if (ay <= az) Y3 else Z3;
    const p = sub(axis, scale(n, dot(axis, n)));
    return normalized(p) orelse axis;
}

/// The largest absolute component's index.
pub fn maxAxis(a: Vec3) usize {
    const ax = @abs(a[0]);
    const ay = @abs(a[1]);
    const az = @abs(a[2]);
    if (ax >= ay and ax >= az) return 0;
    return if (ay >= az) 1 else 2;
}

pub inline fn min(a: Vec3, b: Vec3) Vec3 {
    return .{ @min(a[0], b[0]), @min(a[1], b[1]), @min(a[2], b[2]) };
}

pub inline fn max(a: Vec3, b: Vec3) Vec3 {
    return .{ @max(a[0], b[0]), @max(a[1], b[1]), @max(a[2], b[2]) };
}

pub fn isFinite(a: Vec3) bool {
    return a[0] - a[0] == 0 and a[1] - a[1] == 0 and a[2] - a[2] == 0;
}

// --- 2D ---

pub const ZERO2: Vec2 = .{ 0, 0 };

pub inline fn add2(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

pub inline fn sub2(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub inline fn scale2(a: Vec2, s: f64) Vec2 {
    return .{ a[0] * s, a[1] * s };
}

pub inline fn dot2(a: Vec2, b: Vec2) f64 {
    return a[0] * b[0] + a[1] * b[1];
}

/// The z of the 3D cross product: positive when `b` is counter-clockwise from `a`.
pub inline fn cross2(a: Vec2, b: Vec2) f64 {
    return a[0] * b[1] - a[1] * b[0];
}

pub inline fn lengthSq2(a: Vec2) f64 {
    return dot2(a, a);
}

pub inline fn length2(a: Vec2) f64 {
    return @sqrt(lengthSq2(a));
}

pub inline fn distanceSq2(a: Vec2, b: Vec2) f64 {
    return lengthSq2(sub2(a, b));
}

pub inline fn distance2(a: Vec2, b: Vec2) f64 {
    return @sqrt(distanceSq2(a, b));
}

/// `a + b·s`
pub inline fn addScaled2(a: Vec2, b: Vec2, s: f64) Vec2 {
    return .{ a[0] + b[0] * s, a[1] + b[1] * s };
}

pub fn normalized2(a: Vec2) ?Vec2 {
    const len = length2(a);
    if (!(len > 0.0)) return null;
    return scale2(a, 1.0 / len);
}

/// `a` turned a quarter turn counter-clockwise.
pub inline fn perp2(a: Vec2) Vec2 {
    return .{ -a[1], a[0] };
}

pub inline fn lerp2(a: Vec2, b: Vec2, t: f64) Vec2 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

pub fn isFinite2(a: Vec2) bool {
    return a[0] - a[0] == 0 and a[1] - a[1] == 0;
}

// --- homogeneous ---

/// The point of a homogeneous `(wx, wy, wz, w)`.
pub inline fn project4(a: Vec4) Vec3 {
    return .{ a[0] / a[3], a[1] / a[3], a[2] / a[3] };
}

pub inline fn add4(a: Vec4, b: Vec4) Vec4 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

pub inline fn sub4(a: Vec4, b: Vec4) Vec4 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3] };
}

pub inline fn scale4(a: Vec4, s: f64) Vec4 {
    return .{ a[0] * s, a[1] * s, a[2] * s, a[3] * s };
}

pub inline fn addScaled4(a: Vec4, b: Vec4, s: f64) Vec4 {
    return .{ a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s, a[3] + b[3] * s };
}

/// A point with weight `w`: `(wx, wy, wz, w)`.
pub inline fn weighted(p: Vec3, w: f64) Vec4 {
    return .{ p[0] * w, p[1] * w, p[2] * w, w };
}
