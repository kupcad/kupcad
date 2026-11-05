//! Checks for tests on triangle meshes read back from exports or taken from the kernel:
//! whether a mesh is closed and consistently oriented, the property every solid KupCAD
//! makes must have. Each edge is shared by exactly two triangles that run along it in
//! opposite directions; an open edge, a third triangle on an edge, a flipped triangle or a
//! degenerate one fails. What "closed" is, is mesh_repair's, which the importers check
//! a file's mesh by: one definition for both.

const std = @import("std");
const mesh_repair = @import("../core/mesh_repair.zig");

pub const MeshError = error{ DegenerateTriangle, OpenEdge, NonManifoldEdge } || std.mem.Allocator.Error;

/// Fails unless `mesh` is closed, consistently oriented surfaces (mesh_repair.check) of
/// triangles with three corners each. Several disjoint closed surfaces pass.
pub fn expectClosed(allocator: std.mem.Allocator, mesh: mesh_repair.Mesh) MeshError!void {
    for (mesh.faces) |t| {
        if (t[0] == t[1] or t[1] == t[2] or t[2] == t[0]) return error.DegenerateTriangle;
    }
    const report = try mesh_repair.check(allocator, mesh);
    if (report.open_edges > 0) return error.OpenEdge;
    // A third triangle on an edge, or a flipped one: two that run an edge the same way
    if (report.shared_edges > 0 or report.turned_edges > 0) return error.NonManifoldEdge;
}

/// A mesh of positions that repeat (three floats per vertex): its points, as many as the
/// vertices, and its triangles, each corner the first vertex at its position.
pub const Welded = struct {
    points: [][3]f64,
    triangles: [][3]u32,

    pub fn mesh(self: Welded) mesh_repair.Mesh {
        return .{ .points = self.points, .faces = self.triangles };
    }

    pub fn deinit(self: Welded, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.triangles);
    }
};

/// `positions` and `indices` welded, so that every distinct position has one index, for
/// meshes that repeat a position under several indices. Caller deinits.
pub fn weld(allocator: std.mem.Allocator, positions: []const f32, indices: []const u32) !Welded {
    var first: std.AutoHashMapUnmanaged([3]u32, u32) = .empty;
    defer first.deinit(allocator);
    const points = try allocator.alloc([3]f64, positions.len / 3);
    errdefer allocator.free(points);
    for (points, 0..) |*p, v| p.* = .{ positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2] };
    const triangles = try allocator.alloc([3]u32, indices.len / 3);
    errdefer allocator.free(triangles);
    for (triangles, 0..) |*t, i| {
        for (t, indices[i * 3 ..][0..3]) |*out, index| {
            const p = positions[index * 3 ..][0..3];
            const key: [3]u32 = .{ @bitCast(p[0]), @bitCast(p[1]), @bitCast(p[2]) };
            const gop = try first.getOrPut(allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = index;
            out.* = gop.value_ptr.*;
        }
    }
    return .{ .points = points, .triangles = triangles };
}
