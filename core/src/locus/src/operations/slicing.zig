const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const MathEnv = @import("../math_env.zig").MathEnv;
const tessellate = @import("tessellate.zig");

pub fn trimByPlane(
    allocator: std.mem.Allocator,
    dest_t: *topo_arena.TopologyArena,
    dest_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    nx: f64,
    ny: f64,
    nz: f64,
    offset: f64,
    env: MathEnv,
) !topo_types.SolidIndex {
    _ = allocator;
    _ = dest_t;
    _ = dest_g;
    _ = src_t;
    _ = src_g;
    _ = solid_id;
    _ = nx;
    _ = ny;
    _ = nz;
    _ = offset;
    _ = env;
    // TODO: Implement half-space plane trim
    return @enumFromInt(0);
}

pub const SolidPair = struct {
    first: topo_types.SolidIndex,
    second: topo_types.SolidIndex,
};

pub fn splitByPlane(
    allocator: std.mem.Allocator,
    dest_a_t: *topo_arena.TopologyArena,
    dest_a_g: *geom_arena.GeometryArena,
    dest_b_t: *topo_arena.TopologyArena,
    dest_b_g: *geom_arena.GeometryArena,
    src_t: *const topo_arena.TopologyArena,
    src_g: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    nx: f64,
    ny: f64,
    nz: f64,
    offset: f64,
    env: MathEnv,
) !SolidPair {
    _ = allocator;
    _ = dest_a_t;
    _ = dest_a_g;
    _ = dest_b_t;
    _ = dest_b_g;
    _ = src_t;
    _ = src_g;
    _ = solid_id;
    _ = nx;
    _ = ny;
    _ = nz;
    _ = offset;
    _ = env;
    // TODO: Implement exact plane bisection
    return .{ .first = @enumFromInt(0), .second = @enumFromInt(0) };
}

pub fn sliceMeshToContours(
    allocator: std.mem.Allocator,
    mesh: *const tessellate.Mesh,
    z_height: f64,
) ![][]const [2]f64 {
    _ = mesh;
    _ = z_height;
    // TODO: Implement Z-plane mesh intersection
    return try allocator.alloc([]const [2]f64, 0);
}
