const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const eigen = @import("eigen.zig");
const bvh = @import("bvh.zig");

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

/// Automatically finds all exact intersection points between a NURBS curve and surface.
/// Returns a list of (t, u, v) parameters. Caller owns the returned slice.
pub fn findExactIntersections(
    allocator: std.mem.Allocator,
    curve: *const geom.NurbsCurve,
    surface: *const geom.NurbsSurface,
) ![]math.Vec3 {
    // 1. Generate candidate seeds via BVH spatial subdivision
    const seeds = try bvh.generateCurveSurfaceSeeds(allocator, curve, surface, 10, 10);
    defer allocator.free(seeds);

    var results: std.ArrayListUnmanaged(math.Vec3) = .empty;
    errdefer results.deinit(allocator);

    // 2. Refine each seed using the LM non-linear solver
    for (seeds) |seed| {
        if (intersectCurveSurface(curve, surface, seed.t, seed.u, seed.v)) |root| {
            // Bounds check: Ensure the converged root is actually within the parametric domains
            if (root[0] < curve.knots[0] or root[0] > curve.knots[curve.knots.len - 1]) continue;
            if (root[1] < surface.knots_u[0] or root[1] > surface.knots_u[surface.knots_u.len - 1]) continue;
            if (root[2] < surface.knots_v[0] or root[2] > surface.knots_v[surface.knots_v.len - 1]) continue;

            // 3. Deduplicate: Multiple adjacent BVH seeds can converge to the same mathematical root
            var is_duplicate = false;
            for (results.items) |existing| {
                const dt = root[0] - existing[0];
                const du = root[1] - existing[1];
                const dv = root[2] - existing[2];
                if ((dt * dt + du * du + dv * dv) < 1e-10) {
                    is_duplicate = true;
                    break;
                }
            }

            if (!is_duplicate) {
                try results.append(allocator, root);
            }
        } else |_| {
            // Solver failed to converge for this specific seed; ignore and move on
        }
    }

    return results.toOwnedSlice(allocator);
}
