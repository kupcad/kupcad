//! A body's parts: one box, two boxes apart, a hollow box with a box in its cavity (the
//! void stays with its solid), solids nested two deep, the empty body.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("primitives.zig");
const transform = @import("transform.zig");
const mass = @import("../measure/mass.zig");
const pipeline = @import("../boolean/pipeline.zig");
const decompose = @import("decompose.zig");
const Diagnostics = diagnostics.Diagnostics;
const Vec3 = vec.Vec3;

const tol = Tolerance.fromZone(1e-5);
const CLOSE = 1e-9;

fn box(lo: Vec3, hi: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var unit = try primitives.box(testing.allocator, tol, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2], false, &diag);
    defer unit.deinit();
    return transform.transform(testing.allocator, &unit, &mat.Affine.translate(lo), .{}, &diag);
}

fn combine(a: *const Body, b: *const Body, op: pipeline.Op) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null);
}

/// The parts of `body`, each checked, with their volumes (in increasing order) and shell
/// counts.
fn partsOf(body: *const Body, volumes: []const f64, shells: []const usize) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const parts = try decompose.decompose(testing.allocator, body, .{}, &diag);
    defer {
        for (parts) |*p| p.deinit();
        testing.allocator.free(parts);
    }
    try testing.expectEqual(volumes.len, parts.len);
    const Order = struct {
        fn lessThan(_: void, x: Body, y: Body) bool {
            var d = Diagnostics.init(testing.allocator);
            defer d.deinit();
            const vx = (mass.mass(&x, .{}, &d) catch unreachable).volume;
            const vy = (mass.mass(&y, .{}, &d) catch unreachable).volume;
            return vx < vy;
        }
    };
    std.mem.sort(Body, parts, {}, Order.lessThan);
    for (parts, volumes, shells) |*p, v, s| {
        var report = try check.run(testing.allocator, p, .global);
        defer report.deinit(testing.allocator);
        if (report.first()) |f| std.debug.print("checker: {f}\n", .{f});
        try testing.expect(report.ok());
        try testing.expectApproxEqAbs(v, (try mass.mass(p, .{}, &diag)).volume, CLOSE);
        try testing.expectEqual(s, p.counts().shells);
    }
}

test "decompose: one box is one part; two apart are two" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    try partsOf(&a, &.{1}, &.{1});
    var b = try box(.{ 3, 0, 0 }, .{ 5, 1, 1 });
    defer b.deinit();
    var both = try combine(&a, &b, .@"union");
    defer both.deinit();
    try partsOf(&both, &.{ 1, 2 }, &.{ 1, 1 });
    var empty = Body.empty(testing.allocator, tol);
    defer empty.deinit();
    try partsOf(&empty, &.{}, &.{});
}

test "decompose: a void stays with the solid around it, a solid in a cavity is a part, nested two deep" {
    var outer = try box(.{ 0, 0, 0 }, .{ 10, 10, 10 });
    defer outer.deinit();
    var cavity = try box(.{ 1, 1, 1 }, .{ 9, 9, 9 });
    defer cavity.deinit();
    var hollow = try combine(&outer, &cavity, .difference);
    defer hollow.deinit();
    try partsOf(&hollow, &.{1000 - 512}, &.{2});
    // A hollow box in the cavity: four shells, two parts of two shells each
    var inner = try box(.{ 2, 2, 2 }, .{ 8, 8, 8 });
    defer inner.deinit();
    var core = try box(.{ 3, 3, 3 }, .{ 7, 7, 7 });
    defer core.deinit();
    var inner_hollow = try combine(&inner, &core, .difference);
    defer inner_hollow.deinit();
    var nested = try combine(&hollow, &inner_hollow, .@"union");
    defer nested.deinit();
    try testing.expectEqual(@as(usize, 4), nested.counts().shells);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const parts = try decompose.decompose(testing.allocator, &nested, .{}, &diag);
    defer {
        for (parts) |*p| p.deinit();
        testing.allocator.free(parts);
    }
    try testing.expectEqual(@as(usize, 2), parts.len);
    var volumes: [2]f64 = undefined;
    for (parts, &volumes) |*p, *v| {
        try testing.expectEqual(@as(usize, 2), p.counts().shells);
        v.* = (try mass.mass(p, .{}, &diag)).volume;
    }
    std.mem.sort(f64, &volumes, {}, std.sort.asc(f64));
    try testing.expectApproxEqAbs(@as(f64, 216 - 64), volumes[0], CLOSE);
    try testing.expectApproxEqAbs(@as(f64, 1000 - 512), volumes[1], CLOSE);
}
