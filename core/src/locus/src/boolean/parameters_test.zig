//! Every numeric input of M4's operations at its extremes (not a number, infinite, the
//! largest and smallest doubles, huge, tiny, zero, the zone and twice it), on fixed solids:
//! a cut's normal and offset, a boolean's and a chain's tolerance, and the placements of a
//! boolean's operands (moved, turned and scaled by each extreme first). Each is a clean
//! refusal (an error with a finding) or a result the checker passes to level 2 and the
//! overlap rules pass, never a crash, and nothing leaks (the testing allocator). As
//! sketch/parameters_test.zig does for the 2D kernel.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const transform = @import("../construct/transform.zig");
const overlap = @import("../query/overlap.zig");
const pipeline = @import("pipeline.zig");
const trim = @import("trim.zig");
const helpers = @import("pipeline_test.zig");
const Diagnostics = diagnostics.Diagnostics;
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);

const EXTREMES = [_]f64{
    -std.math.inf(f64),      std.math.inf(f64),      std.math.nan(f64),
    -std.math.floatMax(f64), std.math.floatMax(f64), std.math.floatTrueMin(f64),
    -1e15,                   -1e-15,                 -0.0,
    0,                       1e-15,                  1e-5,
    2e-5,                    1,                      1e15,
};

/// A result passes the checker and the overlap rules, or the error was a refusal with a
/// finding; out of memory is the harness's own.
fn graded(result: anyerror!Body, diag: *Diagnostics) !void {
    var body = result catch |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expect(diag.first() != null);
        return;
    };
    defer body.deinit();
    var report = try check.run(testing.allocator, &body, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| std.debug.print("checker: {f}\n", .{f});
    try testing.expect(report.ok());
    try overlap.check(testing.allocator, &body, .{}, diag);
}

fn fresh(diag: *Diagnostics) void {
    diag.deinit();
    diag.* = Diagnostics.init(testing.allocator);
}

test "parameters: a cut's normal and offset at every extreme" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try helpers.box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    for (EXTREMES) |v| {
        for (0..3) |k| {
            var normal: Vec3 = .{ 0, 0, 1 };
            normal[k] = v;
            fresh(&diag);
            try graded(trim.trimByPlane(testing.allocator, &a, normal, 1, .{}, &diag, null), &diag);
        }
        fresh(&diag);
        try graded(trim.trimByPlane(testing.allocator, &a, .{ 0, 0, 1 }, v, .{}, &diag, null), &diag);
        fresh(&diag);
        try graded(trim.trimByPlane(testing.allocator, &a, .{ 1, 1, 1 }, v, .{}, &diag, null), &diag);
    }
}

test "parameters: a boolean's and a chain's tolerance at every extreme" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try helpers.box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try helpers.box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b.deinit();
    for (EXTREMES) |zone| {
        const given = Tolerance.fromZone(zone);
        for ([_]pipeline.Op{ .@"union", .difference, .intersection }) |op| {
            fresh(&diag);
            try graded(pipeline.boolean(testing.allocator, &a, &b, op, .{ .common = .{ .tolerance = given } }, &diag, null), &diag);
        }
        fresh(&diag);
        try graded(pipeline.chain(testing.allocator, &.{ &a, &b, &a }, .@"union", .{ .common = .{ .tolerance = given } }, &diag, null), &diag);
    }
}

test "parameters: a boolean's operand moved, turned and scaled by every extreme" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try helpers.box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b0 = try helpers.box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer b0.deinit();
    for (EXTREMES) |v| {
        const placements = [_]mat.Affine{
            mat.Affine.translate(.{ v, 0, 0 }),
            mat.Affine.rotate(vec.Z3, v),
            mat.Affine.scaleBy(.{ v, 1, 1 }),
            mat.Affine.scaleBy(.{ v, v, v }),
        };
        for (&placements) |*place| {
            fresh(&diag);
            var b = transform.transform(testing.allocator, &b0, place, .{}, &diag) catch |err| {
                if (err == error.OutOfMemory) return err;
                try testing.expect(diag.first() != null);
                continue;
            };
            defer b.deinit();
            for ([_]pipeline.Op{ .@"union", .difference, .intersection }) |op| {
                fresh(&diag);
                try graded(pipeline.boolean(testing.allocator, &a, &b, op, .{}, &diag, null), &diag);
            }
        }
    }
}
