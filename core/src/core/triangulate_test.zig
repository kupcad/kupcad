const std = @import("std");
const testing = std.testing;
const triangulate = @import("triangulate.zig");
const vec3 = @import("vec3.zig");

/// The triangles of the face `corners` of `points`, and that each turns as the face does
/// (its normal along `normal`) and that together they cover `area`.
fn expectTriangles(points: []const [3]f64, corners: []const u32, normal: [3]f64, area: f64, count: usize) !void {
    var out: std.ArrayList([3]u32) = .empty;
    defer out.deinit(testing.allocator);
    try triangulate.face(testing.allocator, points, corners, &out);
    try testing.expectEqual(count, out.items.len);
    var total: f64 = 0;
    for (out.items) |t| {
        const n = vec3.cross(vec3.sub(points[t[1]], points[t[0]]), vec3.sub(points[t[2]], points[t[0]]));
        try testing.expect(vec3.dot(n, normal) > 0);
        total += @sqrt(vec3.dot(n, n)) / 2;
    }
    try testing.expectApproxEqAbs(area, total, 1e-12);
}

test "triangulate: a quad is two triangles, a concave face is cut along its inside, both as the face turns" {
    const square = [_][3]f64{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } };
    try expectTriangles(&square, &.{ 0, 1, 2, 3 }, .{ 0, 0, 1 }, 1, 2);
    // The same corners the other way round face down
    try expectTriangles(&square, &.{ 3, 2, 1, 0 }, .{ 0, 0, -1 }, 1, 2);
    // An L of area 3, its notch's corner reflex: no triangle may cover the notch
    const l = [_][3]f64{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 2, 1, 0 }, .{ 1, 1, 0 }, .{ 1, 2, 0 }, .{ 0, 2, 0 } };
    try expectTriangles(&l, &.{ 0, 1, 2, 3, 4, 5 }, .{ 0, 0, 1 }, 3, 4);
    // Upright, off the axes: the plane is the face's own
    const tilted = [_][3]f64{ .{ 0, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, .{ 0, 0, 1 } };
    try expectTriangles(&tilted, &.{ 0, 1, 2, 3 }, .{ 1, -1, 0 }, std.math.sqrt2, 2);
    // A triangle goes through as it is
    try expectTriangles(&square, &.{ 0, 1, 2 }, .{ 0, 0, 1 }, 0.5, 1);
}

test "triangulate: corners in a line enclose nothing" {
    const line = [_][3]f64{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 2, 0, 0 }, .{ 3, 0, 0 } };
    var out: std.ArrayList([3]u32) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.Degenerate, triangulate.face(testing.allocator, &line, &.{ 0, 1, 2, 3 }, &out));
}
