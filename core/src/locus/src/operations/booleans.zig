const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const MathEnv = @import("../math_env.zig").MathEnv;
const queries = @import("queries.zig");

pub const BooleanOp = enum {
    union_op,
    difference,
    intersection,
};

pub const BooleanError = error{
    OutOfMemory,
    TopologyCorrupted,
    SolverFailed,
};

/// Re-exported for driver access
pub const isPointInsideSolid = queries.isPointInsideSolid;

pub fn computeBoolean(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_a_t: *const topo_arena.TopologyArena,
    src_a_g: *const geom_arena.GeometryArena,
    solid_a: topo_types.SolidIndex,
    src_b_t: *const topo_arena.TopologyArena,
    src_b_g: *const geom_arena.GeometryArena,
    solid_b: topo_types.SolidIndex,
    op: BooleanOp,
    env: MathEnv,
) BooleanError!topo_types.SolidIndex {
    _ = op;
    _ = env;

    const working_a = try deepCloneSolid(allocator, dest_t, dest_g, src_a_t, src_a_g, solid_a);
    const working_b = try deepCloneSolid(allocator, dest_t, dest_g, src_b_t, src_b_g, solid_b);

    _ = working_a;
    _ = working_b;

    return try packageResultingSolid(allocator, dest_t);
}

pub fn deepCloneSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    src_solid: topo_types.SolidIndex,
) !topo_types.SolidIndex {
    _ = allocator;
    _ = dest_t;
    _ = dest_g;
    _ = src_t;
    _ = src_g;
    _ = src_solid;
    return @enumFromInt(0);
}

fn packageResultingSolid(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
) !topo_types.SolidIndex {
    _ = allocator;
    _ = dest_t;
    return @enumFromInt(0);
}
