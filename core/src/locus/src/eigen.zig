const std = @import("std");
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

    /// In a production engine using numerical differentiation, hitting the ftol/xtol
    /// precision limit (noise floor) is considered a successful convergence.
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
    return locus_eigen_det3(mat.ptr);
}

pub fn determinant4x4(mat: *const [16]f64) f64 {
    return locus_eigen_det4(mat.ptr);
}

pub fn pcaNormal(pts: []const math.Vec3) math.Vec3 {
    var normal: math.Vec3 = undefined;
    // Safely cast the contiguous array of [3]f64 directly to a flat f64 pointer
    locus_eigen_pca_normal(@ptrCast(pts.ptr), @intCast(pts.len), &normal);
    return normal;
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

/// Minimizes the squared sum of residuals for non-linear systems.
/// Uses Eigen's Levenberg-Marquardt solver with automatic numerical differentiation.
pub fn minimizeNonLinear(
    comptime Context: type,
    num_residuals: usize,
    x: []f64,
    context: *Context,
    comptime evalFn: fn (ctx: *Context, x_val: []const f64, fvec: []f64) i32,
    tol: f64,
    max_fev: usize,
) LMStatus {
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

    // If Eigen returns a bizarre status (like ImproperInputParameters) but actually converged to an exact root,
    // we manually verify the residual. This protects the CAD engine from C++ solver quirks.
    var fvec_buf: [64]f64 = undefined;
    if (num_residuals <= 64) {
        const fvec = fvec_buf[0..num_residuals];
        _ = evalFn(context, x, fvec);

        var max_res: f64 = 0.0;
        for (fvec) |f| max_res = @max(max_res, @abs(f));

        // If the maximum residual is within our tolerance, forcefully override to Success.
        if (max_res <= tol * 10.0) {
            status = .relative_error_too_small;
        }
    }

    return status;
}
