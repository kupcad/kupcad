const std = @import("std");
const math_env = @import("../math_env.zig");
const geom_arena = @import("arena.zig");
const Interner = @import("interning.zig").Interner;

test "Interning: Deduplicates identical points within MathEnv tolerance" {
    const alloc = std.testing.allocator;
    var g = geom_arena.GeometryArena.init();
    defer g.deinit(alloc);

    const env = math_env.MathEnv.init(.{ .vertex_tolerance = 1e-4 });

    const p1 = try Interner.getOrInsertPoint(alloc, &g, .{ 1.0, 2.0, 3.0 }, env);
    const p2 = try Interner.getOrInsertPoint(alloc, &g, .{ 1.00001, 2.00001, 3.00001 }, env);

    try std.testing.expectEqual(p1, p2);
    try std.testing.expectEqual(@as(usize, 1), g.points.items.len);
}
