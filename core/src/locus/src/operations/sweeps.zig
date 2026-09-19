const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const MathEnv = @import("../math_env.zig").MathEnv;
const math = @import("../math.zig");

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
    _ = allocator;
    _ = dest_g;
    _ = src_t;
    _ = src_g;
    _ = base_face_id;
    _ = vec;
    _ = env;

    const sh_faces_start: u32 = @intCast(dest_t.shell_faces.items.len);
    _ = sh_faces_start;

    // TODO: Implement DoD Extrusion logic

    return @enumFromInt(0);
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
    _ = allocator;
    _ = dest_t;
    _ = dest_g;
    _ = src_t;
    _ = base_face_id;
    _ = segments;
    _ = degrees;
    _ = env;
    // TODO: Implement DoD Revolve logic
    return @enumFromInt(0);
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
    _ = allocator;
    _ = dest_t;
    _ = dest_g;
    _ = base_pts_in;
    _ = top_pts_in;
    _ = height;
    _ = env;
    // TODO: Implement DoD Loft logic
    return @enumFromInt(0);
}
