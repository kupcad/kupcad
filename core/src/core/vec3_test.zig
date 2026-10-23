const std = @import("std");
const testing = std.testing;
const vec3 = @import("vec3.zig");

test "vec3: dot, cross and normalize, a zero vector staying zero" {
    try testing.expectEqual(@as(f64, 32), vec3.dot(.{ 1, 2, 3 }, .{ 4, 5, 6 }));
    try testing.expectEqual(@as(f64, 0), vec3.dot(.{ 1, 0, 0 }, .{ 0, 1, 0 }));
    try testing.expectEqual([3]f64{ 0, 0, 1 }, vec3.cross(.{ 1, 0, 0 }, .{ 0, 1, 0 }));
    try testing.expectEqual([3]f64{ 0, 1, 0 }, vec3.normalize(.{ 0, 5, 0 }));
    try testing.expectEqual([3]f64{ 0, 0, 0 }, vec3.normalize(.{ 0, 0, 0 }));
    // No negative zero: (-5, 0, 0) normalizes to (-1, 0, 0) with plain zeros
    const n = vec3.normalize(.{ 0, -0.0, -5 });
    try testing.expect(!std.math.signbit(n[1]));
}

test "vec3: a triangle's normal follows the right-hand rule, its centroid averages its corners" {
    try testing.expectEqual([3]f64{ 0, 0, 1 }, vec3.triangleNormal(.{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }));
    try testing.expectEqual([3]f64{ 0, 0, -1 }, vec3.triangleNormal(.{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 0 }));
    try testing.expectEqual([3]f64{ 0, 0, 0 }, vec3.triangleNormal(.{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 2, 0, 0 })); // degenerate
    try testing.expectEqual([3]f64{ 0, 2, 3 }, vec3.centroid(.{ -3, 0, 0 }, .{ 3, 0, 0 }, .{ 0, 6, 9 }));
}

test "vec3: a point's distance to a triangle is to its face, an edge or a corner, whichever is nearest" {
    const a = [3]f64{ 0, 0, 0 };
    const b = [3]f64{ 4, 0, 0 };
    const c = [3]f64{ 0, 4, 0 };
    const cases = [_]struct { p: [3]f64, expected: f64 }{
        .{ .p = .{ 1, 1, 3 }, .expected = 9 }, // above the face
        .{ .p = .{ 1, 1, 0 }, .expected = 0 }, // on it
        .{ .p = .{ -2, -2, 0 }, .expected = 8 }, // beyond corner a
        .{ .p = .{ 6, -1, 0 }, .expected = 5 }, // beyond corner b
        .{ .p = .{ 2, -3, 0 }, .expected = 9 }, // beyond edge ab
        .{ .p = .{ -1, 2, 0 }, .expected = 1 }, // beyond edge ac
        .{ .p = .{ 3, 3, 0 }, .expected = 2 }, // beyond edge bc: its nearest point (2, 2)
    };
    for (cases) |case| {
        errdefer std.debug.print("point {any}\n", .{case.p});
        try testing.expectApproxEqAbs(case.expected, vec3.pointTriangleDistanceSq(case.p, a, b, c), 1e-12);
    }
}
