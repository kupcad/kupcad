// --- API Exports ---
pub const math = @import("math.zig");
pub const topology = @import("topology.zig");
pub const geometry = @import("geometry.zig");
pub const generators = @import("generators.zig");
pub const transforms = @import("transforms.zig");
pub const quickhull = @import("quickhull.zig");
pub const sweeps = @import("sweeps.zig");
pub const minkowski = @import("minkowski.zig");
pub const booleans = @import("booleans.zig");
pub const booleans_2d = @import("booleans_2d.zig");
pub const slicing = @import("slicing.zig");
pub const tessellate = @import("tessellate.zig");
pub const eigen = @import("eigen.zig");
pub const nurbs_ssi = @import("nurbs_ssi.zig");

test {
    _ = @import("blends_test.zig");
    _ = @import("booleans_test.zig");
    _ = @import("booleans_2d_test.zig");
    _ = @import("bvh_test.zig");
    _ = @import("eigen_test.zig");
    _ = @import("eigen_lm_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("nurbs_test.zig");
    _ = @import("nurbs_intersect_test.zig");
    _ = @import("nurbs_ssi_test.zig");
    _ = @import("nurbs_tessellate_test.zig");
    _ = @import("nurbs_topology_test.zig");
    _ = @import("generators_test.zig");
    _ = @import("geometry_test.zig");
    _ = @import("parallel_test.zig");
    _ = @import("minkowski_test.zig");
    _ = @import("quickhull_test.zig");
    _ = @import("properties_test.zig");
    _ = @import("inspection_test.zig");
    _ = @import("projections_test.zig");
    _ = @import("queries_test.zig");
    _ = @import("slicing_test.zig");
    _ = @import("stress_test.zig");
    _ = @import("sweeps_test.zig");
    _ = @import("tessellate_test.zig");
    _ = @import("tolerances_test.zig");
    _ = @import("transforms_test.zig");
    _ = @import("validator_test.zig");
}
