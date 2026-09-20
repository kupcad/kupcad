const std = @import("std");
const topo_arena = @import("../topology/arena.zig");
const topo_types = @import("../topology/types.zig");
const geom_arena = @import("../geometry/arena.zig");
const math = @import("../math.zig");
const MathEnv = @import("../math_env.zig").MathEnv;

pub const Mesh = struct {
    vertices: std.ArrayListUnmanaged(math.Vec3) = .empty,
    normals: std.ArrayListUnmanaged(math.Vec3) = .empty,
    triangles: std.ArrayListUnmanaged([3]u32) = .empty,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.normals.deinit(allocator);
        self.triangles.deinit(allocator);
    }
};

pub fn tessellateSolid(
    allocator: std.mem.Allocator,
    t_arena: *const topo_arena.TopologyArena,
    g_arena: *const geom_arena.GeometryArena,
    solid_id: topo_types.SolidIndex,
    out_mesh: *Mesh,
    env: MathEnv,
) !void {
    _ = allocator;
    _ = t_arena;
    _ = g_arena;
    _ = solid_id;
    _ = out_mesh;
    _ = env;
    // TODO: Implement Constrained Delaunay Triangulation (CDT)
}
