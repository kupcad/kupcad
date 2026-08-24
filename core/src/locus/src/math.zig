const std = @import("std");

/// Used purely for floating-point safety and preventing division by zero.
pub const MATH_EPSILON = 1.0e-12;
/// The fallback default if the user doesn't provide a config.
pub const DEFAULT_TOLERANCE = 1.0e-6;

pub const Vec2 = [2]f64;
pub const Vec3 = [3]f64;
pub const Vec4 = [4]f64;
pub const Mat2 = [4]f64; // Row-major 2x2 matrix
pub const Mat3 = [9]f64; // Row-major 3x3 matrix

// --- Vector Math ---

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

pub inline fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

pub inline fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub inline fn scale(a: Vec3, s: f64) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

pub inline fn magSq(a: Vec3) f64 {
    return dot(a, a);
}

pub inline fn mag(a: Vec3) f64 {
    return @sqrt(magSq(a));
}

pub inline fn distSq(a: Vec3, b: Vec3) f64 {
    return magSq(sub(a, b));
}

pub inline fn normalize(a: Vec3) Vec3 {
    const m = mag(a);
    if (m < MATH_EPSILON) return .{ 0, 0, 0 }; // Use strict Epsilon here
    return scale(a, 1.0 / m);
}

// --- Matrix Math ---

pub inline fn invertMat2(m: Mat2) ?Mat2 {
    const det = m[0] * m[3] - m[1] * m[2];
    // Use strict Epsilon to prevent Jacobian singularity crashes
    if (@abs(det) < MATH_EPSILON) return null;
    const inv_det = 1.0 / det;
    return Mat2{
        m[3] * inv_det,  -m[1] * inv_det,
        -m[2] * inv_det, m[0] * inv_det,
    };
}

// --- Newton-Raphson Solvers ---

pub const CalcOutput2D = struct {
    val: Vec2,
    jacobian: Mat2,
};

/// 2D Newton-Raphson root finder for surface parameter projection.
/// Accepts a runtime `tolerance` from the VM configurations.
pub fn solveNewton2D(
    ctx: anytype,
    evalFn: *const fn (ctx: @TypeOf(ctx), uv: Vec2) CalcOutput2D,
    guess: Vec2,
    trials: usize,
    tolerance: f64, // <-- Explicit runtime tolerance passed down
) ?Vec2 {
    var uv = guess;
    for (0..trials) |_| {
        const out = evalFn(ctx, uv);

        // Did we hit the user's requested tolerance?
        if (@abs(out.val[0]) < tolerance and @abs(out.val[1]) < tolerance) {
            return uv;
        }

        const inv_jac = invertMat2(out.jacobian) orelse return null;

        uv[0] -= (inv_jac[0] * out.val[0] + inv_jac[1] * out.val[1]);
        uv[1] -= (inv_jac[2] * out.val[0] + inv_jac[3] * out.val[1]);
    }
    return null; // Did not converge within allowed trials
}
