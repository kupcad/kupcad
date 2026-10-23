const std = @import("std");
const testing = std.testing;
const path = @import("path.zig");
const path_corners = @import("path_corners.zig");

const TOLERANCE = 1e-9;

/// The lines of a path through `points`, back to the first when `closed`.
fn lines(comptime points: []const [2]f64, comptime closed: bool) [points.len - 1 + @intFromBool(closed)]path.Segment {
    var out: [points.len - 1 + @intFromBool(closed)]path.Segment = undefined;
    for (points[1..], 0..) |p, i| out[i] = .{ .to = p };
    if (closed) out[out.len - 1] = .{ .to = points[0] };
    return out;
}

fn expectPoint(expected: [2]f64, actual: [2]f64) !void {
    try testing.expectApproxEqAbs(expected[0], actual[0], 1e-12);
    try testing.expectApproxEqAbs(expected[1], actual[1], 1e-12);
}

fn eased(start: [2]f64, segments: []const path.Segment, closed: bool, how: path_corners.Ease) !path_corners.Eased {
    var failure: path_corners.Failure = undefined;
    return path_corners.ease(testing.allocator, start, segments, closed, how, TOLERANCE, &failure);
}

test "path corners: a closed square's corners rounded are quarter arcs, its last line left to the closing" {
    const square = lines(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, true);
    const round = try eased(.{ 0, 0 }, &square, true, .{ .round = 2 });
    defer round.deinit(testing.allocator);
    // From the corner at the start: up the left side, round it, along the bottom...
    try expectPoint(.{ 0, 2 }, round.start);
    try testing.expectEqual(@as(usize, 7), round.segments.len);
    const first = round.segments[0];
    try expectPoint(.{ 2, 0 }, first.to);
    try expectPoint(.{ 2, 2 }, first.arc.?.center);
    try testing.expectEqual(@as(f64, 2), first.arc.?.radius);
    try testing.expect(first.ccw);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, first.angle, 1e-12);
    try expectPoint(.{ 8, 0 }, round.segments[1].to);
    try testing.expect(round.segments[1].isLine());
    // ...to the last corner's arc, which ends where the left side's line back up starts
    try expectPoint(.{ 0, 8 }, round.segments[6].to);
    try expectPoint(.{ 2, 8 }, round.segments[6].arc.?.center);

    // Cut instead: a line across each corner, 2 back along each side
    const cut = try eased(.{ 0, 0 }, &square, true, .{ .chamfer = 2 });
    defer cut.deinit(testing.allocator);
    try expectPoint(.{ 0, 2 }, cut.start);
    try testing.expectEqual(@as(usize, 7), cut.segments.len);
    for (cut.segments) |segment| try testing.expect(segment.isLine());
    try expectPoint(.{ 2, 0 }, cut.segments[0].to);
    try expectPoint(.{ 8, 0 }, cut.segments[1].to);
}

test "path corners: an open path keeps its ends, rounds left and right turns, and goes on past a straight point" {
    const left = lines(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } }, false);
    const up = try eased(.{ 0, 0 }, &left, false, .{ .round = 3 });
    defer up.deinit(testing.allocator);
    try expectPoint(.{ 0, 0 }, up.start);
    try testing.expectEqual(@as(usize, 3), up.segments.len);
    try expectPoint(.{ 7, 0 }, up.segments[0].to);
    try expectPoint(.{ 7, 3 }, up.segments[1].arc.?.center);
    try testing.expect(up.segments[1].ccw);
    try expectPoint(.{ 10, 3 }, up.segments[1].to);
    try expectPoint(.{ 10, 10 }, up.segments[2].to);

    // Turning right, the arc goes clockwise about a centre on the right
    const right = lines(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, -10 } }, false);
    const down = try eased(.{ 0, 0 }, &right, false, .{ .round = 3 });
    defer down.deinit(testing.allocator);
    try expectPoint(.{ 7, -3 }, down.segments[1].arc.?.center);
    try testing.expect(!down.segments[1].ccw);

    // No corner where the path goes on straight
    const straight = lines(&.{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 } }, false);
    const same = try eased(.{ 0, 0 }, &straight, false, .{ .round = 3 });
    defer same.deinit(testing.allocator);
    try testing.expectEqualSlices(path.Segment, &straight, same.segments);
}

fn distance(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

test "path corners: a corner beside an arc is rounded by the arc touching both, the arc giving up its sweep" {
    // Along x to (10, 0), then a quarter of the circle of 5 about (15, 0) down to (15, -5):
    // a right turn, away from the arc's centre
    const hook = [_]path.Segment{ .{ .to = .{ 10, 0 } }, .{ .to = .{ 15, -5 }, .arc = .{ .center = .{ 15, 0 }, .radius = 5 }, .ccw = true, .angle = std.math.pi / 2.0 } };
    const round = try eased(.{ 0, 0 }, &hook, false, .{ .round = 1 });
    defer round.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), round.segments.len);
    // The fillet's centre is 1 below the line and 5 + 1 from the arc's
    const x = 15 - @sqrt(35.0);
    try expectPoint(.{ x, 0 }, round.segments[0].to);
    const fillet = round.segments[1];
    try expectPoint(.{ x, -1 }, fillet.arc.?.center);
    try testing.expect(!fillet.ccw);
    try testing.expectApproxEqAbs(@as(f64, 5), distance(fillet.to, .{ 15, 0 }), 1e-12);
    // The rest of the arc, from where the fillet leaves it to where it ended
    const rest = round.segments[2];
    try expectPoint(.{ 15, -5 }, rest.to);
    try testing.expectApproxEqAbs(path.sweep(.{ 15, 0 }, fillet.to, rest.to, true), rest.angle, 1e-12);
    try testing.expectApproxEqAbs(path.sweep(fillet.arc.?.center, round.segments[0].to, fillet.to, false), fillet.angle, 1e-12);

    // Cut instead, 1 back along the line and 1 round the arc
    const cut = try eased(.{ 0, 0 }, &hook, false, .{ .chamfer = 1 });
    defer cut.deinit(testing.allocator);
    try expectPoint(.{ 9, 0 }, cut.segments[0].to);
    try expectPoint(.{ 15 - 5 * @cos(0.2), -5 * @sin(0.2) }, cut.segments[1].to);
    try testing.expectApproxEqAbs(std.math.pi / 2.0 - 0.2, cut.segments[2].angle, 1e-12);

    // A pointed arch: two arcs of 10 turning right meet at its top; rounded, the fillet's
    // centre is where their circles shrunk by 1 meet, and the arch stays symmetric
    const top = [2]f64{ 0, @sqrt(75.0) };
    const arch = [_]path.Segment{
        .{ .to = top, .arc = .{ .center = .{ 5, 0 }, .radius = 10 }, .ccw = false, .angle = path.sweep(.{ 5, 0 }, .{ -5, 0 }, top, false) },
        .{ .to = .{ 5, 0 }, .arc = .{ .center = .{ -5, 0 }, .radius = 10 }, .ccw = false, .angle = path.sweep(.{ -5, 0 }, top, .{ 5, 0 }, false) },
    };
    const pointed = try eased(.{ -5, 0 }, &arch, false, .{ .round = 1 });
    defer pointed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), pointed.segments.len);
    try expectPoint(.{ 0, @sqrt(56.0) }, pointed.segments[1].arc.?.center);
    try testing.expectApproxEqAbs(-pointed.segments[0].to[0], pointed.segments[1].to[0], 1e-12);
    try testing.expectApproxEqAbs(pointed.segments[0].angle, pointed.segments[2].angle, 1e-12);

    // A fillet wider than the arcs that turn its way can't touch them
    var failure: path_corners.Failure = undefined;
    try testing.expectError(error.CornerFailed, path_corners.ease(testing.allocator, .{ -5, 0 }, &arch, false, .{ .round = 12 }, TOLERANCE, &failure));
    try testing.expectEqual(path_corners.Failure{ .no_fit = 1 }, failure);
}

test "path corners: a joint where an arc goes on smoothly stays, and a side the corners use up is left out" {
    // A line, a half circle and a line: each joint goes on along the same tangent
    const hook = [_]path.Segment{ .{ .to = .{ 10, 0 } }, path.arcByAngles(.{ 10, 5 }, 5, -90, 90), .{ .to = .{ 0, 10 } } };
    const same = try eased(.{ 0, 0 }, &hook, false, .{ .round = 1 });
    defer same.deinit(testing.allocator);
    try testing.expectEqualSlices(path.Segment, &hook, same.segments);

    // A square of 4 rounded by 2 is a circle: four quarter arcs, no sides left
    const square = lines(&.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } }, true);
    const circle = try eased(.{ 0, 0 }, &square, true, .{ .round = 2 });
    defer circle.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), circle.segments.len);
    for (circle.segments) |segment| try expectPoint(.{ 2, 2 }, segment.arc.?.center);
}

test "path corners: a path that doubles back, or a side too short for its corners, says where" {
    var failure: path_corners.Failure = undefined;
    const back = lines(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 5, 0 } }, false);
    try testing.expectError(error.CornerFailed, path_corners.ease(testing.allocator, .{ 0, 0 }, &back, false, .{ .round = 1 }, TOLERANCE, &failure));
    try testing.expectEqual(path_corners.Failure{ .doubles_back = 1 }, failure);
    try testing.expectError(error.CornerFailed, path_corners.ease(testing.allocator, .{ 0, 0 }, &back, false, .{ .chamfer = 1 }, TOLERANCE, &failure));

    // The corner at point 1 takes 3 from the first side, which is 2 long
    const short = lines(&.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 10 } }, false);
    try testing.expectError(error.CornerFailed, path_corners.ease(testing.allocator, .{ 0, 0 }, &short, false, .{ .round = 3 }, TOLERANCE, &failure));
    try testing.expectEqual(@as(usize, 0), failure.too_short.from);
    try testing.expectEqual(@as(f64, 2), failure.too_short.length);
    try testing.expectApproxEqAbs(@as(f64, 3), failure.too_short.needed, 1e-12);
    // Closed, a side's two corners share it: 3 + 3 of a side of 5
    const square = lines(&.{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 5 }, .{ 0, 5 } }, true);
    try testing.expectError(error.CornerFailed, path_corners.ease(testing.allocator, .{ 0, 0 }, &square, true, .{ .chamfer = 3 }, TOLERANCE, &failure));
    try testing.expectEqual(@as(f64, 6), failure.too_short.needed);
}
