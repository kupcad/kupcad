//! Every numeric input of the 2D kernel at its extremes (not a number, infinite, the
//! largest and smallest doubles, huge, tiny, zero, negative), on fixed sheets: each is a
//! clean refusal (an error with a finding) or a valid result the checker grades, never a
//! crash, and nothing leaks (the testing allocator). The values a script would never
//! write are the ones that find the unguarded path.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("../construct/primitives.zig");
const boolean = @import("boolean.zig");
const offset = @import("offset.zig");
const query = @import("query.zig");
const hull = @import("hull.zig");
const Vec2 = vec.Vec2;

const tol = Tolerance.fromZone(1e-5);

const EXTREMES = [_]f64{
    -std.math.inf(f64),      std.math.inf(f64),      std.math.nan(f64),
    -std.math.floatMax(f64), std.math.floatMax(f64), std.math.floatTrueMin(f64),
    -1e15,                   -1e12,                  -1,
    -1e-5,                   -1e-15,                 -0.0,
    0,                       1e-15,                  1e-5,
    2e-5,                    1,                      1e12,
    1e15,
};

/// A result is valid, or the error was a refusal with a finding; out of memory is the
/// harness's own.
fn graded(result: anyerror!Body, diag: *Diagnostics) !void {
    var body = result catch |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expect(diag.first() != null);
        return;
    };
    defer body.deinit();
    var report = try check.run(testing.allocator, &body, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
}

test "parameters: an offset's delta and miter limit at every extreme, with each join" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 4, 4, false, &diag);
    defer sq.deinit();
    for (EXTREMES) |delta| {
        for (std.enums.values(offset.Join)) |join| {
            diag.deinit();
            diag = Diagnostics.init(testing.allocator);
            try graded(offset.offset(testing.allocator, &sq, delta, join, 2, .{}, &diag), &diag);
        }
    }
    for (EXTREMES) |limit| {
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        try graded(offset.offset(testing.allocator, &sq, 1, .miter, limit, .{}, &diag), &diag);
    }
}

test "parameters: a square's sides, a circle's radius and a polygon's coordinates at every extreme" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (EXTREMES) |v| {
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        try graded(primitives.square(testing.allocator, tol, v, 3, false, &diag), &diag);
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        try graded(primitives.circle(testing.allocator, tol, v, &diag), &diag);
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        const ring = [_]Vec2{ .{ 0, 0 }, .{ 3, 0 }, .{ v, 2 } };
        try graded(primitives.polygon(testing.allocator, tol, &ring, &diag), &diag);
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        const rings = [_][]const Vec2{ &.{ .{ 0, 0 }, .{ 3, 0 }, .{ 1, v } }, &.{ .{ 1, 1 }, .{ 2, 1 }, .{ 2, 2 } } };
        try graded(primitives.polygonsEvenOdd(testing.allocator, tol, &rings, &diag), &diag);
    }
}

test "parameters: a boolean, a hull and the queries with an operand or a point at every extreme" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 4, 4, false, &diag);
    defer sq.deinit();
    for (EXTREMES) |v| {
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        const ring = [_]Vec2{ .{ 1, 1 }, .{ v, 1 }, .{ 2, 3 } };
        var other = primitives.polygon(testing.allocator, tol, &ring, &diag) catch |err| {
            if (err == error.OutOfMemory) return err;
            continue;
        };
        defer other.deinit();
        for (std.enums.values(boolean.Op)) |op| {
            diag.deinit();
            diag = Diagnostics.init(testing.allocator);
            try graded(boolean.boolean(testing.allocator, &.{ &sq, &other }, op, .{}, &diag), &diag);
        }
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        try graded(hull.hull(testing.allocator, &.{ &sq, &other }, .{}, &diag), &diag);
    }
    for (EXTREMES) |v| {
        diag.deinit();
        diag = Diagnostics.init(testing.allocator);
        _ = query.contains(&sq, .{ v, 1 }, tol.zone, &diag) catch |err| if (err == error.OutOfMemory) return err;
        _ = query.contains(&sq, .{ 1, 1 }, v, &diag) catch |err| if (err == error.OutOfMemory) return err;
    }
}
