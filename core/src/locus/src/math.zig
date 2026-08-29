const std = @import("std");

/// Used purely for floating-point safety and preventing division by zero.
pub const MATH_EPSILON = 1.0e-12;

pub const Vec2 = [2]f64;
pub const Vec3 = [3]f64;
pub const Vec4 = [4]f64;
pub const Mat2 = [4]f64; // Row-major: [m00, m01, m10, m11]
pub const Mat3 = [9]f64; // Row-major 3x3

// --- Tolerances ---

pub const Tolerance = struct {
    absolute: f64,
    squared: f64,
    parametric: f64, // Used for 2D (u,v) UV space checks

    /// Calculates adaptive tolerances based on solid bounding box dimensions
    pub fn fromBoundingBox(min: Vec3, max: Vec3) Tolerance {
        const dx = max[0] - min[0];
        const dy = max[1] - min[1];
        const dz = max[2] - min[2];
        const max_dim = @max(dx, @max(dy, dz));

        // Scale relative to object size (minimum floor of 1e-7 mm)
        const abs_tol = @max(1.0e-7, max_dim * 1.0e-7);
        return .{
            .absolute = abs_tol,
            .squared = abs_tol * abs_tol,
            .parametric = 1.0e-5, // Fixed domain tolerance for [0, 1] parameter space
        };
    }

    pub inline fn pointsCoincide(self: Tolerance, p1: Vec3, p2: Vec3) bool {
        return distSq(p1, p2) <= self.squared;
    }

    pub inline fn pointsCoincide2D(self: Tolerance, p1: Vec2, p2: Vec2) bool {
        const dx = p1[0] - p2[0];
        const dy = p1[1] - p2[1];
        return (dx * dx + dy * dy) <= (self.parametric * self.parametric);
    }
};

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
    if (m < MATH_EPSILON) return .{ 0, 0, 0 };
    return scale(a, 1.0 / m);
}

// --- 2D Vector Math ---

pub inline fn dot2(a: Vec2, b: Vec2) f64 {
    return a[0] * b[0] + a[1] * b[1];
}

pub inline fn sub2(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

// --- Matrix Math ---

pub inline fn invertMat2(m: Mat2) ?Mat2 {
    const det = m[0] * m[3] - m[1] * m[2];
    // Check for degenerate Jacobian
    if (@abs(det) < MATH_EPSILON) return null;
    const inv_det = 1.0 / det;
    return Mat2{
        m[3] * inv_det,  -m[1] * inv_det,
        -m[2] * inv_det, m[0] * inv_det,
    };
}

// --- Solvers ---

pub const CalcOutput2D = struct {
    val: Vec2,
    jacobian: Mat2,
};

/// 2D Newton-Raphson root finder for evaluating surface parameters (u, v).
pub fn solveNewton2D(
    ctx: anytype,
    evalFn: *const fn (ctx: @TypeOf(ctx), uv: Vec2) CalcOutput2D,
    guess: Vec2,
    trials: u32,
    tolerance: f64,
) ?Vec2 {
    var uv = guess;
    for (0..trials) |_| {
        const out = evalFn(ctx, uv);

        // Convergence check using injected tolerance
        if (@abs(out.val[0]) < tolerance and @abs(out.val[1]) < tolerance) {
            return uv;
        }

        const inv_jac = invertMat2(out.jacobian) orelse return null;

        // next = hint - inv * value
        uv[0] -= (inv_jac[0] * out.val[0] + inv_jac[1] * out.val[1]);
        uv[1] -= (inv_jac[2] * out.val[0] + inv_jac[3] * out.val[1]);
    }
    return null;
}
