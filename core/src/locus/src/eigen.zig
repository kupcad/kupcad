const std = @import("std");
const builtin = @import("builtin");
const math = @import("math.zig");

pub const LMStatus = enum(c_int) {
    not_started = 0,
    running = 1,
    improper_input_parameters = 2,
    relative_reduction_too_small = 3,
    relative_error_too_small = 4,
    cosine_too_small = 5,
    too_many_function_evaluation = 6,
    ftol_too_small = 7,
    xtol_too_small = 8,
    gtol_too_small = 9,
    user_asked = 10,
    _,

    pub fn isSuccess(self: LMStatus) bool {
        return switch (self) {
            .relative_reduction_too_small, .relative_error_too_small, .cosine_too_small, .ftol_too_small, .xtol_too_small => true,
            else => false,
        };
    }
};

const ResidualFunc = *const fn (x: [*]const f64, fvec: [*]f64, user_data: ?*anyopaque) callconv(.c) c_int;

extern "C" fn eigen_lm_solve(
    num_unknowns: c_int,
    num_residuals: c_int,
    func: ResidualFunc,
    user_data: ?*anyopaque,
    x_in_out: [*]f64,
    tol: f64,
    max_fev: c_int,
) c_int;

extern fn locus_eigen_det3(mat: [*]const f64) f64;
extern fn locus_eigen_det4(mat: [*]const f64) f64;
extern fn locus_eigen_pca_normal(pts: [*]const f64, num_pts: c_int, out_normal: [*]f64) void;

pub fn determinant3x3(mat: *const [9]f64) f64 {
    if (builtin.target.cpu.arch == .wasm32) {
        const m = mat;
        return m[0] * (m[4] * m[8] - m[5] * m[7]) -
            m[1] * (m[3] * m[8] - m[5] * m[6]) +
            m[2] * (m[3] * m[7] - m[4] * m[6]);
    } else {
        return locus_eigen_det3(mat.ptr);
    }
}

pub fn determinant4x4(mat: *const [16]f64) f64 {
    if (builtin.target.cpu.arch == .wasm32) {
        const m = mat;
        const sub0 = m[10] * m[15] - m[11] * m[14];
        const sub1 = m[9] * m[15] - m[11] * m[13];
        const sub2 = m[9] * m[14] - m[10] * m[13];
        const sub3 = m[8] * m[15] - m[11] * m[12];
        const sub4 = m[8] * m[14] - m[10] * m[12];
        const sub5 = m[8] * m[13] - m[9] * m[12];

        return m[0] * (m[5] * sub0 - m[6] * sub1 + m[7] * sub2) -
            m[1] * (m[4] * sub0 - m[6] * sub3 + m[7] * sub4) +
            m[2] * (m[4] * sub1 - m[5] * sub3 + m[7] * sub5) -
            m[3] * (m[4] * sub2 - m[5] * sub4 + m[6] * sub5);
    } else {
        return locus_eigen_det4(mat.ptr);
    }
}

pub fn pcaNormal(pts: []const math.Vec3) math.Vec3 {
    if (builtin.target.cpu.arch == .wasm32) {
        if (pts.len < 3) return .{ 0.0, 0.0, 1.0 };
        var centroid = math.Vec3{ 0.0, 0.0, 0.0 };
        for (pts) |p| {
            centroid[0] += p[0];
            centroid[1] += p[1];
            centroid[2] += p[2];
        }
        const inv_n = 1.0 / @as(f64, @floatFromInt(pts.len));
        centroid[0] *= inv_n;
        centroid[1] *= inv_n;
        centroid[2] *= inv_n;

        var cov = [_]f64{0} ** 9;
        for (pts) |p| {
            const dx = p[0] - centroid[0];
            const dy = p[1] - centroid[1];
            const dz = p[2] - centroid[2];
            cov[0] += dx * dx;
            cov[1] += dx * dy;
            cov[2] += dx * dz;
            cov[3] += dy * dx;
            cov[4] += dy * dy;
            cov[5] += dy * dz;
            cov[6] += dz * dx;
            cov[7] += dz * dy;
            cov[8] += dz * dz;
        }

        var V = [9]f64{
            1, 0, 0,
            0, 1, 0,
            0, 0, 1,
        };

        var iter: usize = 0;
        while (iter < 20) : (iter += 1) {
            var p: usize = 0;
            var q: usize = 1;
            var max_val = @abs(cov[1]);
            if (@abs(cov[2]) > max_val) {
                p = 0;
                q = 2;
                max_val = @abs(cov[2]);
            }
            if (@abs(cov[5]) > max_val) {
                p = 1;
                q = 2;
                max_val = @abs(cov[5]);
            }

            if (max_val < 1e-12) break;

            const app = cov[p * 3 + p];
            const aqq = cov[q * 3 + q];
            const apq = cov[p * 3 + q];

            const tau = (aqq - app) / (2.0 * apq);
            const t = if (tau >= 0) 1.0 / (tau + @sqrt(1.0 + tau * tau)) else -1.0 / (-tau + @sqrt(1.0 + tau * tau));
            const c = 1.0 / @sqrt(1.0 + t * t);
            const s = t * c;

            cov[p * 3 + p] = app - t * apq;
            cov[q * 3 + q] = aqq + t * apq;
            cov[p * 3 + q] = 0.0;
            cov[q * 3 + p] = 0.0;

            const r1 = if (p == 0 and q == 1) @as(usize, 2) else if (p == 0 and q == 2) @as(usize, 1) else @as(usize, 0);
            const a_p_r = cov[p * 3 + r1];
            const a_q_r = cov[q * 3 + r1];
            cov[p * 3 + r1] = c * a_p_r - s * a_q_r;
            cov[r1 * 3 + p] = cov[p * 3 + r1];
            cov[q * 3 + r1] = s * a_p_r + c * a_q_r;
            cov[r1 * 3 + q] = cov[q * 3 + r1];

            for (0..3) |k| {
                const v_kp = V[k * 3 + p];
                const v_kq = V[k * 3 + q];
                V[k * 3 + p] = c * v_kp - s * v_kq;
                V[k * 3 + q] = s * v_kp + c * v_kq;
            }
        }

        var min_idx: usize = 0;
        var min_e: f64 = cov[0];
        if (cov[4] < min_e) {
            min_idx = 1;
            min_e = cov[4];
        }
        if (cov[8] < min_e) {
            min_idx = 2;
            min_e = cov[8];
        }

        return math.normalize(.{ V[0 * 3 + min_idx], V[1 * 3 + min_idx], V[2 * 3 + min_idx] });
    } else {
        var normal: math.Vec3 = undefined;
        locus_eigen_pca_normal(@ptrCast(pts.ptr), @intCast(pts.len), &normal);
        return normal;
    }
}

/// Evaluates if point C is Counter-Clockwise (> 0), Clockwise (< 0), or Collinear (0) to line AB.
pub fn orient2D(a: math.Vec2, b: math.Vec2, c: math.Vec2) f64 {
    const mat = [9]f64{
        a[0], a[1], 1.0,
        b[0], b[1], 1.0,
        c[0], c[1], 1.0,
    };
    return determinant3x3(&mat);
}

/// Evaluates if point D lies strictly inside (> 0), outside (< 0), or on (0) the circumcircle of triangle ABC.
/// Assumes ABC is ordered Counter-Clockwise.
pub fn inCircle(a: math.Vec2, b: math.Vec2, c: math.Vec2, d: math.Vec2) f64 {
    const mat = [16]f64{
        a[0], a[1], (a[0] * a[0] + a[1] * a[1]), 1.0,
        b[0], b[1], (b[0] * b[0] + b[1] * b[1]), 1.0,
        c[0], c[1], (c[0] * c[0] + c[1] * c[1]), 1.0,
        d[0], d[1], (d[0] * d[0] + d[1] * d[1]), 1.0,
    };
    return determinant4x4(&mat);
}

fn minimizeNonLinearWasm(
    comptime Context: type,
    num_residuals: usize,
    x: []f64,
    context: *Context,
    comptime evalFn: fn (ctx: *Context, x_val: []const f64, fvec: []f64) i32,
    tol: f64,
    max_fev: usize,
) LMStatus {
    const n = x.len;
    const m = num_residuals;
    if (n > 8 or m > 16) return .improper_input_parameters;

    var fvec: [16]f64 = undefined;
    var fvec_new: [16]f64 = undefined;
    var J: [16 * 8]f64 = undefined;
    var JTJ: [8 * 8]f64 = undefined;
    var JTf: [8]f64 = undefined;
    var delta_x: [8]f64 = undefined;
    var x_new: [8]f64 = undefined;
    var A: [8 * 8]f64 = undefined;

    _ = evalFn(context, x, fvec[0..m]);
    var s0: f64 = 0.0;
    for (fvec[0..m]) |f| s0 += f * f;

    var max_res: f64 = 0.0;
    for (fvec[0..m]) |f| max_res = @max(max_res, @abs(f));
    if (max_res <= tol) return .relative_error_too_small;

    var lambda: f64 = 1e-3;
    var fev: usize = 1;

    while (fev < max_fev) : (fev += 1) {
        for (0..n) |j| {
            const h = @max(1e-6, 1e-6 * @abs(x[j]));
            const x_orig = x[j];
            x[j] += h;
            _ = evalFn(context, x, fvec_new[0..m]);
            fev += 1;
            x[j] = x_orig;

            for (0..m) |i| {
                J[i * n + j] = (fvec_new[i] - fvec[i]) / h;
            }
        }

        @memset(JTJ[0 .. n * n], 0.0);
        @memset(JTf[0..n], 0.0);
        for (0..n) |r| {
            for (0..n) |c| {
                var sum: f64 = 0.0;
                for (0..m) |i| sum += J[i * n + r] * J[i * n + c];
                JTJ[r * n + c] = sum;
            }
            var sum_f: f64 = 0.0;
            for (0..m) |i| sum_f += J[i * n + r] * fvec[i];
            JTf[r] = sum_f;
        }

        for (0..n) |r| {
            for (0..n) |c| {
                A[r * n + c] = JTJ[r * n + c];
            }
            const diag_val = @max(1e-6, JTJ[r * n + r]);
            A[r * n + r] += lambda * diag_val;
            delta_x[r] = -JTf[r];
        }

        var solve_ok = true;
        for (0..n) |i| {
            var max_r = i;
            var max_v = @abs(A[i * n + i]);
            for (i + 1..n) |r| {
                if (@abs(A[r * n + i]) > max_v) {
                    max_v = @abs(A[r * n + i]);
                    max_r = r;
                }
            }
            if (max_v < 1e-12) {
                solve_ok = false;
                break;
            }
            if (max_r != i) {
                for (0..n) |c| std.mem.swap(f64, &A[i * n + c], &A[max_r * n + c]);
                std.mem.swap(f64, &delta_x[i], &delta_x[max_r]);
            }
            const pivot = A[i * n + i];
            for (i + 1..n) |r| {
                const factor = A[r * n + i] / pivot;
                for (i..n) |c| A[r * n + c] -= factor * A[i * n + c];
                delta_x[r] -= factor * delta_x[i];
            }
        }

        if (solve_ok) {
            var k: usize = n;
            while (k > 0) {
                k -= 1;
                var sum = delta_x[k];
                for (k + 1..n) |c| sum -= A[k * n + c] * delta_x[c];
                delta_x[k] = sum / A[k * n + k];
            }

            for (0..n) |j| x_new[j] = x[j] + delta_x[j];
            _ = evalFn(context, x_new[0..n], fvec_new[0..m]);
            fev += 1;

            var s_new: f64 = 0.0;
            for (fvec_new[0..m]) |f| s_new += f * f;

            if (s_new < s0) {
                for (0..n) |j| x[j] = x_new[j];
                for (0..m) |i| fvec[i] = fvec_new[i];
                s0 = s_new;
                lambda = @max(1e-7, lambda / 10.0);

                var max_r_check: f64 = 0.0;
                for (fvec[0..m]) |f| max_r_check = @max(max_r_check, @abs(f));
                if (max_r_check <= tol * 10.0) return .relative_error_too_small;
            } else {
                lambda = @min(1e9, lambda * 10.0);
            }
        } else {
            lambda *= 10.0;
        }
    }

    var final_max: f64 = 0.0;
    for (fvec[0..m]) |f| final_max = @max(final_max, @abs(f));
    if (final_max <= tol * 10.0) return .relative_error_too_small;

    return .too_many_function_evaluation;
}

pub fn minimizeNonLinear(
    comptime Context: type,
    num_residuals: usize,
    x: []f64,
    context: *Context,
    comptime evalFn: fn (ctx: *Context, x_val: []const f64, fvec: []f64) i32,
    tol: f64,
    max_fev: usize,
) LMStatus {
    if (builtin.target.cpu.arch == .wasm32) {
        return minimizeNonLinearWasm(Context, num_residuals, x, context, evalFn, tol, max_fev);
    }

    const ContextWrapper = struct {
        num_x: usize,
        num_f: usize,
        user_ctx: *anyopaque,
    };
    const Wrapper = struct {
        fn cCallback(x_ptr: [*]const f64, fvec_ptr: [*]f64, user_data: ?*anyopaque) callconv(.c) c_int {
            const wrap_ctx: *ContextWrapper = @ptrCast(@alignCast(user_data));
            const x_slice = x_ptr[0..wrap_ctx.num_x];
            const fvec_slice = fvec_ptr[0..wrap_ctx.num_f];
            const typed_ctx: *Context = @ptrCast(@alignCast(wrap_ctx.user_ctx));
            return evalFn(typed_ctx, x_slice, fvec_slice);
        }
    };
    var cw = ContextWrapper{
        .num_x = x.len,
        .num_f = num_residuals,
        .user_ctx = context,
    };
    const status_int = eigen_lm_solve(
        @intCast(x.len),
        @intCast(num_residuals),
        Wrapper.cCallback,
        &cw,
        x.ptr,
        tol,
        @intCast(max_fev),
    );
    var status: LMStatus = @enumFromInt(status_int);

    var fvec_buf: [64]f64 = undefined;
    if (num_residuals <= 64) {
        const fvec = fvec_buf[0..num_residuals];
        _ = evalFn(context, x, fvec);
        var max_res: f64 = 0.0;
        for (fvec) |f| max_res = @max(max_res, @abs(f));
        if (max_res <= tol * 10.0) {
            status = .relative_error_too_small;
        }
    }
    return status;
}
