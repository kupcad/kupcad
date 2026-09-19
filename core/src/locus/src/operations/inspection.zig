const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const math = @import("../math.zig");

pub const FaceData = struct {
    index: u32,
    normal: math.Vec3,
    centroid: math.Vec3,
};

pub fn queryFaces(
    allocator: std.mem.Allocator,
    t_arena: *const topo_arena.TopologyArena,
    g_arena: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    direction: math.Vec3,
    tolerance: f64,
) !?[]FaceData {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    _ = direction;
    _ = tolerance;
    return null;
}
