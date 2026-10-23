const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const sketch_circles = @import("sketch_circles.zig");

/// The circles below the sketch the script leaves in `r`.
fn circlesOf(vm: *@import("vm.zig").VM) !sketch_circles.Circles {
    return sketch_circles.collect(testing.allocator, &vm.dag_builder, vm.globals.get("r").?.asCrossSection().dag_idx);
}

test "sketch circles: a circle keeps its centre, radius and points through moves, turns, uniform scales and mirrors" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, "r = circle(r: 2, segments: 8).scale(3, 3).rotate(90).translate(x: 10, y: 5).mirror(0, 1)"));
    var circles = try circlesOf(&vm);
    defer circles.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), circles.items.len);
    const c = circles.items[0];
    try testing.expectApproxEqAbs(@as(f64, 6), c.radius, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10), c.center[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -5), c.center[1], 1e-12); // mirrored across x
    try testing.expectEqual(@as(usize, 8), c.points.len);
    // The first point was (2, 0): scaled to (6, 0), turned to (0, 6), moved to (10, 11), mirrored to (10, -11)
    try testing.expectApproxEqAbs(@as(f64, 10), c.points[0][0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -11), c.points[0][1], 1e-12);
    for (c.points) |p| try testing.expectApproxEqAbs(@as(f64, 6), std.math.hypot(p[0] - c.center[0], p[1] - c.center[1]), 1e-12);
}

test "sketch circles: a closed path's arcs are circles, each with the points it was drawn with" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, "r = (line([0, 0], [10, 0]) + arc(center: [10, 5], r: 5, start: -90, sweep: 180) + polyline([[10, 10], [0, 10]])).close.translate(x: 1)"));
    var circles = try circlesOf(&vm);
    defer circles.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), circles.items.len);
    const c = circles.items[0];
    try testing.expect(!c.closed);
    try testing.expectApproxEqAbs(@as(f64, 5), c.radius, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 11), c.center[0], 1e-12);
    // The arc's points: from (11, 0) round to (11, 10), each on the circle
    try testing.expect(c.points.len >= 3);
    try testing.expectApproxEqAbs(@as(f64, 11), c.points[0][0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), c.points[0][1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10), c.points[c.points.len - 1][1], 1e-12);
    for (c.points) |p| try testing.expectApproxEqAbs(@as(f64, 5), std.math.hypot(p[0] - c.center[0], p[1] - c.center[1]), 1e-12);
}

test "sketch circles: booleans and labels keep both sides' circles, a corner is one, an ellipse or an offset none" {
    var vm = try support.initVm();
    defer vm.deinit();
    const source =
        \\a = circle(r: 1) + circle(r: 1).translate(x: 5)
        \\b = square(10, round_r: 2).named("plate")
        \\r = (a - b).material(color: "#FF0000")
    ;
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    var circles = try circlesOf(&vm);
    defer circles.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), circles.items.len); // two circles and four corners
    var corners: usize = 0;
    for (circles.items) |c| {
        if (c.radius == 2) corners += 1;
    }
    try testing.expectEqual(@as(usize, 4), corners);

    for ([_][]const u8{ "r = circle(r: 1).scale(2, 1)", "r = circle(r: 1).offset(1)", "r = square(3)" }) |none| {
        errdefer std.debug.print("source: {s}\n", .{none});
        var other = try support.initVm();
        defer other.deinit();
        try testing.expectEqual(.ok, try support.runOn(&other, none));
        var found = try circlesOf(&other);
        defer found.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), found.items.len);
    }
}
