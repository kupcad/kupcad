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

test "path: a path leaves its end along its last segment, and a tangent arc turns from there" {
    // A line's way, an arc's tangent either way round, a cubic's from its last control
    try testing.expectEqual([2]f64{ 0, 1 }, path.endTangent(.{ 0, 0 }, &.{.{ .to = .{ 0, 5 } }}).?);
    const quarter = path.arcByAngles(.{ 0, 0 }, 5, 0, 90); // ends at (0, 5) going -x
    const left = path.endTangent(.{ 5, 0 }, &.{quarter}).?;
    try testing.expectApproxEqAbs(@as(f64, -1), left[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), left[1], 1e-12);
    const back = path.arcByAngles(.{ 0, 0 }, 5, 90, 0); // ends at (5, 0) going -y
    const down = path.endTangent(.{ 0, 5 }, &.{back}).?;
    try testing.expectApproxEqAbs(@as(f64, 0), down[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), down[1], 1e-12);
    try testing.expectEqual([2]f64{ 1, 0 }, path.endTangent(.{ 0, 0 }, &.{.{ .to = .{ 3, 1 }, .cubic = .{ .c1 = .{ 0, 1 }, .c2 = .{ 2, 1 } } }}).?);
    try testing.expectEqual(@as(?[2]f64, null), path.endTangent(.{ 0, 0 }, &.{}));

    // Up from (10, 5), on to (5, 10): the quarter circle about (5, 5), turning left
    const arc = path.tangentArc(.{ 10, 5 }, .{ 0, 1 }, .{ 5, 10 }, 1e-6).?;
    try testing.expectEqual([2]f64{ 5, 5 }, arc.arc.?.center);
    try testing.expectEqual(@as(f64, 5), arc.arc.?.radius);
    try testing.expect(arc.ccw);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, arc.angle, 1e-12);
    // To the right it turns clockwise; along the line, no circle touches it
    try testing.expect(!path.tangentArc(.{ 10, 5 }, .{ 0, 1 }, .{ 15, 10 }, 1e-6).?.ccw);
    try testing.expectEqual(@as(?path.Segment, null), path.tangentArc(.{ 0, 0 }, .{ 1, 0 }, .{ 7, 0 }, 1e-6));
}

test "path: a closed path's signed area counts its arcs' bulges, and its reverse runs the other way" {
    // A half disc of radius 2, counter-clockwise: over the top, then the line back
    const half = [_]path.Segment{path.arcByAngles(.{ 0, 0 }, 2, 0, 180)};
    try testing.expectApproxEqAbs(2 * std.math.pi, path.signedArea(.{ 2, 0 }, &half), 1e-12);
    // Back from (-2, 0) to (2, 0) the same way over: clockwise, the same area negated
    const back = try path.reversed(testing.allocator, .{ 2, 0 }, &half);
    defer testing.allocator.free(back);
    try testing.expectEqual([2]f64{ 2, 0 }, back[0].to);
    try testing.expect(!back[0].ccw);
    try testing.expectApproxEqAbs(-2 * std.math.pi, path.signedArea(path.endOf(.{ 2, 0 }, &half), back), 1e-12);
    // A unit square clockwise, and the order of its lines turned around
    const square = [_]path.Segment{ .{ .to = .{ 0, 1 } }, .{ .to = .{ 1, 1 } }, .{ .to = .{ 1, 0 } } };
    try testing.expectEqual(@as(f64, -1), path.signedArea(.{ 0, 0 }, &square));
    const ccw = try path.reversed(testing.allocator, .{ 0, 0 }, &square);
    defer testing.allocator.free(ccw);
    try testing.expectEqualSlices(path.Segment, &.{ .{ .to = .{ 1, 1 } }, .{ .to = .{ 0, 1 } }, .{ .to = .{ 0, 0 } } }, ccw);
    try testing.expectEqual(@as(f64, 1), path.signedArea(.{ 1, 0 }, ccw));
}

test "path: a point is inside a closed path by the even-odd rule, exactly on its arcs" {
    const half = [_]path.Segment{path.arcByAngles(.{ 0, 0 }, 2, 0, 180)};
    // Just inside and just outside the arc, below the line, and near the arc's low end
    try testing.expect(path.encloses(.{ 2, 0 }, &half, .{ 0, 1.999 }));
    try testing.expect(!path.encloses(.{ 2, 0 }, &half, .{ 0, 2.001 }));
    try testing.expect(!path.encloses(.{ 2, 0 }, &half, .{ 0, -0.1 }));
    try testing.expect(path.encloses(.{ 2, 0 }, &half, .{ 1.9, 0.5 }));
    try testing.expect(!path.encloses(.{ 2, 0 }, &half, .{ 1.95, 0.5 }));
    // Clockwise, the same
    const back = try path.reversed(testing.allocator, .{ 2, 0 }, &half);
    defer testing.allocator.free(back);
    try testing.expect(path.encloses(.{ -2, 0 }, back, .{ 1.9, 0.5 }));
    try testing.expect(!path.encloses(.{ -2, 0 }, back, .{ 1.95, 0.5 }));
    // A circle of two halves: its centre, where the ray meets the joint of the halves, is in
    const circle = [_]path.Segment{ path.arcByAngles(.{ 0, 0 }, 2, 0, 180), path.arcByAngles(.{ 0, 0 }, 2, 180, 360) };
    try testing.expect(path.encloses(.{ 2, 0 }, &circle, .{ 0, 0 }));
    try testing.expect(path.encloses(.{ 2, 0 }, &circle, .{ -1.99, 0 }));
    try testing.expect(!path.encloses(.{ 2, 0 }, &circle, .{ 2.01, 0 }));
    // A unit square's lines, by the same rule
    const square = [_]path.Segment{ .{ .to = .{ 1, 0 } }, .{ .to = .{ 1, 1 } }, .{ .to = .{ 0, 1 } } };
    try testing.expect(path.encloses(.{ 0, 0 }, &square, .{ 0.5, 0.5 }));
    try testing.expect(!path.encloses(.{ 0, 0 }, &square, .{ 1.5, 0.5 }));
}
