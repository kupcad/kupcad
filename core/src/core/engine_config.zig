//! The settings `CAD.config` changes. The shared ones come first and mean the same on
//! both kernels, so a model reads the same whichever engine builds it; `manifold` and
//! `brep` hold what only one kernel has.

const std = @import("std");
const geom = @import("../kernel/geometry_handle.zig");
const limits = @import("limits.zig");

const MAX_SEGMENTS: u32 = limits.MAX_SEGMENTS;

/// How finely curves are cut into straight edges. Defined in Locus, which can't import
/// KupCAD, so that its tessellator and the mesh engine follow one rule.
pub const Resolution = @import("../locus/src/math_env.zig").Resolution;

/// Settings only the mesh engine (Manifold) has.
pub const ManifoldConfig = struct {
    /// Merge coplanar triangles after each boolean, hull and union (within `tolerance`).
    simplify_coplanar: bool = false,
};

/// Settings only the exact engine (B-Rep) has.
pub const BRepConfig = struct {
    /// Iteration limit of the Newton root finders that project points onto surfaces.
    max_newton_trials: u32 = 50,
    /// Step limit when marching along a surface-surface intersection in a boolean.
    max_marching_steps: u32 = 500,
};

pub const EngineConfig = struct {
    engine: geom.EngineType = .manifold,
    /// Points closer than this are the same point: booleans weld them (B-Rep), coplanar
    /// faces merge within it (Manifold's simplify_coplanar), and measurements use it.
    tolerance: f64 = 1e-5,
    resolution: Resolution = .{},
    /// Most vertices one operation may produce (~500 MB of RAM at the default during CSG).
    max_vertices: usize = 5_000_000,
    manifold: ManifoldConfig = .{},
    brep: BRepConfig = .{},

    /// Why the settings can't be used, or null if they can. Checked whenever a script
    /// changes them, so the kernels never see a zero tolerance or a 1-edge circle.
    pub fn problem(self: EngineConfig) ?[]const u8 {
        if (!isPositive(self.tolerance)) return "tolerance must be a positive number";
        const res = self.resolution;
        if (res.segments != 0 and (res.segments < 3 or res.segments > MAX_SEGMENTS))
            return std.fmt.comptimePrint("resolution segments must be 0 (automatic) or 3 to {d}", .{MAX_SEGMENTS});
        if (!isPositive(res.min_angle) or res.min_angle > 180.0) return "resolution min_angle must be above 0 and at most 180 degrees";
        if (!isPositive(res.min_length)) return "resolution min_length must be a positive number";
        if (self.max_vertices == 0) return "max_vertices must be at least 1";
        if (self.brep.max_newton_trials == 0 or self.brep.max_newton_trials > limits.MAX_NEWTON_TRIALS)
            return std.fmt.comptimePrint("brep max_newton_trials must be 1 to {d}", .{limits.MAX_NEWTON_TRIALS});
        if (self.brep.max_marching_steps == 0 or self.brep.max_marching_steps > limits.MAX_MARCHING_STEPS)
            return std.fmt.comptimePrint("brep max_marching_steps must be 1 to {d}", .{limits.MAX_MARCHING_STEPS});
        return null;
    }

    /// The segment count a full circle of `radius` gets, within MAX_SEGMENTS: an automatic
    /// count can exceed it (a huge radius) without that being the script's fault.
    pub fn segmentsFor(self: EngineConfig, radius: f64) u32 {
        return @min(self.resolution.segmentsFor(radius), MAX_SEGMENTS);
    }

    /// A hash of the settings that change what an operation builds (not `max_vertices`,
    /// which only decides whether it may), so cached results are reused only under the
    /// settings they were built with.
    pub fn resultHash(self: EngineConfig) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, self.engine);
        std.hash.autoHash(&h, @as(u64, @bitCast(self.tolerance)));
        std.hash.autoHash(&h, self.resolution.segments);
        std.hash.autoHash(&h, @as(u64, @bitCast(self.resolution.min_angle)));
        std.hash.autoHash(&h, @as(u64, @bitCast(self.resolution.min_length)));
        std.hash.autoHash(&h, self.manifold.simplify_coplanar);
        std.hash.autoHash(&h, self.brep.max_newton_trials);
        std.hash.autoHash(&h, self.brep.max_marching_steps);
        return h.final();
    }
};

fn isPositive(x: f64) bool {
    return x > 0.0 and std.math.isFinite(x);
}
