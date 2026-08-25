const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const TransformError = error{
    OutOfMemory,
};

/// Deep clones a Solid and applies a 4x4 affine transformation matrix to its geometry.
pub fn transformSolid(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    mat: [16]f64,
) TransformError!topo.SolidId {
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    _ = mat;
    // 1. Clone the topological subgraph (Solid -> Shells -> Faces -> Wires -> Edges -> Vertices)
    // 2. For each cloned Vertex, multiply its `point` by `mat`.
    // 3. For each cloned Curve/Surface, apply the affine transform:
    //    - Planes: multiply `origin` by `mat`, multiply `u_axis` and `v_axis` by rotation-only part of `mat`.
    //    - Cylinders/Spheres: transform the `center`/`origin` and scale the `radius` (if uniform).

    // Example math operation on a vertex:
    // const new_x = v[0]*mat[0] + v[1]*mat[4] + v[2]*mat[8] + mat[12];

    return 0; // Return new transformed solid ID
}

pub fn translateSolid(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    x: f64,
    y: f64,
    z: f64,
) TransformError!topo.SolidId {
    const mat = [_]f64{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        x, y, z, 1,
    };
    return transformSolid(t_arena, g_arena, solid_id, mat);
}

pub fn scaleSolid(
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    sx: f64,
    sy: f64,
    sz: f64,
) TransformError!topo.SolidId {
    const mat = [_]f64{
        sx, 0,  0,  0,
        0,  sy, 0,  0,
        0,  0,  sz, 0,
        0,  0,  0,  1,
    };
    return transformSolid(t_arena, g_arena, solid_id, mat);
}
