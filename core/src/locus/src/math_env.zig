const std = @import("std");

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
    chordal_deflection: f64 = 1e-3,
    angular_deflection: f64 = 0.2,
    min_circle_segments: u32 = 16,

    pub const Options = struct {
        vertex_tolerance: f64 = 1e-5,
        angular_tolerance: f64 = 1e-4,
        sewing_tolerance: f64 = 1e-5,
        parametric_tolerance: f64 = 1e-5,
        max_newton_trials: u32 = 50,
        max_marching_steps: u32 = 500,
        chordal_deflection: f64 = 1e-3,
        angular_deflection: f64 = 0.2,
        min_circle_segments: u32 = 16,
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
            .chordal_deflection = opts.chordal_deflection,
            .angular_deflection = opts.angular_deflection,
            .min_circle_segments = opts.min_circle_segments,
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
