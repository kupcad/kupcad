const std = @import("std");
const topo_arena = @import("arena.zig");
const geom_arena = @import("../geometry/arena.zig");
const Checkpoint = @import("checkpoint.zig").Checkpoint;

test "Checkpoint: Restores arena state cleanly on transaction rollback" {
    const alloc = std.testing.allocator;
    var t = topo_arena.TopologyArena.init();
    defer t.deinit(alloc);
    var g = geom_arena.GeometryArena.init();
    defer g.deinit(alloc);

    const cp = Checkpoint.save(&t, &g);

    // Simulate speculative allocations
    _ = try g.points.append(alloc, .{ 10.0, 20.0, 30.0 });
    _ = try t.vertices.append(alloc, .{ .point = @enumFromInt(0) });

    try std.testing.expectEqual(@as(usize, 1), t.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), g.points.items.len);

    // Rollback
    Checkpoint.restore(&t, &g, cp);

    try std.testing.expectEqual(@as(usize, 0), t.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 0), g.points.items.len);
}
