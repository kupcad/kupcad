const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const math = @import("../math.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

pub const BoundingBox = struct {
    min: math.Vec3,
    max: math.Vec3,
};

pub const Rect2D = struct {
    min: math.Vec2,
    max: math.Vec2,
};

pub fn genus(allocator: std.mem.Allocator, t_arena: *const topo_arena.TopologyArena, solid_id: topo_types.SolidIndex) i32 {
    _ = allocator;
    _ = t_arena;
    _ = solid_id;
    return 0;
}

pub fn boundingBox(t_arena: *const topo_arena.TopologyArena, g_arena: *const geom_arena.GeometryArena, solid_id: topo_types.SolidIndex) ?BoundingBox {
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    return null;
}

pub fn volume(allocator: std.mem.Allocator, t_arena: *const topo_arena.TopologyArena, g_arena: *const geom_arena.GeometryArena, solid_id: topo_types.SolidIndex, env: MathEnv) f64 {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    _ = env;
    return 0.0;
}

pub fn surfaceArea(allocator: std.mem.Allocator, t_arena: *const topo_arena.TopologyArena, g_arena: *const geom_arena.GeometryArena, solid_id: topo_types.SolidIndex, env: MathEnv) f64 {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    _ = env;
    return 0.0;
}

pub fn crossSectionArea(t_arena: *const topo_arena.TopologyArena, g_arena: *const geom_arena.GeometryArena, solid_id: topo_types.SolidIndex) f64 {
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    return 0.0;
}

pub fn crossSectionBounds(t_arena: *const topo_arena.TopologyArena, g_arena: *const geom_arena.GeometryArena, solid_id: topo_types.SolidIndex) Rect2D {
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    return .{ .min = .{ 0, 0 }, .max = .{ 0, 0 } };
}
