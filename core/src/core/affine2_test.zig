const std = @import("std");
const testing = std.testing;
const affine2 = @import("affine2.zig");

fn expectPoint(expected: [2]f64, actual: [2]f64) !void {
    try testing.expectApproxEqAbs(expected[0], actual[0], 1e-12);
    try testing.expectApproxEqAbs(expected[1], actual[1], 1e-12);
}

test "affine2: a move, a scale, a turn and a mirror place a point as their names say" {
    try expectPoint(.{ 4, 7 }, affine2.apply(affine2.translation(3, 5), .{ 1, 2 }));
    try expectPoint(.{ 2, 6 }, affine2.apply(affine2.scaling(2, 3), .{ 1, 2 }));
    try expectPoint(.{ 0, 1 }, affine2.apply(affine2.rotation(90), .{ 1, 0 }));
    try expectPoint(.{ -1, 0 }, affine2.apply(affine2.rotation(180), .{ 1, 0 }));
    // Across the y axis (normal x), and across the line y = -x (normal (1, 1), any length)
    try expectPoint(.{ -1, 2 }, affine2.apply(affine2.reflection(1, 0), .{ 1, 2 }));
    try expectPoint(.{ 0, -1 }, affine2.apply(affine2.reflection(2, 2), .{ 1, 0 }));
    try expectPoint(.{ 1, 2 }, affine2.apply(affine2.identity, .{ 1, 2 }));
}

test "affine2: compose applies the outer transform after the inner one" {
    // Turned to (0, 1), then moved to (1, 1); the other way round, moved then turned
    try expectPoint(.{ 1, 1 }, affine2.apply(affine2.compose(affine2.translation(1, 0), affine2.rotation(90)), .{ 1, 0 }));
    try expectPoint(.{ 0, 2 }, affine2.apply(affine2.compose(affine2.rotation(90), affine2.translation(1, 0)), .{ 1, 0 }));
}

test "affine2: a similarity's scale, and none for an ellipse or a collapse" {
    try testing.expectApproxEqAbs(@as(f64, 2), affine2.similarityScale(affine2.compose(affine2.rotation(30), affine2.scaling(2, 2))).?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), affine2.similarityScale(affine2.reflection(1, 1)).?, 1e-12);
    try testing.expectEqual(@as(?f64, 1), affine2.similarityScale(affine2.translation(5, 5)));
    try testing.expectEqual(@as(?f64, null), affine2.similarityScale(affine2.scaling(2, 1)));
    try testing.expectEqual(@as(?f64, null), affine2.similarityScale(.{ 1, 0, 1, 1, 0, 0 })); // a shear
    try testing.expectEqual(@as(?f64, null), affine2.similarityScale(affine2.scaling(0, 0)));
}

test "affine2: a point's distance to a segment is to its nearest point, an end or between" {
    const a = [2]f64{ 0, 0 };
    const b = [2]f64{ 4, 0 };
    try testing.expectEqual(@as(f64, 9), affine2.segmentDistanceSq(a, b, .{ 2, 3 }));
    try testing.expectEqual(@as(f64, 0), affine2.segmentDistanceSq(a, b, .{ 1, 0 }));
    try testing.expectEqual(@as(f64, 5), affine2.segmentDistanceSq(a, b, .{ -1, 2 })); // past a
    try testing.expectEqual(@as(f64, 4), affine2.segmentDistanceSq(a, b, .{ 6, 0 })); // past b
    try testing.expectEqual(@as(f64, 2), affine2.segmentDistanceSq(a, a, .{ 1, 1 })); // no length
}
