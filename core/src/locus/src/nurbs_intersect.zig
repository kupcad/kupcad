const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const eigen = @import("eigen.zig");

pub const CurveSurfaceContext = struct {
    curve: *const geom.NurbsCurve,
    surface: *const geom.NurbsSurface,
};

fn evalCurveSurface(ctx: *CurveSurfaceContext, x: []const f64, fvec: []f64) i32 {
    const t = x[0];
    const u = x[1];
    const v = x[2];

    const pt_c = ctx.curve.evaluate(t);
    const pt_s = ctx.surface.evaluate(u, v);

    // The residuals are simply the delta across the X, Y, and Z axes
    fvec[0] = pt_c[0] - pt_s[0];
    fvec[1] = pt_c[1] - pt_s[1];
    fvec[2] = pt_c[2] - pt_s[2];

    return 0;
}

/// Minimizes the distance between a NURBS curve and surface.
/// Returns the exact (t, u, v) parameters of the intersection.
pub fn intersectCurveSurface(
    curve: *const geom.NurbsCurve,
    surface: *const geom.NurbsSurface,
    guess_t: f64,
    guess_u: f64,
    guess_v: f64,
) !math.Vec3 {
    var ctx = CurveSurfaceContext{ .curve = curve, .surface = surface };

    // Seed the solver with the initial guess (typically provided by BVH overlap)
    var vars = [_]f64{ guess_t, guess_u, guess_v };

    const status = eigen.minimizeNonLinear(
        CurveSurfaceContext,
        3, // 3 residuals (X, Y, Z)
        &vars,
        &ctx,
        evalCurveSurface,
        1e-6,
        400,
    );

    if (!status.isSuccess()) return error.IntersectionFailed;

    return .{ vars[0], vars[1], vars[2] };
}
