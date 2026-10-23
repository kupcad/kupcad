const std = @import("std");
const testing = std.testing;
const curves = @import("curves.zig");
const bezier = @import("../../core/bezier.zig");
const geom = @import("../../core/geometry_handle.zig");
const sketch_curves = @import("sketch_curves.zig");
const Circle = sketch_curves.Circle;
const Cubic = sketch_curves.Cubic;

/// Outlines matched against `circles` alone.
fn outlinesOf(contours: geom.Contours, circles: []const Circle, tolerance: f64) ![]@import("drawing.zig").Outline {
    const found = sketch_curves.Curves{ .circles = @constCast(circles), .cubics = &.{} };
    return curves.outlinesOf(testing.allocator, contours, &found, tolerance);
}

/// A circle's `n` points from the +x axis, counter-clockwise, about `center`.
fn circlePoints(center: [2]f64, radius: f64, n: usize) ![][2]f64 {
    const points = try testing.allocator.alloc([2]f64, n);
    for (points, 0..) |*p, i| {
        const ang = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        p.* = .{ center[0] + radius * @cos(ang), center[1] + radius * @sin(ang) };
    }
    return points;
}

fn contoursOf(lists: []const []const [2]f64) !geom.Contours {
    var total: usize = 0;
    for (lists) |l| total += l.len;
    const points = try testing.allocator.alloc([2]f64, total);
    const starts = try testing.allocator.alloc(u32, lists.len + 1);
    var at: usize = 0;
    for (lists, 0..) |l, i| {
        starts[i] = @intCast(at);
        @memcpy(points[at..][0..l.len], l);
        at += l.len;
    }
    starts[lists.len] = @intCast(at);
    return .{ .points = points, .starts = starts };
}

fn freeOutlines(outlines: []@import("drawing.zig").Outline) void {
    for (outlines) |o| testing.allocator.free(o.edges);
    testing.allocator.free(outlines);
}

test "curves: a contour of a circle's points is the circle, two half turns" {
    const points = try circlePoints(.{ 1, 2 }, 3, 12);
    defer testing.allocator.free(points);
    const circles = [_]Circle{.{ .center = .{ 1, 2 }, .radius = 3, .points = points, .closed = true }};
    const contours = try contoursOf(&.{points});
    defer contours.deinit(testing.allocator);
    const outlines = try outlinesOf(contours, &circles, 1e-6);
    defer freeOutlines(outlines);
    try testing.expectEqual(@as(usize, 1), outlines.len);
    const o = outlines[0];
    try testing.expectEqual(@as(usize, 2), o.edges.len);
    try testing.expectEqual(points[0], o.start);
    try testing.expectEqual([2]f64{ -2, 2 }, o.edges[0].to); // the antipode of (4, 2)
    try testing.expectEqual(points[0], o.edges[1].to);
    for (o.edges) |e| {
        try testing.expectEqual(@as(f64, 3), e.arc.?.radius);
        try testing.expect(e.ccw and !e.large());
        try testing.expectEqual(std.math.pi, e.angle);
    }
}

test "curves: a run of chords is one arc, a cut chord a line, a hole's arc runs clockwise" {
    // A circle of 8 points with the two top points replaced by a flat cut (a boolean's
    // crossing points lie on the chords, not the circle), traversed clockwise as a hole
    const full = try circlePoints(.{ 0, 0 }, 2, 8);
    defer testing.allocator.free(full);
    var cut: [8][2]f64 = full[0..8].*;
    cut[2] = .{ 0.5, 1.9 }; // not points of the circle
    cut[3] = .{ -0.5, 1.9 };
    var clockwise: [8][2]f64 = undefined;
    for (0..8) |i| clockwise[i] = cut[(8 - i) % 8];
    const circles = [_]Circle{.{ .center = .{ 0, 0 }, .radius = 2, .points = full, .closed = true }};
    const contours = try contoursOf(&.{&clockwise});
    defer contours.deinit(testing.allocator);
    const outlines = try outlinesOf(contours, &circles, 1e-6);
    defer freeOutlines(outlines);
    const o = outlines[0];
    // The run of 5 chords from point 1 round to point 4 (through 0, 7, 6, 5), more than
    // half a turn, then the lines 4→cut, cut→cut, cut→1
    var arc_edges: usize = 0;
    var lines: usize = 0;
    for (o.edges) |e| {
        if (e.arc) |arc| {
            arc_edges += 1;
            try testing.expectEqual(@as(f64, 2), arc.radius);
            try testing.expect(!e.ccw); // a hole runs clockwise
            try testing.expect(e.large()); // 5 of 8 chords: 225 degrees
            try testing.expectApproxEqAbs(5.0 * std.math.pi / 4.0, e.angle, 1e-12);
            try testing.expectEqual(full[4], e.to);
        } else lines += 1;
    }
    try testing.expectEqual(@as(usize, 1), arc_edges);
    try testing.expectEqual(@as(usize, 3), lines);
    try testing.expectEqual(@as(usize, 4), o.edges.len);
    // The outline starts where a run starts: at point 4, with the lines
    try testing.expectEqual(full[4], o.start);
}

test "curves: a corner's quarter circle doesn't join its last point to its first" {
    // A chord across a corner's arc (its ends joined straight, the arc cut away) is a line
    const quarter = try circlePoints(.{ 0, 0 }, 1, 8);
    defer testing.allocator.free(quarter);
    const corner = [_]Circle{.{ .center = .{ 0, 0 }, .radius = 1, .points = quarter[0..3], .closed = false }};
    const shape = [_][2]f64{ quarter[0], quarter[1], quarter[2], .{ -1, -1 } };
    const contours = try contoursOf(&.{&shape});
    defer contours.deinit(testing.allocator);
    const outlines = try outlinesOf(contours, &corner, 1e-6);
    defer freeOutlines(outlines);
    // The arc of two chords (a quarter turn, not large), then two lines
    try testing.expectEqual(@as(usize, 3), outlines[0].edges.len);
    try testing.expect(outlines[0].edges[0].arc != null and !outlines[0].edges[0].large());
    try testing.expectApproxEqAbs(std.math.pi / 2.0, outlines[0].edges[0].angle, 1e-12);
    try testing.expect(outlines[0].edges[1].arc == null and outlines[0].edges[2].arc == null);
}

test "curves: a point on the line between its neighbours is dropped, so a slice's chords match" {
    // A slice crosses a cylinder's side triangles mid-chord, leaving a point on each chord
    const full = try circlePoints(.{ 0, 0 }, 2, 8);
    defer testing.allocator.free(full);
    var with_midpoints: [16][2]f64 = undefined;
    for (0..8) |i| {
        const next = full[(i + 1) % 8];
        with_midpoints[2 * i] = full[i];
        with_midpoints[2 * i + 1] = .{ (full[i][0] + next[0]) / 2, (full[i][1] + next[1]) / 2 };
    }
    const circles = [_]Circle{.{ .center = .{ 0, 0 }, .radius = 2, .points = full, .closed = true }};
    const contours = try contoursOf(&.{&with_midpoints});
    defer contours.deinit(testing.allocator);
    const outlines = try outlinesOf(contours, &circles, 1e-6);
    defer freeOutlines(outlines);
    try testing.expectEqual(@as(usize, 2), outlines[0].edges.len); // the circle, as two half turns
    try testing.expect(outlines[0].edges[0].arc != null);
}

test "curves: with no circle to match, every edge is a line" {
    const square = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    const contours = try contoursOf(&.{&square});
    defer contours.deinit(testing.allocator);
    const outlines = try outlinesOf(contours, &.{}, 1e-6);
    defer freeOutlines(outlines);
    try testing.expectEqual(@as(usize, 4), outlines[0].edges.len);
    for (outlines[0].edges) |e| try testing.expect(e.arc == null);
    try testing.expectEqual(square[0], outlines[0].start);
    try testing.expectEqual(square[0], outlines[0].edges[3].to);
}

/// A cubic from `p0` to `p3`, flattened finely (the points it became, `p0` first).
fn flattened(p0: [2]f64, cubic: bezier.Cubic, p3: [2]f64, tolerance_sq: f64) ![][2]f64 {
    var points: std.ArrayList([2]f64) = .empty;
    errdefer points.deinit(testing.allocator);
    try points.append(testing.allocator, p0);
    try bezier.flattenCubic(testing.allocator, &points, p0, cubic.c1, cubic.c2, p3, tolerance_sq);
    return points.toOwnedSlice(testing.allocator);
}

test "curves: a run of all a cubic's pieces is the cubic, run back its reverse; cut short, lines" {
    const control = bezier.Cubic{ .c1 = .{ 0, 3 }, .c2 = .{ 4, 3 } };
    const points = try flattened(.{ 0, 0 }, control, .{ 4, 0 }, 0.01);
    defer testing.allocator.free(points);
    try testing.expect(points.len >= 4);
    const cubics = [_]Cubic{.{ .control = control, .points = points }};
    const found = sketch_curves.Curves{ .circles = &.{}, .cubics = @constCast(&cubics) };

    // The curve's points, closed by a line back from its end to its start
    var contours = try contoursOf(&.{points});
    defer contours.deinit(testing.allocator);
    const outlines = try curves.outlinesOf(testing.allocator, contours, &found, 1e-6);
    defer freeOutlines(outlines);
    try testing.expectEqual(@as(usize, 2), outlines[0].edges.len);
    try testing.expectEqual(control, outlines[0].edges[0].cubic.?);
    try testing.expectEqual([2]f64{ 4, 0 }, outlines[0].edges[0].to);
    try testing.expect(outlines[0].edges[1].isLine());

    // The same contour the other way round: the cubic run backwards
    const backwards = try testing.allocator.alloc([2]f64, points.len);
    defer testing.allocator.free(backwards);
    for (points, 0..) |p, i| backwards[points.len - 1 - i] = p;
    var back_contours = try contoursOf(&.{backwards});
    defer back_contours.deinit(testing.allocator);
    const back = try curves.outlinesOf(testing.allocator, back_contours, &found, 1e-6);
    defer freeOutlines(back);
    try testing.expectEqual(@as(usize, 2), back[0].edges.len);
    try testing.expectEqual(control.reversed(), back[0].edges[0].cubic.?);
    try testing.expectEqual([2]f64{ 0, 0 }, back[0].edges[0].to);

    // With its last point cut off (a boolean's crossing elsewhere): a part of a cubic is
    // no cubic, so its pieces stay lines
    var cut_contours = try contoursOf(&.{points[0 .. points.len - 1]});
    defer cut_contours.deinit(testing.allocator);
    const cut = try curves.outlinesOf(testing.allocator, cut_contours, &found, 1e-6);
    defer freeOutlines(cut);
    try testing.expectEqual(points.len - 1, cut[0].edges.len);
    for (cut[0].edges) |e| try testing.expect(e.isLine());
}

test "curves: a curve's point is kept even where it lies on the line between its neighbours" {
    // A nearly straight cubic: its middle point is within the tolerance of the chord, but
    // dropping it would leave an edge no piece of the curve
    const control = bezier.Cubic{ .c1 = .{ 1, 0.002 }, .c2 = .{ 3, 0.002 } };
    const points = try flattened(.{ 0, 0 }, control, .{ 4, 0 }, 1e-12);
    defer testing.allocator.free(points);
    try testing.expect(points.len >= 3);
    const cubics = [_]Cubic{.{ .control = control, .points = points }};
    const found = sketch_curves.Curves{ .circles = &.{}, .cubics = @constCast(&cubics) };
    var contours = try contoursOf(&.{points});
    defer contours.deinit(testing.allocator);
    const outlines = try curves.outlinesOf(testing.allocator, contours, &found, 0.01);
    defer freeOutlines(outlines);
    try testing.expectEqual(@as(usize, 2), outlines[0].edges.len);
    try testing.expectEqual(control, outlines[0].edges[0].cubic.?);
}
