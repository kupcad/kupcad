//! The numerical solvers: Newton's method for a scalar equation and for the projection of a
//! point onto a curve or a surface (with the NURBS Book's four stopping tests, §6.1), a
//! Levenberg–Marquardt minimizer for small least-squares problems (the refinement step of
//! surface marching), and the Jacobi eigen-decomposition of a symmetric 3×3 (a point set's
//! best plane). Every loop is bounded by the step count the caller passes (`Limits`); a
//! solver that doesn't converge says so, never a stand-in.

const std = @import("std");
const vec = @import("vec.zig");
const mat = @import("mat.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

/// How a Newton iteration ended.
pub const Outcome = enum {
    /// A stopping test passed: the answer is within the tolerances.
    converged,
    /// The step count ran out with no test passed.
    exhausted,
    /// A derivative vanished, or a value stopped being a number.
    singular,
};

// ---------------------------------------------------------------------------------------
// Newton on a scalar equation

/// The value and derivative of a scalar function at a parameter.
pub const Scalar = struct { f: f64, df: f64 };

pub const ScalarResult = struct { t: f64, f: f64, outcome: Outcome };

/// A root of `f(t) = 0` from `t0` by Newton's method, `t` held to `domain` (clamped at its
/// ends). Converged when `|f| <= eps_f` or the step is below `eps_t`.
pub fn newtonScalar(
    ctx: anytype,
    comptime evaluate: fn (ctx: @TypeOf(ctx), t: f64) Scalar,
    t0: f64,
    domain: [2]f64,
    eps_f: f64,
    eps_t: f64,
    max_steps: u32,
) ScalarResult {
    var t = std.math.clamp(t0, domain[0], domain[1]);
    var step: u32 = 0;
    while (step < max_steps) : (step += 1) {
        const s = evaluate(ctx, t);
        if (!(s.f - s.f == 0)) return .{ .t = t, .f = s.f, .outcome = .singular };
        if (@abs(s.f) <= eps_f) return .{ .t = t, .f = s.f, .outcome = .converged };
        if (!(s.df != 0.0) or !(s.df - s.df == 0)) return .{ .t = t, .f = s.f, .outcome = .singular };
        const next = std.math.clamp(t - s.f / s.df, domain[0], domain[1]);
        const moved = @abs(next - t);
        t = next;
        if (moved <= eps_t) {
            const final = evaluate(ctx, t);
            return .{ .t = t, .f = final.f, .outcome = if (@abs(final.f) <= eps_f or moved <= eps_t) .converged else .exhausted };
        }
    }
    const final = evaluate(ctx, t);
    return .{ .t = t, .f = final.f, .outcome = if (@abs(final.f) <= eps_f) .converged else .exhausted };
}

// ---------------------------------------------------------------------------------------
// Projection onto a curve (NURBS Book §6.1)

/// A curve's point and first two derivatives at a parameter.
pub const CurveSample = struct { p: Vec3, d1: Vec3, d2: Vec3 };

pub const CurveDomain = struct {
    /// `[t0, t1]`
    range: [2]f64,
    /// A closed curve: a parameter past an end wraps to the other.
    periodic: bool = false,
};

pub const Projection1 = struct {
    t: f64,
    point: Vec3,
    /// `|C(t) − target|`
    distance: f64,
    outcome: Outcome,
};

/// The parameter of the curve nearest `target`, refined from `t0` by Newton on
/// `f(t) = C'(t)·(C(t) − P)` with `f' = C''·(C − P) + |C'|²`. Stops (§6.1) when the point
/// is within `eps_point` of `target` (1), the angle between `C'` and `C − P` is within
/// `eps_cosine` of a right angle (2), or a step moves the point less than `eps_point` (4);
/// a parameter is clamped to the domain, or wrapped on a periodic curve (3). `t0` should be
/// near the answer: the caller seeds it from samples.
pub fn projectToCurve(
    ctx: anytype,
    comptime evaluate: fn (ctx: @TypeOf(ctx), t: f64) CurveSample,
    target: Vec3,
    t0: f64,
    domain: CurveDomain,
    eps_point: f64,
    eps_cosine: f64,
    max_steps: u32,
) Projection1 {
    var t = fitToDomain(t0, domain);
    var s = evaluate(ctx, t);
    var step: u32 = 0;
    while (true) {
        const diff = vec.sub(s.p, target);
        const dist = vec.length(diff);
        if (!(dist - dist == 0)) return .{ .t = t, .point = s.p, .distance = dist, .outcome = .singular };
        // (1) the point coincides
        if (dist <= eps_point) return .{ .t = t, .point = s.p, .distance = dist, .outcome = .converged };
        const d1_len = vec.length(s.d1);
        // (2) the tangent is at a right angle to the way to the target
        if (d1_len > 0.0 and @abs(vec.dot(s.d1, diff)) <= eps_cosine * d1_len * dist) {
            return .{ .t = t, .point = s.p, .distance = dist, .outcome = .converged };
        }
        if (step >= max_steps) return .{ .t = t, .point = s.p, .distance = dist, .outcome = .exhausted };
        step += 1;
        const f = vec.dot(s.d1, diff);
        const df = vec.dot(s.d2, diff) + d1_len * d1_len;
        if (!(df != 0.0) or !(df - df == 0)) return .{ .t = t, .point = s.p, .distance = dist, .outcome = .singular };
        // (3) stay in the domain
        const next = fitToDomain(t - f / df, domain);
        // (4) the parameter stopped moving the point
        if (@abs(next - t) * d1_len <= eps_point) {
            const at = evaluate(ctx, next);
            const d = vec.distance(at.p, target);
            return .{ .t = next, .point = at.p, .distance = d, .outcome = .converged };
        }
        t = next;
        s = evaluate(ctx, t);
    }
}

fn fitToDomain(t: f64, domain: CurveDomain) f64 {
    const lo = domain.range[0];
    const hi = domain.range[1];
    if (!domain.periodic) return std.math.clamp(t, lo, hi);
    const period = hi - lo;
    if (!(period > 0.0)) return lo;
    var u = t;
    // Bounded: a parameter is never more than a few periods out
    var guard: u8 = 0;
    while (u < lo and guard < 64) : (guard += 1) u += period;
    while (u > hi and guard < 64) : (guard += 1) u -= period;
    return std.math.clamp(u, lo, hi);
}

// ---------------------------------------------------------------------------------------
// Projection onto a surface (NURBS Book §6.1)

/// A surface's point and derivatives to second order at a parameter pair.
pub const SurfaceSample = struct { p: Vec3, du: Vec3, dv: Vec3, duu: Vec3, duv: Vec3, dvv: Vec3 };

pub const SurfaceDomain = struct {
    u: CurveDomain,
    v: CurveDomain,
};

pub const Projection2 = struct {
    uv: Vec2,
    point: Vec3,
    distance: f64,
    outcome: Outcome,
};

/// The parameters of the surface nearest `target`, refined from `uv0` by Newton on
/// `f = S_u·r, g = S_v·r` (`r = S − P`) with the Jacobian `[[|S_u|² + r·S_uu, S_u·S_v +
/// r·S_uv], [S_u·S_v + r·S_uv, |S_v|² + r·S_vv]]`, the stopping tests as `projectToCurve`'s.
pub fn projectToSurface(
    ctx: anytype,
    comptime evaluate: fn (ctx: @TypeOf(ctx), u: f64, v: f64) SurfaceSample,
    target: Vec3,
    uv0: Vec2,
    domain: SurfaceDomain,
    eps_point: f64,
    eps_cosine: f64,
    max_steps: u32,
) Projection2 {
    var uv = Vec2{ fitToDomain(uv0[0], domain.u), fitToDomain(uv0[1], domain.v) };
    var s = evaluate(ctx, uv[0], uv[1]);
    var step: u32 = 0;
    while (true) {
        const r = vec.sub(s.p, target);
        const dist = vec.length(r);
        if (!(dist - dist == 0)) return .{ .uv = uv, .point = s.p, .distance = dist, .outcome = .singular };
        if (dist <= eps_point) return .{ .uv = uv, .point = s.p, .distance = dist, .outcome = .converged };
        const du_len = vec.length(s.du);
        const dv_len = vec.length(s.dv);
        const f = vec.dot(s.du, r);
        const g = vec.dot(s.dv, r);
        if (du_len > 0.0 and dv_len > 0.0 and @abs(f) <= eps_cosine * du_len * dist and @abs(g) <= eps_cosine * dv_len * dist) {
            return .{ .uv = uv, .point = s.p, .distance = dist, .outcome = .converged };
        }
        if (step >= max_steps) return .{ .uv = uv, .point = s.p, .distance = dist, .outcome = .exhausted };
        step += 1;
        const j00 = du_len * du_len + vec.dot(r, s.duu);
        const j01 = vec.dot(s.du, s.dv) + vec.dot(r, s.duv);
        const j11 = dv_len * dv_len + vec.dot(r, s.dvv);
        const det = j00 * j11 - j01 * j01;
        if (!(det != 0.0) or !(det - det == 0)) return .{ .uv = uv, .point = s.p, .distance = dist, .outcome = .singular };
        const delta_u = -(j11 * f - j01 * g) / det;
        const delta_v = -(j00 * g - j01 * f) / det;
        const next = Vec2{ fitToDomain(uv[0] + delta_u, domain.u), fitToDomain(uv[1] + delta_v, domain.v) };
        const moved = vec.length(vec.add(vec.scale(s.du, next[0] - uv[0]), vec.scale(s.dv, next[1] - uv[1])));
        if (moved <= eps_point) {
            const at = evaluate(ctx, next[0], next[1]);
            return .{ .uv = next, .point = at.p, .distance = vec.distance(at.p, target), .outcome = .converged };
        }
        uv = next;
        s = evaluate(ctx, uv[0], uv[1]);
    }
}

// ---------------------------------------------------------------------------------------
// Levenberg–Marquardt

/// The result of a least-squares minimization.
pub const LeastSquares = struct {
    /// The sum of the squared residuals at the end.
    cost: f64,
    /// The largest residual's magnitude at the end.
    max_residual: f64,
    evaluations: u32,
    outcome: Outcome,
};

/// Minimizes the sum of squares of `m` residuals over `n` unknowns in `x` (both fixed at
/// compile time, small) by Levenberg–Marquardt with a numerical Jacobian. `residuals(ctx,
/// x, out)` writes the `m` residuals at `x`. Converged when every residual is within
/// `eps_residual`, or a step changes `x` by less than `eps_step` in every unknown.
/// Costs about `(n + 2) · steps` residual evaluations.
pub fn levenbergMarquardt(
    comptime n: usize,
    comptime m: usize,
    ctx: anytype,
    comptime residuals: fn (ctx: @TypeOf(ctx), x: *const [n]f64, out: *[m]f64) void,
    x: *[n]f64,
    eps_residual: f64,
    eps_step: f64,
    max_steps: u32,
) LeastSquares {
    var r: [m]f64 = undefined;
    residuals(ctx, x, &r);
    var evaluations: u32 = 1;
    var cost = sumSquares(&r);
    if (!(cost - cost == 0)) return .{ .cost = cost, .max_residual = maxAbs(&r), .evaluations = evaluations, .outcome = .singular };
    if (maxAbs(&r) <= eps_residual) return .{ .cost = cost, .max_residual = maxAbs(&r), .evaluations = evaluations, .outcome = .converged };

    var lambda: f64 = 1e-3;
    var step: u32 = 0;
    while (step < max_steps) : (step += 1) {
        // The Jacobian by forward differences
        var jac: [m][n]f64 = undefined;
        for (0..n) |j| {
            const h = @max(1e-7, 1e-7 * @abs(x[j]));
            const saved = x[j];
            x[j] = saved + h;
            var r_h: [m]f64 = undefined;
            residuals(ctx, x, &r_h);
            evaluations += 1;
            x[j] = saved;
            for (0..m) |i| jac[i][j] = (r_h[i] - r[i]) / h;
        }
        // Normal equations JᵀJ δ = −Jᵀr, damped on the diagonal
        var jtj: [n][n]f64 = undefined;
        var jtr: [n]f64 = undefined;
        for (0..n) |a| {
            for (0..n) |b| {
                var s: f64 = 0;
                for (0..m) |i| s += jac[i][a] * jac[i][b];
                jtj[a][b] = s;
            }
            var s: f64 = 0;
            for (0..m) |i| s += jac[i][a] * r[i];
            jtr[a] = s;
        }
        var improved = false;
        // Try the step; a worse one raises the damping and tries again, bounded
        var tries: u8 = 0;
        while (tries < 16) : (tries += 1) {
            var a: [n][n]f64 = jtj;
            for (0..n) |k| a[k][k] += lambda * @max(jtj[k][k], 1e-12);
            var delta: [n]f64 = undefined;
            for (0..n) |k| delta[k] = -jtr[k];
            if (!solveLinear(n, &a, &delta)) {
                lambda *= 10.0;
                continue;
            }
            var x_new: [n]f64 = undefined;
            var largest_step: f64 = 0;
            for (0..n) |k| {
                x_new[k] = x[k] + delta[k];
                largest_step = @max(largest_step, @abs(delta[k]));
            }
            var r_new: [m]f64 = undefined;
            residuals(ctx, &x_new, &r_new);
            evaluations += 1;
            const cost_new = sumSquares(&r_new);
            if (cost_new - cost_new != 0) return .{ .cost = cost, .max_residual = maxAbs(&r), .evaluations = evaluations, .outcome = .singular };
            if (cost_new < cost) {
                x.* = x_new;
                r = r_new;
                cost = cost_new;
                lambda = @max(1e-12, lambda / 10.0);
                improved = true;
                if (maxAbs(&r) <= eps_residual or largest_step <= eps_step) {
                    return .{ .cost = cost, .max_residual = maxAbs(&r), .evaluations = evaluations, .outcome = .converged };
                }
                break;
            }
            lambda = @min(1e12, lambda * 10.0);
        }
        if (!improved) {
            // No damping found a better point: at a minimum of the residuals, or stuck
            return .{ .cost = cost, .max_residual = maxAbs(&r), .evaluations = evaluations, .outcome = if (maxAbs(&r) <= eps_residual) .converged else .exhausted };
        }
    }
    return .{ .cost = cost, .max_residual = maxAbs(&r), .evaluations = evaluations, .outcome = if (maxAbs(&r) <= eps_residual) .converged else .exhausted };
}

fn sumSquares(r: []const f64) f64 {
    var s: f64 = 0;
    for (r) |v| s += v * v;
    return s;
}

fn maxAbs(r: []const f64) f64 {
    var s: f64 = 0;
    for (r) |v| s = @max(s, @abs(v));
    return s;
}

/// Solves `a·x = b` in place (`b` becomes `x`) by Gaussian elimination with partial
/// pivoting; false when a pivot is zero.
fn solveLinear(comptime n: usize, a: *[n][n]f64, b: *[n]f64) bool {
    for (0..n) |col| {
        var pivot = col;
        for (col + 1..n) |row| {
            if (@abs(a[row][col]) > @abs(a[pivot][col])) pivot = row;
        }
        if (!(a[pivot][col] != 0.0)) return false;
        if (pivot != col) {
            std.mem.swap([n]f64, &a[pivot], &a[col]);
            std.mem.swap(f64, &b[pivot], &b[col]);
        }
        for (col + 1..n) |row| {
            const factor = a[row][col] / a[col][col];
            for (col..n) |k| a[row][k] -= factor * a[col][k];
            b[row] -= factor * b[col];
        }
    }
    var k: usize = n;
    while (k > 0) {
        k -= 1;
        var s = b[k];
        for (k + 1..n) |j| s -= a[k][j] * b[j];
        b[k] = s / a[k][k];
    }
    return true;
}

// ---------------------------------------------------------------------------------------
// Jacobi eigen-decomposition

/// The eigenvalues of a symmetric 3×3 in ascending order and the matching unit
/// eigenvectors.
pub const Eigen3 = struct {
    values: [3]f64,
    vectors: [3]Vec3,
};

/// Sweeps of Jacobi rotations on a symmetric 3×3 until the off-diagonal part is below
/// `eps` relative to the diagonal; a fixed sweep order keeps the result the same
/// everywhere.
pub fn jacobiSymmetric3(m: *const mat.Mat3, eps: f64, max_sweeps: u32) Eigen3 {
    var a: [3][3]f64 = .{ .{ m[0], m[1], m[2] }, .{ m[3], m[4], m[5] }, .{ m[6], m[7], m[8] } };
    var v: [3][3]f64 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    const pairs = [_][2]usize{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 } };
    var sweep: u32 = 0;
    while (sweep < max_sweeps) : (sweep += 1) {
        const off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2];
        const diag = a[0][0] * a[0][0] + a[1][1] * a[1][1] + a[2][2] * a[2][2];
        if (off <= eps * eps * @max(diag, 1e-300)) break;
        for (pairs) |pq| {
            const p = pq[0];
            const q = pq[1];
            if (a[p][q] == 0.0) continue;
            const theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
            const t = if (theta >= 0) 1.0 / (theta + @sqrt(1.0 + theta * theta)) else -1.0 / (-theta + @sqrt(1.0 + theta * theta));
            const c = 1.0 / @sqrt(1.0 + t * t);
            const s = t * c;
            // Rotate rows and columns p, q of a
            for (0..3) |k| {
                const akp = a[k][p];
                const akq = a[k][q];
                a[k][p] = c * akp - s * akq;
                a[k][q] = s * akp + c * akq;
            }
            for (0..3) |k| {
                const apk = a[p][k];
                const aqk = a[q][k];
                a[p][k] = c * apk - s * aqk;
                a[q][k] = s * apk + c * aqk;
            }
            for (0..3) |k| {
                const vkp = v[k][p];
                const vkq = v[k][q];
                v[k][p] = c * vkp - s * vkq;
                v[k][q] = s * vkp + c * vkq;
            }
        }
    }
    // Ascending by eigenvalue, a fixed sort of three
    var order = [3]usize{ 0, 1, 2 };
    if (a[order[1]][order[1]] < a[order[0]][order[0]]) std.mem.swap(usize, &order[0], &order[1]);
    if (a[order[2]][order[2]] < a[order[1]][order[1]]) std.mem.swap(usize, &order[1], &order[2]);
    if (a[order[1]][order[1]] < a[order[0]][order[0]]) std.mem.swap(usize, &order[0], &order[1]);
    var out: Eigen3 = undefined;
    for (order, 0..) |i, k| {
        out.values[k] = a[i][i];
        out.vectors[k] = .{ v[0][i], v[1][i], v[2][i] };
    }
    return out;
}

/// The unit normal of the plane that fits `points` best (least squares): the eigenvector
/// of the covariance's smallest eigenvalue. Null for fewer than three points or points on
/// a line (two eigenvalues zero, no plane preferred).
pub fn fitPlaneNormal(points: []const Vec3, eps: f64) ?Vec3 {
    if (points.len < 3) return null;
    var centroid = vec.ZERO3;
    for (points) |p| centroid = vec.add(centroid, p);
    centroid = vec.scale(centroid, 1.0 / @as(f64, @floatFromInt(points.len)));
    var cov: mat.Mat3 = @splat(0);
    for (points) |p| {
        const d = vec.sub(p, centroid);
        for (0..3) |i| {
            for (0..3) |j| cov[i * 3 + j] += d[i] * d[j];
        }
    }
    const eig = jacobiSymmetric3(&cov, eps, 32);
    // On a line the two smallest eigenvalues are both zero relative to the largest
    if (eig.values[1] <= eps * @max(eig.values[2], 1e-300)) return null;
    return vec.normalized(eig.vectors[0]);
}
