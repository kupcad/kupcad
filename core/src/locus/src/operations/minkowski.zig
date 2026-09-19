const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

pub fn minkowskiSumConvex(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_a_t: *const topo_arena.TopologyArena,
    src_a_g: *const geom_arena.GeometryArena,
    solid_a: topo_types.SolidIndex,
    src_b_t: *const topo_arena.TopologyArena,
    src_b_g: *const geom_arena.GeometryArena,
    solid_b: topo_types.SolidIndex,
    env: MathEnv,
) !topo_types.SolidIndex {
    _ = allocator;
    _ = dest_t;
    _ = dest_g;
    _ = src_a_t;
    _ = src_a_g;
    _ = solid_a;
    _ = src_b_t;
    _ = src_b_g;
    _ = solid_b;
    _ = env;
    // TODO: Implement Quickhull-based Minkowski sum
    return @enumFromInt(0);
}
