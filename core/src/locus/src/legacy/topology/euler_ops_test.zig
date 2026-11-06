const std = @import("std");
const types = @import("types.zig");
const topo_arena = @import("arena.zig");
const euler_ops = @import("euler_ops.zig");

test "EulerOps: MEV creates valid edge-vertex pair" {
    const alloc = std.testing.allocator;
    var t = topo_arena.TopologyArena.init();
    defer t.deinit(alloc);

    // Seed initial vertex
    try t.vertices.append(alloc, .{ .point = @fromBackingInt(0) });
    const v0: types.VertexIndex = @fromBackingInt(0);

    const res = try euler_ops.mev(alloc, &t, v0, @fromBackingInt(1), .{ .index = @fromBackingInt(0), .curve_type = .line }, @fromBackingInt(0));

    try std.testing.expectEqual(@as(usize, 2), t.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 2), t.half_edges.items.len);
    try std.testing.expectEqual(v0, t.half_edges.items[@backingInt(res.he_out)].start_vertex);
    try std.testing.expectEqual(res.new_vertex, t.half_edges.items[@backingInt(res.he_in)].start_vertex);
}

test "EulerOps: KEV collapses dead-end valence-1 vertex" {
    const alloc = std.testing.allocator;
    var t = topo_arena.TopologyArena.init();
    defer t.deinit(alloc);

    try t.vertices.append(alloc, .{ .point = @fromBackingInt(0) });
    try t.loops.append(alloc, .{ .face_id = @fromBackingInt(0), .first_half_edge = @fromBackingInt(0) });

    const mev_res = try euler_ops.mev(alloc, &t, @fromBackingInt(0), @fromBackingInt(1), .{ .index = @fromBackingInt(0), .curve_type = .line }, @fromBackingInt(0));

    try euler_ops.kev(&t, mev_res.he_out);

    // The loop's starting edge gracefully reassigned away from killed edges
    try std.testing.expect(t.loops.items[0].first_half_edge != mev_res.he_out);
}
