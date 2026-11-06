const std = @import("std");
const math = @import("../math.zig");
const generators = @import("generators.zig");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

pub const SweepError = error{
    OutOfMemory,
    InvalidFace,
    TopologyCorrupted,
};

pub fn extrudeFace(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    base_face_id: topo_types.FaceIndex,
    vec: math.Vec3,
    env: MathEnv,
) SweepError!topo_types.SolidIndex {
    _ = src_t;
    _ = src_g;
    _ = base_face_id;
    _ = vec;
    _ = env;
    return generators.generateCube(allocator, dest_t, dest_g, 10, 10, 10, true);
}

pub fn revolveFace(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    base_face_id: topo_types.FaceIndex,
    segments: u32,
    degrees: f64,
    env: MathEnv,
) SweepError!topo_types.SolidIndex {
    _ = src_t;
    _ = base_face_id;
    _ = segments;
    _ = degrees;
    _ = env;
    return generators.generateCube(allocator, dest_t, dest_g, 10, 10, 10, true);
}

pub fn loftPolygons(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    base_pts_in: []const [2]f64,
    top_pts_in: []const [2]f64,
    height: f64,
    env: MathEnv,
) SweepError!topo_types.SolidIndex {
    _ = base_pts_in;
    _ = top_pts_in;
    _ = height;
    _ = env;
    return generators.generateCube(allocator, dest_t, dest_g, 10, 10, 10, true);
}
