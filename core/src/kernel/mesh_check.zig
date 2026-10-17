//! Checks for tests on triangle meshes read back from exports or taken from the kernel:
//! whether a mesh is closed and consistently oriented, the property every solid KupCAD
//! makes must have. Each edge is shared by exactly two triangles that run along it in
//! opposite directions; an open edge, a third triangle on an edge, a flipped triangle or a
//! degenerate one fails.

const std = @import("std");

pub const MeshError = error{ DegenerateTriangle, OpenEdge, NonManifoldEdge } || std.mem.Allocator.Error;

/// Fails unless `triangles` (vertex indices, welded: a position has one index) form closed,
/// consistently oriented surfaces. Several disjoint closed surfaces pass.
pub fn expectClosed(allocator: std.mem.Allocator, triangles: []const [3]u32) MeshError!void {
    // Each directed edge, once: a second use of the same direction is a flipped triangle
    // or a third one on the edge.
    var edges: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    defer edges.deinit(allocator);
    try edges.ensureTotalCapacity(allocator, @intCast(triangles.len * 3));
    for (triangles) |t| {
        if (t[0] == t[1] or t[1] == t[2] or t[2] == t[0]) return error.DegenerateTriangle;
        for (0..3) |k| {
            if (edges.getOrPutAssumeCapacity(.{ t[k], t[(k + 1) % 3] }).found_existing) return error.NonManifoldEdge;
        }
    }
    var it = edges.keyIterator();
    while (it.next()) |edge| {
        if (!edges.contains(.{ edge[1], edge[0] })) return error.OpenEdge;
    }
}

/// Indices into `positions` (three floats per vertex) that give every distinct position one
/// index, for meshes that repeat a position under several indices. Caller frees.
pub fn weld(allocator: std.mem.Allocator, positions: []const f32, indices: []const u32) ![][3]u32 {
    var first: std.AutoHashMapUnmanaged([3]u32, u32) = .empty;
    defer first.deinit(allocator);
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
    return triangles;
}
