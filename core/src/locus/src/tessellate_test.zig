const std = @import("std");
const tessellate = @import("tessellate.zig");
const math = @import("math.zig");

test "Ear Clipping Triangulator" {
    const alloc = std.testing.allocator;

    // A simple L-shaped concave polygon
    const poly = [_]math.Vec2{
        .{ 0, 0 },
        .{ 2, 0 },
        .{ 2, 1 },
        .{ 1, 1 }, // Reflex vertex
        .{ 1, 2 },
        .{ 0, 2 },
    };

    var tris: std.ArrayListUnmanaged([3]u32) = .empty;
    defer tris.deinit(alloc);

    try tessellate.triangulatePolygon(alloc, &poly, &tris);

    try std.testing.expectEqual(@as(usize, 4), tris.items.len);
}
