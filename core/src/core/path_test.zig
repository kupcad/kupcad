const std = @import("std");
const testing = std.testing;
const path = @import("path.zig");

test "path: a cubic segment's bounds reach its bend, its length and points follow the curve, a transform moves its controls" {
    // From (0, 0) to (3, 0) with the controls a unit up: the curve peaks at y = 0.75 halfway
    const seg = path.Segment{ .to = .{ 3, 0 }, .cubic = .{ .c1 = .{ 0, 1 }, .c2 = .{ 3, 1 } } };
    try testing.expect(!seg.isLine());
    const box = path.bounds(.{ 0, 0 }, &.{seg});
    try testing.expectEqual([2]f64{ 0, 0 }, box.min);
    try testing.expectApproxEqAbs(@as(f64, 3), box.max[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.75), box.max[1], 1e-12);
    // Longer than its chord, shorter than its control polygon
    const len = seg.length(.{ 0, 0 });
    try testing.expect(len > 3 and len < 5);
    // Drawn as four chords: the start, three points on the curve, the end
    var pts: std.ArrayList([2]f64) = .empty;
    defer pts.deinit(testing.allocator);
    var ranges: [1]path.Range = undefined;
    try path.appendPoints(testing.allocator, &pts, .{ 0, 0 }, &.{seg}, &.{4}, &ranges);
    try testing.expectEqual(@as(usize, 5), pts.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1.5), pts.items[2][0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.75), pts.items[2][1], 1e-12);
    try testing.expectEqual(path.Range{ .first = 1, .count = 4 }, ranges[0]);
    // Scaled unevenly and mirrored across x: the controls go with it, still a cubic
    const moved = seg.transformed(.{ 2, 0, 0, -1, 1, 0 });
    try testing.expectEqual([2]f64{ 7, 0 }, moved.to);
    try testing.expectEqual([2]f64{ 1, -1 }, moved.cubic.?.c1);
    try testing.expectEqual([2]f64{ 7, -1 }, moved.cubic.?.c2);
}

test "path: a line's length is its chord's, an arc's its radius times its angle" {
    const line = path.Segment{ .to = .{ 3, 4 } };
    try testing.expect(line.isLine());
    try testing.expectEqual(@as(f64, 5), line.length(.{ 0, 0 }));
    const quarter = path.arcByAngles(.{ 0, 0 }, 2, 0, 90);
    try testing.expectApproxEqAbs(std.math.pi, quarter.length(.{ 2, 0 }), 1e-12);
}
