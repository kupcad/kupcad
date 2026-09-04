const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const eigen = @import("eigen.zig");

pub const SsiContext = struct {
    surf_a: *const geom.NurbsSurface,
    surf_b: *const geom.NurbsSurface,
    guess_pt: math.Vec3,
    marching_tangent: math.Vec3,
};

fn evalSsiStep(ctx: *SsiContext, x: []const f64, fvec: []f64) i32 {
    const pt_a = ctx.surf_a.evaluate(x[0], x[1]);
    const pt_b = ctx.surf_b.evaluate(x[2], x[3]);

    // Residuals 0-2: The surfaces must touch at exactly the same XYZ coordinate
    fvec[0] = pt_a[0] - pt_b[0];
    fvec[1] = pt_a[1] - pt_b[1];
    fvec[2] = pt_a[2] - pt_b[2];

    // Residual 3: The solution must lie on the stepping plane to ensure forward progress
    // (P_A - P_guess) \cdot T = 0
    const dx = pt_a[0] - ctx.guess_pt[0];
    const dy = pt_a[1] - ctx.guess_pt[1];
    const dz = pt_a[2] - ctx.guess_pt[2];

    fvec[3] = (dx * ctx.marching_tangent[0]) +
        (dy * ctx.marching_tangent[1]) +
        (dz * ctx.marching_tangent[2]);

    return 0;
}

/// Takes a single marching step along the surface-surface intersection curve.
/// Returns the exact [uA, vA, uB, vB] parameters for the next point.
pub fn stepIntersection(
    surf_a: *const geom.NurbsSurface,
    surf_b: *const geom.NurbsSurface,
    current_uv: [4]f64,
    step_size: f64,
) ![4]f64 {
    // 1. Numerically approximate surface normals via finite central differences
    const eps = 1e-5;
    const pa_u1 = surf_a.evaluate(current_uv[0] + eps, current_uv[1]);
    const pa_u0 = surf_a.evaluate(current_uv[0] - eps, current_uv[1]);
    const pa_v1 = surf_a.evaluate(current_uv[0], current_uv[1] + eps);
    const pa_v0 = surf_a.evaluate(current_uv[0], current_uv[1] - eps);

    const du_a = [3]f64{ pa_u1[0] - pa_u0[0], pa_u1[1] - pa_u0[1], pa_u1[2] - pa_u0[2] };
    const dv_a = [3]f64{ pa_v1[0] - pa_v0[0], pa_v1[1] - pa_v0[1], pa_v1[2] - pa_v0[2] };

    var norm_a = [3]f64{
        du_a[1] * dv_a[2] - du_a[2] * dv_a[1],
        du_a[2] * dv_a[0] - du_a[0] * dv_a[2],
        du_a[0] * dv_a[1] - du_a[1] * dv_a[0],
    };

    // FIXED: Normalize surface normal A
    const len_a = @sqrt(norm_a[0] * norm_a[0] + norm_a[1] * norm_a[1] + norm_a[2] * norm_a[2]);
    if (len_a > 1e-12) {
        norm_a[0] /= len_a;
        norm_a[1] /= len_a;
        norm_a[2] /= len_a;
    }

    const pb_u1 = surf_b.evaluate(current_uv[2] + eps, current_uv[3]);
    const pb_u0 = surf_b.evaluate(current_uv[2] - eps, current_uv[3]);
    const pb_v1 = surf_b.evaluate(current_uv[2], current_uv[3] + eps);
    const pb_v0 = surf_b.evaluate(current_uv[2], current_uv[3] - eps);

    const du_b = [3]f64{ pb_u1[0] - pb_u0[0], pb_u1[1] - pb_u0[1], pb_u1[2] - pb_u0[2] };
    const dv_b = [3]f64{ pb_v1[0] - pb_v0[0], pb_v1[1] - pb_v0[1], pb_v1[2] - pb_v0[2] };

    var norm_b = [3]f64{
        du_b[1] * dv_b[2] - du_b[2] * dv_b[1],
        du_b[2] * dv_b[0] - du_b[0] * dv_b[2],
        du_b[0] * dv_b[1] - du_b[1] * dv_b[0],
    };

    // FIXED: Normalize surface normal B
    const len_b = @sqrt(norm_b[0] * norm_b[0] + norm_b[1] * norm_b[1] + norm_b[2] * norm_b[2]);
    if (len_b > 1e-12) {
        norm_b[0] /= len_b;
        norm_b[1] /= len_b;
        norm_b[2] /= len_b;
    }

    // 2. Compute stepping tangent T = N_A x N_B
    var tangent = [3]f64{
        norm_a[1] * norm_b[2] - norm_a[2] * norm_b[1],
        norm_a[2] * norm_b[0] - norm_a[0] * norm_b[2],
        norm_a[0] * norm_b[1] - norm_a[1] * norm_b[0],
    };

    const t_len = @sqrt(tangent[0] * tangent[0] + tangent[1] * tangent[1] + tangent[2] * tangent[2]);
    if (t_len < 1e-12) return error.TangentSingularity;
    tangent[0] /= t_len;
    tangent[1] /= t_len;
    tangent[2] /= t_len;

    // 3. Project linear guess forward
    const start_pt = surf_a.evaluate(current_uv[0], current_uv[1]);
    const guess_pt = [3]f64{
        start_pt[0] + tangent[0] * step_size,
        start_pt[1] + tangent[1] * step_size,
        start_pt[2] + tangent[2] * step_size,
    };

    // 4. Refine guess onto both surfaces using the 4-residual LM system
    var ctx = SsiContext{
        .surf_a = surf_a,
        .surf_b = surf_b,
        .guess_pt = guess_pt,
        .marching_tangent = tangent,
    };

    var vars = [4]f64{ current_uv[0], current_uv[1], current_uv[2], current_uv[3] };

    const status = eigen.minimizeNonLinear(
        SsiContext,
        4, // 4 residuals
        &vars,
        &ctx,
        evalSsiStep,
        1e-6,
        400,
    );

    if (!status.isSuccess()) return error.SolverFailed;
    return vars;
}
