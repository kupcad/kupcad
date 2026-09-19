const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const booleans = @import("booleans.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

pub fn extractPolygon(
    allocator: std.mem.Allocator,
    t_arena: *const topo_arena.TopologyArena,
    g_arena: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
) ![]const [2]f64 {
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    // TODO: Implement 2D contour extraction
    return try allocator.alloc([2]f64, 0);
}

pub fn crossSectionBoolean(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_a_t: *const topo_arena.TopologyArena,
    src_a_g: *const geom_arena.GeometryArena,
    solid_a: topo_types.SolidIndex,
    src_b_t: *const topo_arena.TopologyArena,
    src_b_g: *const geom_arena.GeometryArena,
    solid_b: topo_types.SolidIndex,
    op: booleans.BooleanOp,
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
    _ = op;
    _ = env;
    // TODO: Implement 2D CSG
    return @enumFromInt(0);
}
