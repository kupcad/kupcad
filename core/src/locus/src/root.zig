//! The root of the `locus` module: what a host (KupCAD's B-Rep driver, or any program) may
//! use, and the `test` block that pulls in every test file. The layout and what each part
//! may import are in docs/architecture.md §4, and checked by source_test.zig.

/// Vectors, matrices, the exact predicates, rounded intervals and the solvers.
pub const math = struct {
    pub const vec = @import("math/vec.zig");
    pub const mat = @import("math/mat.zig");
    pub const predicates = @import("math/predicates.zig");
    pub const interval = @import("math/interval.zig");
    pub const solve = @import("math/solve.zig");
    pub const poly = @import("math/poly.zig");
    pub const trig = @import("math/trig.zig");
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
pub const Body = topology.Body;
/// The 2D kernel: the overlay engine (D9), what sketch booleans and offsets are made of.
pub const sketch = struct {
    pub const overlay = @import("sketch/overlay.zig");
    pub const boolean = @import("sketch/boolean.zig");
    pub const offset = @import("sketch/offset.zig");
    pub const query = @import("sketch/query.zig");
    pub const hull = @import("sketch/hull.zig");
};
/// Constructions: sewing, the primitives, the hull.
pub const construct = struct {
    pub const sew = @import("construct/sew.zig");
    pub const primitives = @import("construct/primitives.zig");
    pub const hull = @import("construct/hull.zig");
    pub const transform = @import("construct/transform.zig");
    pub const sweep = @import("construct/sweep.zig");
};
/// Meshes: the triangulator (M2), the tessellation of bodies (planar faces in M2).
pub const mesh = struct {
    pub const triangulate = @import("mesh/triangulate.zig");
    pub const edges = @import("mesh/edges.zig");
    pub const chords = @import("mesh/chords.zig");
    pub const tessellate = @import("mesh/tessellate.zig");
};
/// Measures: bounding boxes (volume, area and genus in M1).
pub const measure = struct {
    pub const bbox = @import("measure/bbox.zig");
    pub const mass = @import("measure/mass.zig");
};
/// Input and output: the body as JSON (the canonical form, fixtures, traces), STEP.
pub const query = struct {
    pub const index = @import("query/index.zig");
    pub const FaceIndex = index.FaceIndex;
    pub const in_face = @import("query/in_face.zig");
    pub const point_in_body = @import("query/point_in_body.zig");
    pub const raycast = @import("query/raycast.zig");
    pub const distance = @import("query/distance.zig");
    pub const faces = @import("query/faces.zig");
};

pub const io = struct {
    pub const body_json = @import("io/body_json.zig");
    pub const step_write = @import("io/step_write.zig");
    pub const trace = @import("io/trace.zig");
};
/// Spatial structures: the welding grid, interning over an arena, the BVH.
pub const spatial = struct {
    pub const grid = @import("spatial/grid.zig");
    pub const intern = @import("spatial/intern.zig");
    pub const bvh = @import("spatial/bvh.zig");
};

test {
    _ = @import("source_test.zig");
    _ = @import("parallel_test.zig");
    _ = @import("math/vec_test.zig");
    _ = @import("math/mat_test.zig");
    _ = @import("math/predicates_test.zig");
    _ = @import("math/interval_test.zig");
    _ = @import("math/solve_test.zig");
    _ = @import("math/trig_test.zig");
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
    _ = @import("io/body_json_test.zig");
    _ = @import("construct/primitives_test.zig");
    _ = @import("spatial/bvh_test.zig");
    _ = @import("io/step_write_test.zig");
    _ = @import("io/fixtures_test.zig");
    _ = @import("io/trace_test.zig");
    _ = @import("construct/transform_test.zig");
    _ = @import("construct/sweep_test.zig");
    _ = @import("measure/mass_test.zig");
    _ = @import("sketch/overlay_test.zig");
    _ = @import("sketch/boolean_test.zig");
    _ = @import("sketch/offset_test.zig");
    _ = @import("sketch/parameters_test.zig");
    _ = @import("sketch/query_test.zig");
    _ = @import("mesh/triangulate_test.zig");
    _ = @import("mesh/tessellate_test.zig");
    _ = @import("mesh/chords_test.zig");
    _ = @import("math/poly_test.zig");
    _ = @import("query/raycast_test.zig");
    _ = @import("query/distance_test.zig");
    _ = @import("query/faces_test.zig");
    _ = @import("construct/test_bodies.zig");
    _ = @import("determinism_test.zig");
    _ = @import("alloc_failure_test.zig");
    _ = @import("fuzz_test.zig");
}
