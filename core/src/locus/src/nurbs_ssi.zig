const std = @import("std");
const math = @import("math.zig");
const geom = @import("geometry.zig");
const eigen = @import("eigen.zig");
const bvh = @import("bvh.zig");
const parallel = @import("parallel.zig");

pub const SsiContext = struct {
    surf_a: *const geom.NurbsSurface,
    surf_b: *const geom.NurbsSurface,
    guess_pt: math.Vec3,
    marching_tangent: math.Vec3,
};

pub const SsiSeam = struct {
    points_3d: []math.Vec3,
    uvs_a: []math.Vec2,
    uvs_b: []math.Vec2,
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

fn inBounds(uv: [4]f64, sa: *const geom.NurbsSurface, sb: *const geom.NurbsSurface) bool {
    // Add a tiny epsilon tolerance to prevent premature termination due to float noise at edges
    const eps = 1e-6;
    return uv[0] >= sa.knots_u[0] - eps and uv[0] <= sa.knots_u[sa.knots_u.len - 1] + eps and
        uv[1] >= sa.knots_v[0] - eps and uv[1] <= sa.knots_v[sa.knots_v.len - 1] + eps and
        uv[2] >= sb.knots_u[0] - eps and uv[2] <= sb.knots_u[sb.knots_u.len - 1] + eps and
        uv[3] >= sb.knots_v[0] - eps and uv[3] <= sb.knots_v[sb.knots_v.len - 1] + eps;
}

/// Traces the continuous intersection curve between two NURBS surfaces.
/// Returns the 3D world seam and the 2D parametric p-curves for both faces.
pub fn traceIntersectionCurve(
    allocator: std.mem.Allocator,
    surf_a: *const geom.NurbsSurface,
    surf_b: *const geom.NurbsSurface,
    seed_uv: [4]f64,
    step_size: f64,
) !SsiSeam {
    var pts_3d: std.ArrayListUnmanaged(math.Vec3) = .empty;
    var uvs_a: std.ArrayListUnmanaged(math.Vec2) = .empty;
    var uvs_b: std.ArrayListUnmanaged(math.Vec2) = .empty;
    errdefer {
        pts_3d.deinit(allocator);
        uvs_a.deinit(allocator);
        uvs_b.deinit(allocator);
    }

    const max_steps: usize = 200; // Hard safety limit against closed UV loops

    // 1. Trace Forward
    var curr_uv = seed_uv;
    var steps: usize = 0;
    while (inBounds(curr_uv, surf_a, surf_b) and steps < max_steps) : (steps += 1) {
        try pts_3d.append(allocator, surf_a.evaluate(curr_uv[0], curr_uv[1]));
        try uvs_a.append(allocator, .{ curr_uv[0], curr_uv[1] });
        try uvs_b.append(allocator, .{ curr_uv[2], curr_uv[3] });

        if (stepIntersection(surf_a, surf_b, curr_uv, step_size)) |next_uv| {
            // Break if the step made virtually zero parametric progress
            const du = @abs(next_uv[0] - curr_uv[0]) + @abs(next_uv[1] - curr_uv[1]);
            if (du < 1e-6) break;
            curr_uv = next_uv;
        } else |_| break;
    }

    // 2. Trace Backward
    curr_uv = seed_uv;
    steps = 0;
    if (stepIntersection(surf_a, surf_b, curr_uv, -step_size)) |first_back_uv| {
        curr_uv = first_back_uv;
        while (inBounds(curr_uv, surf_a, surf_b) and steps < max_steps) : (steps += 1) {
            try pts_3d.insert(allocator, 0, surf_a.evaluate(curr_uv[0], curr_uv[1]));
            try uvs_a.insert(allocator, 0, .{ curr_uv[0], curr_uv[1] });
            try uvs_b.insert(allocator, 0, .{ curr_uv[2], curr_uv[3] });

            if (stepIntersection(surf_a, surf_b, curr_uv, -step_size)) |next_uv| {
                const du = @abs(next_uv[0] - curr_uv[0]) + @abs(next_uv[1] - curr_uv[1]);
                if (du < 1e-6) break;
                curr_uv = next_uv;
            } else |_| break;
        }
    } else |_| {}

    return SsiSeam{
        .points_3d = try pts_3d.toOwnedSlice(allocator),
        .uvs_a = try uvs_a.toOwnedSlice(allocator),
        .uvs_b = try uvs_b.toOwnedSlice(allocator),
    };
}

/// Automatically discovers and traces all continuous intersection seams between two NURBS surfaces.
pub fn findAllIntersectionSeams(
    allocator: std.mem.Allocator,
    surf_a: *const geom.NurbsSurface,
    surf_b: *const geom.NurbsSurface,
    step_size: f64,
) ![]SsiSeam {
    const seeds = try bvh.generateSurfaceSurfaceSeeds(allocator, surf_a, surf_b, 4);
    defer allocator.free(seeds);

    if (seeds.len == 0) return &[_]SsiSeam{};

    const results = try allocator.alloc(?SsiSeam, seeds.len);
    defer allocator.free(results);
    @memset(results, null);

    const ParallelCtx = struct {
        main_alloc: std.mem.Allocator,
        surf_a: *const geom.NurbsSurface,
        surf_b: *const geom.NurbsSurface,
        seeds: []const bvh.SurfaceSeed,
        step_size: f64,
        results: []?SsiSeam,
    };

    var ctx = ParallelCtx{
        .main_alloc = allocator,
        .surf_a = surf_a,
        .surf_b = surf_b,
        .seeds = seeds,
        .step_size = step_size,
        .results = results,
    };

    parallel.parallelFor(0, seeds.len, ParallelCtx, &ctx, struct {
        fn doWork(i: usize, c: *ParallelCtx) void {
            // Isolated arena per worker thread to prevent std.testing.allocator races
            var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer thread_arena.deinit();
            const thread_alloc = thread_arena.allocator();

            const seed = c.seeds[i];
            const start_uv = [4]f64{ seed.u_a, seed.v_a, seed.u_b, seed.v_b };

            if (traceIntersectionCurve(thread_alloc, c.surf_a, c.surf_b, start_uv, c.step_size)) |seam| {
                if (seam.points_3d.len > 2) {
                    // Deep-copy thread result to persistent allocator
                    c.results[i] = SsiSeam{
                        .points_3d = c.main_alloc.dupe(math.Vec3, seam.points_3d) catch return,
                        .uvs_a = c.main_alloc.dupe(math.Vec2, seam.uvs_a) catch return,
                        .uvs_b = c.main_alloc.dupe(math.Vec2, seam.uvs_b) catch return,
                    };
                }
            } else |_| {}
        }
    }.doWork);

    var final_seams = std.ArrayListUnmanaged(SsiSeam).empty;
    errdefer {
        for (final_seams.items) |s| {
            allocator.free(s.points_3d);
            allocator.free(s.uvs_a);
            allocator.free(s.uvs_b);
        }
        final_seams.deinit(allocator);
    }

    for (results) |opt_seam| {
        if (opt_seam) |seam| {
            var is_duplicate = false;
            for (final_seams.items) |existing| {
                if (seam.points_3d.len == 0 or existing.points_3d.len == 0) continue;

                // Robust check: test if the midpoint of 'seam' lies near ANY point on 'existing'
                const sample_pt = seam.points_3d[seam.points_3d.len / 2];
                for (existing.points_3d) |eq| {
                    if (math.distSq(sample_pt, eq) < 1.0) { // 1.0 unit squared distance threshold in 3D
                        is_duplicate = true;
                        break;
                    }
                }
                if (is_duplicate) break;
            }

            if (is_duplicate) {
                allocator.free(seam.points_3d);
                allocator.free(seam.uvs_a);
                allocator.free(seam.uvs_b);
            } else {
                try final_seams.append(allocator, seam);
            }
        }
    }

    return final_seams.toOwnedSlice(allocator);
}
