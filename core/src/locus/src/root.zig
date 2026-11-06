//! The root of the `locus` module: what a host (KupCAD's B-Rep driver, or any program) may
//! use, and the `test` block that pulls in every test file. The layout and what each part
//! may import are in docs/architecture.md §4, and checked by source_test.zig.

/// Vectors, matrices, the exact predicates and the solvers.
pub const math = struct {
    pub const vec = @import("math/vec.zig");
    pub const mat = @import("math/mat.zig");
    pub const predicates = @import("math/predicates.zig");
    pub const solve = @import("math/solve.zig");
};
pub const tolerance = @import("tolerance.zig");
pub const Tolerance = tolerance.Tolerance;
pub const Resolution = tolerance.Resolution;
pub const diagnostics = @import("diagnostics.zig");
pub const Diagnostics = diagnostics.Diagnostics;
pub const Error = diagnostics.Error;
pub const Limits = diagnostics.Limits;
pub const Options = diagnostics.Options;
pub const parallel = @import("parallel.zig");
pub const Parallel = parallel.Parallel;
/// The geometry: kinds and references, curves, pcurves, surfaces, NURBS.
pub const geometry = struct {
    pub const types = @import("geometry/types.zig");
    pub const curves = @import("geometry/curves.zig");
    pub const pcurves = @import("geometry/pcurves.zig");
    pub const surfaces = @import("geometry/surfaces.zig");
    pub const nurbs = @import("geometry/nurbs.zig");
    pub const canonical = @import("geometry/canonical.zig");
    pub const transform = @import("geometry/transform.zig");
    pub const arena = @import("geometry/arena.zig");
    pub const Geometry = arena.Geometry;
};
/// The topology: the entities, the body, its traversals, the Euler operators, the
/// checker and the tags.
pub const topology = struct {
    pub const types = @import("topology/types.zig");
    pub const body = @import("topology/body.zig");
    pub const Body = body.Body;
    pub const traverse = @import("topology/traverse.zig");
    pub const tags = @import("topology/tags.zig");
    pub const euler = @import("topology/euler.zig");
    pub const check = @import("topology/check.zig");
};
/// Spatial structures: the welding grid, interning over an arena, the BVH.
pub const spatial = struct {
    pub const grid = @import("spatial/grid.zig");
    pub const intern = @import("spatial/intern.zig");
};

/// The first model (September 2026), which the driver still runs on: typed indices over two
/// arenas, half-edges, Euler operators, a checker, primitive builders, transforms, a hull,
/// a BVH and a STEP writer, with stubs for the rest. M0 rebuilds all of it on the model of
/// docs/architecture.md §5 and deletes this namespace at its "rebuild what exists" item;
/// until then nothing new imports it.
pub const legacy = struct {
    pub const math = @import("legacy/math.zig");
    pub const math_env = @import("legacy/math_env.zig");
    pub const geometry = struct {
        pub const arena = @import("legacy/geometry/arena.zig");
        pub const curves = @import("legacy/geometry/curves.zig");
        pub const surfaces = @import("legacy/geometry/surfaces.zig");
        pub const types = @import("legacy/geometry/types.zig");
    };
    pub const topology = struct {
        pub const arena = @import("legacy/topology/arena.zig");
        pub const half_edge = @import("legacy/topology/half_edge.zig");
        pub const types = @import("legacy/topology/types.zig");
        pub const verifier = @import("legacy/topology/verifier.zig");
    };
    pub const operations = struct {
        pub const booleans = @import("legacy/operations/booleans.zig");
        pub const booleans_2d = @import("legacy/operations/booleans_2d.zig");
        pub const generators = @import("legacy/operations/generators.zig");
        pub const inspection = @import("legacy/operations/inspection.zig");
        pub const minkowski = @import("legacy/operations/minkowski.zig");
        pub const projections = @import("legacy/operations/projections.zig");
        pub const properties = @import("legacy/operations/properties.zig");
        pub const queries = @import("legacy/operations/queries.zig");
        pub const quickhull = @import("legacy/operations/quickhull.zig");
        pub const slicing = @import("legacy/operations/slicing.zig");
        pub const step_export = @import("legacy/operations/step_export.zig");
        pub const sweeps = @import("legacy/operations/sweeps.zig");
        pub const tessellate = @import("legacy/operations/tessellate.zig");
        pub const transforms = @import("legacy/operations/transforms.zig");
    };
};

test {
    _ = @import("source_test.zig");
    _ = @import("parallel_test.zig");
    _ = @import("math/vec_test.zig");
    _ = @import("math/mat_test.zig");
    _ = @import("math/predicates_test.zig");
    _ = @import("math/solve_test.zig");
    _ = @import("tolerance_test.zig");
    _ = @import("diagnostics_test.zig");
    _ = @import("geometry/curves_test.zig");
    _ = @import("geometry/nurbs_test.zig");
    _ = @import("geometry/surfaces_test.zig");
    _ = @import("spatial/intern_test.zig");
    _ = @import("geometry/transform_test.zig");
    _ = @import("topology/body_test.zig");
    _ = @import("topology/euler_test.zig");
    _ = @import("topology/check_test.zig");

    _ = @import("legacy/geometry/interning_test.zig");
    _ = @import("legacy/operations/generators_test.zig");
    _ = @import("legacy/topology/bvh_test.zig");
    _ = @import("legacy/topology/checkpoint_test.zig");
    _ = @import("legacy/topology/euler_ops_test.zig");
    _ = @import("legacy/topology/verifier_test.zig");
    _ = @import("legacy/testing/fixture_test.zig");
}
