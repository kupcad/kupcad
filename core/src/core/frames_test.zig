const std = @import("std");
const testing = std.testing;
const frames = @import("frames.zig");

fn expectVec(expected: [3]f64, actual: [3]f64) !void {
    for (expected, actual) |e, a| try testing.expectApproxEqAbs(e, a, 1e-9);
}

/// Each leg's frame, twisted along it and turned through the corner after it, is the next
/// leg's frame; a closed polyline's last comes round to its first.
fn expectCarried(points: []const [3]f64, legs: []const frames.Leg, closed: bool) !void {
    for (legs, 0..) |leg, k| {
        const next = if (k + 1 < legs.len) k + 1 else if (closed) 0 else break;
        const t = frames.direction(points[k], points[k + 1]);
        const carried = frames.turnedAt(leg.frame.turned(t, leg.twist), t, frames.direction(points[next], points[next + 1]));
        errdefer std.debug.print("leg {d} to {d}\n", .{ k, next });
        try expectVec(legs[next].frame.u, carried.u);
        try expectVec(legs[next].frame.v, carried.v);
    }
}

test "frames: a path starts with its profile's y up, or along y for a path straight up" {
    const flat = frames.Frame.along(.{ 1, 0, 0 });
    try expectVec(.{ 0, 1, 0 }, flat.u);
    try expectVec(.{ 0, 0, 1 }, flat.v);
    const up = frames.Frame.along(.{ 0, 0, 1 });
    try expectVec(.{ 1, 0, 0 }, up.u);
    try expectVec(.{ 0, 1, 0 }, up.v);
}

test "frames: a corner turns the frame by its bend, so the profile doesn't twist" {
    // Along x, then up: the profile's x (left, y) stays, its y (up) turns back along -x
    const points = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 0, 10 } };
    const legs = try frames.legs(testing.allocator, &points, false);
    defer testing.allocator.free(legs);
    try expectVec(.{ 0, 1, 0 }, legs[1].frame.u);
    try expectVec(.{ -1, 0, 0 }, legs[1].frame.v);
    try testing.expectEqual(@as(f64, 0), legs[1].twist);
    try expectCarried(&points, legs, false);
}

test "frames: a closed loop comes back to its start, twisted evenly along it when it isn't flat" {
    // A flat square: no twist needed
    const square = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 0, 0, 0 } };
    const flat = try frames.legs(testing.allocator, &square, true);
    defer testing.allocator.free(flat);
    for (flat) |leg| try testing.expectApproxEqAbs(@as(f64, 0), leg.twist, 1e-12);
    try expectCarried(&square, flat, true);

    // A saddle: up and down at alternate corners. Carried alone, the frame comes back turned;
    // twisted, it meets itself, each leg by its share of the length
    const saddle = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 5 }, .{ 10, 10, 0 }, .{ 0, 15, 5 }, .{ 0, 0, 0 } };
    const legs = try frames.legs(testing.allocator, &saddle, true);
    defer testing.allocator.free(legs);
    try expectCarried(&saddle, legs, true);
    var total: f64 = 0;
    for (legs, 0..) |leg, k| {
        total += leg.twist;
        const per_length = leg.twist / std.math.sqrt(frames.distanceSq(saddle[k], saddle[k + 1]));
        try testing.expectApproxEqAbs(legs[0].twist / std.math.sqrt(frames.distanceSq(saddle[0], saddle[1])), per_length, 1e-12);
    }
    try testing.expect(@abs(total) > 0.01);
}

test "frames: a path that doubles back turns about the profile's y" {
    const bend = frames.bendAt(.{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 });
    try expectVec(.{ 0, 0, 1 }, bend.axis);
    try testing.expectApproxEqAbs(std.math.pi, bend.angle, 1e-12);
    try testing.expectEqual(@as(f64, 0), frames.bendAt(.{ 1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 }).angle);
}
