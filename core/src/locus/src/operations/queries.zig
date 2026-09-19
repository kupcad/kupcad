const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const math = @import("../math.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

pub const RayHit = struct {
    distance: f64,
    position: math.Vec3,
    normal: math.Vec3,
};

pub fn isPointInsideSolid(
    allocator: std.mem.Allocator,
    t_arena: *const topo_arena.TopologyArena,
    g_arena: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    pt: math.Vec3,
    env: MathEnv,
) bool {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    _ = pt;
    _ = env;
    return false;
}

pub fn rayCast(
    allocator: std.mem.Allocator,
    t_arena: *const topo_arena.TopologyArena,
    g_arena: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    ray_origin: math.Vec3,
    ray_end: math.Vec3,
    env: MathEnv,
) !?[]RayHit {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    _ = ray_origin;
    _ = ray_end;
    _ = env;
    return null;
}

pub fn minGap(
    allocator: std.mem.Allocator,
    t_arena_a: *const topo_arena.TopologyArena,
    g_arena_a: *const geom_arena.GeometryArena,
    solid_a: topo_types.SolidIndex,
    t_arena_b: *const topo_arena.TopologyArena,
    g_arena_b: *const geom_arena.GeometryArena,
    solid_b: topo_types.SolidIndex,
    env: MathEnv,
) f64 {
    _ = allocator;
    _ = t_arena_a;
    _ = g_arena_a;
    _ = solid_a;
    _ = t_arena_b;
    _ = g_arena_b;
    _ = solid_b;
    _ = env;
    return 0.0;
}
