const std = @import("std");

/// Fewest straight edges an automatically resolved circle gets.
const MIN_AUTO_SEGMENTS: u32 = 5;

/// How finely a curve is cut into straight edges wherever it has to be (meshing, export):
/// `segments` edges per full circle when set, otherwise as many as keep each edge within
/// `min_angle` degrees of arc and `min_length` long, whichever gives fewer (OpenSCAD's
/// $fn, $fa and $fs). KupCAD's mesh engine follows the same rule, so both kernels cut a
/// curve alike.
pub const Resolution = struct {
    segments: u32 = 0, // 0 = from min_angle and min_length
    min_angle: f64 = 12.0,
    min_length: f64 = 2.0,

    /// The number of edges a full circle of `radius` gets.
    pub fn segmentsFor(self: Resolution, radius: f64) u32 {
        if (self.segments > 0) return self.segments;
        if (!(radius > 0.0)) return MIN_AUTO_SEGMENTS;
        const by_angle = 360.0 / self.min_angle;
        const by_length = 2.0 * std.math.pi * radius / self.min_length;
        const count = @ceil(@min(by_angle, by_length));
        // Past u32 the count is meaningless anyway; callers clamp to their own limits.
        if (!(count < @as(f64, std.math.maxInt(u32)))) return std.math.maxInt(u32);
        return @max(MIN_AUTO_SEGMENTS, @as(u32, @intFromFloat(count)));
    }
};

/// Context-aware tolerance environment mapped from KupCAD's EngineConfig.
pub const MathEnv = struct {
    // Spatial Tolerances
    vertex_tolerance: f64 = 1e-5,
    angular_tolerance: f64 = 1e-4,
    sewing_tolerance: f64 = 1e-5,
    parametric_tolerance: f64 = 1e-5,

    // Precomputed Hot-Loop Squares (Defaulted for 1e-5)
    vertex_tol_sq: f64 = 1e-10,
    parametric_tol_sq: f64 = 1e-10,

    // Solver Constraints
    max_newton_trials: u32 = 50,
    max_marching_steps: u32 = 500,

    // Tessellation Directives
    resolution: Resolution = .{},

    pub const Options = struct {
        vertex_tolerance: f64 = 1e-5,
        angular_tolerance: f64 = 1e-4,
        sewing_tolerance: f64 = 1e-5,
        parametric_tolerance: f64 = 1e-5,
        max_newton_trials: u32 = 50,
        max_marching_steps: u32 = 500,
        resolution: Resolution = .{},
    };

    pub fn init(opts: Options) MathEnv {
        return .{
            .vertex_tolerance = opts.vertex_tolerance,
            .angular_tolerance = opts.angular_tolerance,
            .sewing_tolerance = opts.sewing_tolerance,
            .parametric_tolerance = opts.parametric_tolerance,
            .vertex_tol_sq = opts.vertex_tolerance * opts.vertex_tolerance,
            .parametric_tol_sq = opts.parametric_tolerance * opts.parametric_tolerance,
            .max_newton_trials = opts.max_newton_trials,
            .max_marching_steps = opts.max_marching_steps,
            .resolution = opts.resolution,
        };
    }

    /// Spawns a localized MathEnv scaled to the bounding box of the current operation.
    pub fn scaleForBounds(self: MathEnv, min: [3]f64, max: [3]f64) MathEnv {
        const dx = max[0] - min[0];
        const dy = max[1] - min[1];
        const dz = max[2] - min[2];
        const max_dim = @max(dx, @max(dy, dz));

        const scaled_tol = @max(self.vertex_tolerance, max_dim * self.vertex_tolerance);

        var local_env = self;
        local_env.vertex_tolerance = scaled_tol;
        local_env.vertex_tol_sq = scaled_tol * scaled_tol;

        return local_env;
    }

    pub inline fn isCoincident(self: *const MathEnv, a: [3]f64, b: [3]f64) bool {
        const dx = a[0] - b[0];
        const dy = a[1] - b[1];
        const dz = a[2] - b[2];
        return (dx * dx + dy * dy + dz * dz) <= self.vertex_tol_sq;
    }

    pub inline fn isCoincident2D(self: *const MathEnv, a: [2]f64, b: [2]f64) bool {
        const dx = a[0] - b[0];
        const dy = a[1] - b[1];
        return (dx * dx + dy * dy) <= self.parametric_tol_sq;
    }

    pub inline fn isParallel(self: *const MathEnv, dir_a: [3]f64, dir_b: [3]f64) bool {
        const dot = dir_a[0] * dir_b[0] + dir_a[1] * dir_b[1] + dir_a[2] * dir_b[2];
        return (1.0 - @abs(dot)) <= self.angular_tolerance;
    }
};
