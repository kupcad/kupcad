const std = @import("std");

// --- Core Math & Environment ---
pub const math = @import("math.zig");
pub const math_env = @import("math_env.zig");
pub const eigen = @import("eigen.zig");
pub const parallel = @import("parallel.zig");

// --- Geometry Subsystem (Phase 1 & 2) ---
pub const geometry = struct {
    pub const arena = @import("geometry/arena.zig");
    pub const curves = @import("geometry/curves.zig");
    pub const surfaces = @import("geometry/surfaces.zig");
    pub const types = @import("geometry/types.zig");
};

// --- Topology Subsystem (Phase 2, 3 & 4) ---
pub const topology = struct {
    pub const arena = @import("topology/arena.zig");
    pub const half_edge = @import("topology/half_edge.zig");
    pub const types = @import("topology/types.zig");
    pub const verifier = @import("topology/verifier.zig");
};

// --- CSG & Operations (Phase 4) ---
pub const operations = struct {
    pub const booleans = @import("operations/booleans.zig");
    pub const booleans_2d = @import("operations/booleans_2d.zig");
    pub const generators = @import("operations/generators.zig");
    pub const inspection = @import("operations/inspection.zig");
    pub const minkowski = @import("operations/minkowski.zig");
    pub const projections = @import("operations/projections.zig");
    pub const properties = @import("operations/properties.zig");
    pub const queries = @import("operations/queries.zig");
    pub const quickhull = @import("operations/quickhull.zig");
    pub const slicing = @import("operations/slicing.zig");
    pub const step_export = @import("operations/step_export.zig");
    pub const sweeps = @import("operations/sweeps.zig");
    pub const tessellate = @import("operations/tessellate.zig");
    pub const transforms = @import("operations/transforms.zig");
};
