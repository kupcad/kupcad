const std = @import("std");
const geom = @import("../kernel/geometry_handle.zig");

/// Configuration parameters for the fast parallel mesh CSG backend (Manifold 3D).
pub const ManifoldConfig = struct {
    tolerance: f64 = 1e-5, // Coincidence & float-snapping threshold for mesh booleans
    fixed_segments: u32 = 0, // Explicit segment count override (0 = auto-calculate via angle & length)
    min_angle_deg: f64 = 12.0, // Minimum angular step per segment in degrees (OpenSCAD $fa)
    min_segment_len: f64 = 2.0, // Minimum linear edge length in units/mm (OpenSCAD $fs)
    simplify_coplanar: bool = false, // Merge redundant coplanar triangles after CSG operations

    /// Calculates the optimal segment count for an arc or circle of a given radius.
    pub fn getSegments(self: ManifoldConfig, radius: f64) u32 {
        if (self.fixed_segments > 0) return self.fixed_segments;
        if (radius <= 0.0) return 12;

        const angle_count = 360.0 / @max(self.min_angle_deg, 0.1);
        const length_count = (2.0 * std.math.pi * radius) / @max(self.min_segment_len, 0.01);

        const count = @min(angle_count, length_count);
        return @max(5, @as(u32, @intFromFloat(@ceil(count))));
    }
};

/// Configuration parameters for the exact analytical surface backend (B-Rep).
pub const BRepConfig = struct {
    // Tolerances
    tolerance: f64 = 1e-5, // Linear Tolerance - The minimum 3D distance between two points to treat them as coincident
    angle_tolerance: f64 = 1e-4, // Angular Tolerance - The maximum angle difference between two surface normal vectors to consider them coplanar or tangent
    sewing_tolerance: f64 = 1e-5, // Stitching/Healing Tolerance - The distance threshold used when stitching free edges of adjacent faces into a closed Shell or Solid

    // Tessellation (B-Rep -> Mesh)
    chordal_deflection: f64 = 1e-3, // The maximum allowable distance between a curved B-Rep surface and the flat triangle mesh representing it. Lower values produce smoother curves
    angular_deflection: f64 = 0.2, // The maximum allowed angle between adjacent triangle normal vectors on a curved surface
    min_circle_segments: u32 = 16, // The minimum number of linear segments used when meshing circular arcs/cylinders

    // Solvers
    max_newton_trials: u32 = 50, // The maximum iteration limit for Newton-Raphson root finders when projecting points onto surfaces or curves
    max_marching_steps: u32 = 500, // The maximum number of steps allowed when marching along a surface-surface intersection curve during CSG Boolean operations
};

pub const EngineConfig = struct {
    engine: geom.EngineType = .manifold, // Selects the active backend CAD evaluation kernel
    manifold: ManifoldConfig = .{},
    brep: BRepConfig = .{},
};
