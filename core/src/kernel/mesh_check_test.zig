const std = @import("std");
const testing = std.testing;
const mesh_check = @import("mesh_check.zig");

/// A tetrahedron, its faces wound consistently, and the corners of two (the second 5 along x).
const TETRAHEDRON = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 0, 3, 2 } };
const POINTS = [_][3]f64{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 5, 0, 0 }, .{ 6, 0, 0 }, .{ 5, 1, 0 }, .{ 5, 0, 1 } };

fn expectClosed(faces: []const [3]u32) mesh_check.MeshError!void {
    return mesh_check.expectClosed(testing.allocator, .{ .points = &POINTS, .faces = faces });
}

test "mesh_check: a closed mesh passes, and so do two of them" {
    try expectClosed(&TETRAHEDRON);
    var two: [8][3]u32 = undefined;
    for (&two, 0..) |*t, i| {
        const offset: u32 = if (i < 4) 0 else 4;
        t.* = .{ TETRAHEDRON[i % 4][0] + offset, TETRAHEDRON[i % 4][1] + offset, TETRAHEDRON[i % 4][2] + offset };
    }
    try expectClosed(&two);
}

test "mesh_check: a hole, a flipped face, an extra face and a degenerate one fail" {
    try testing.expectError(error.OpenEdge, expectClosed(TETRAHEDRON[0..3]));

    var flipped = TETRAHEDRON;
    std.mem.swap(u32, &flipped[3][1], &flipped[3][2]);
    try testing.expectError(error.NonManifoldEdge, expectClosed(&flipped));

    try testing.expectError(error.NonManifoldEdge, expectClosed(&(TETRAHEDRON ++ [_][3]u32{TETRAHEDRON[0]})));
    try testing.expectError(error.DegenerateTriangle, expectClosed(&(TETRAHEDRON ++ [_][3]u32{.{ 0, 0, 1 }})));
}

test "mesh_check: weld gives a repeated position its first index" {
    // Vertex 3 repeats vertex 0's position.
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0 };
    const welded = try mesh_check.weld(testing.allocator, &positions, &.{ 0, 1, 2, 3, 2, 1 });
    defer welded.deinit(testing.allocator);
    try testing.expectEqualSlices([3]u32, &.{ .{ 0, 1, 2 }, .{ 0, 2, 1 } }, welded.triangles);
}
