//! Faces by direction: a box's six, a stadium slab's top with its exact area and centroid
//! (arcs included), a plate with a hole, a cylinder's caps and no side, tags carried.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const tolerance = @import("../tolerance.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const faces = @import("faces.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
const CLOSE = 1e-9;

fn expectVec(want: Vec3, got: Vec3) !void {
    for (0..3) |k| try testing.expectApproxEqAbs(want[k], got[k], CLOSE);
}

test "faces: a box's faces each way, their centroids and areas; nothing diagonal" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 4, 6, false, &diag);
    defer box.deinit();
    const cases = [_]struct { dir: Vec3, centroid: Vec3, area: f64 }{
        .{ .dir = .{ 0, 0, 1 }, .centroid = .{ 1, 2, 6 }, .area = 8 },
        .{ .dir = .{ 0, 0, -1 }, .centroid = .{ 1, 2, 0 }, .area = 8 },
        .{ .dir = .{ 1, 0, 0 }, .centroid = .{ 2, 2, 3 }, .area = 24 },
        .{ .dir = .{ -1, 0, 0 }, .centroid = .{ 0, 2, 3 }, .area = 24 },
        .{ .dir = .{ 0, 1, 0 }, .centroid = .{ 1, 4, 3 }, .area = 12 },
        .{ .dir = .{ 0, -3, 0 }, .centroid = .{ 1, 0, 3 }, .area = 12 },
    };
    for (cases) |case| {
        const found = try faces.byDirection(testing.allocator, &box, case.dir, &diag);
        defer testing.allocator.free(found);
        try testing.expectEqual(@as(usize, 1), found.len);
        try expectVec(case.centroid, found[0].centroid);
        try testing.expectApproxEqAbs(case.area, found[0].area, CLOSE);
        try expectVec(vec.normalized(case.dir).?, found[0].normal);
    }
    const none = try faces.byDirection(testing.allocator, &box, .{ 1, 1, 0 }, &diag);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "faces: a stadium slab's top is its exact area and centroid; a plate's top has its hole; a cylinder has caps only" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // The stadium from x = −2 to 3 (the left end a half disc about (−2, 0), the right one
    // about (2, 0)... moved so its centroid is off the origin: shifted right by 1)
    const Arc = primitives.OutlineArc;
    const stadium = [_]primitives.OutlineEdge{
        .{ .a = .{ -1, -1 }, .b = .{ 3, -1 } },
        .{ .a = .{ 3, -1 }, .b = .{ 3, 1 }, .arc = Arc{ .c = .{ 3, 0 }, .r = 1, .ccw = true } },
        .{ .a = .{ 3, 1 }, .b = .{ -1, 1 } },
        .{ .a = .{ -1, 1 }, .b = .{ -1, -1 }, .arc = Arc{ .c = .{ -1, 0 }, .r = 1, .ccw = true } },
    };
    var slot = try primitives.outlines(testing.allocator, tol, &.{&stadium}, &diag);
    defer slot.deinit();
    var slab = try sweep.extrude(testing.allocator, &slot, .{ 0, 0, 2 }, .{}, &diag);
    defer slab.deinit();
    const top = try faces.byDirection(testing.allocator, &slab, .{ 0, 0, 1 }, &diag);
    defer testing.allocator.free(top);
    try testing.expectEqual(@as(usize, 1), top.len);
    try testing.expectApproxEqAbs(8 + PI, top[0].area, CLOSE);
    try expectVec(.{ 1, 0, 2 }, top[0].centroid);

    const outer = [_]Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]Vec2{ .{ 6, 6 }, .{ 6, 8 }, .{ 8, 8 }, .{ 8, 6 } };
    var sheet = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer sheet.deinit();
    var plate = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 1 }, .{}, &diag);
    defer plate.deinit();
    const plate_top = try faces.byDirection(testing.allocator, &plate, .{ 0, 0, 1 }, &diag);
    defer testing.allocator.free(plate_top);
    try testing.expectApproxEqAbs(@as(f64, 96), plate_top[0].area, CLOSE);
    // (100 · 5 − 4 · 7) / 96 in each of x and y
    const c = (100.0 * 5 - 4.0 * 7) / 96.0;
    try expectVec(.{ c, c, 1 }, plate_top[0].centroid);

    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 3, false, &diag);
    defer cyl.deinit();
    const cap = try faces.byDirection(testing.allocator, &cyl, .{ 0, 0, 1 }, &diag);
    defer testing.allocator.free(cap);
    try testing.expectEqual(@as(usize, 1), cap.len);
    try testing.expectApproxEqAbs(4 * PI, cap[0].area, CLOSE);
    try expectVec(.{ 0, 0, 3 }, cap[0].centroid);
    const side = try faces.byDirection(testing.allocator, &cyl, .{ 1, 0, 0 }, &diag);
    defer testing.allocator.free(side);
    try testing.expectEqual(@as(usize, 0), side.len);
}

test "faces: a small face far from its plane's origin has its own area and centroid" {
    // The bottom's plane is the sketch's, its frame at the world's origin: the moments
    // about there summed terms of 1e13 for a face of 1e-4, and the centroid divided their
    // rounding by its area. About a point of the face
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const at = Vec2{ 9e6, 3e6 };
    const square = [_]Vec2{ at, vec.add2(at, .{ 0.01, 0 }), vec.add2(at, .{ 0.01, 0.01 }), vec.add2(at, .{ 0, 0.01 }) };
    var sheet = try primitives.polygon(testing.allocator, tol, &square, &diag);
    defer sheet.deinit();
    var post = try sweep.extrude(testing.allocator, &sheet, .{ 0, 0, 0.01 }, .{}, &diag);
    defer post.deinit();
    for ([_]Vec3{ .{ 0, 0, 1 }, .{ 0, 0, -1 } }, [_]f64{ 0.01, 0 }) |dir, z| {
        const found = try faces.byDirection(testing.allocator, &post, dir, &diag);
        defer testing.allocator.free(found);
        try testing.expectEqual(@as(usize, 1), found.len);
        // The corners where their coordinates round them, 1.9e-9 at most
        try testing.expectApproxEqAbs(@as(f64, 1e-4), found[0].area, 1e-10);
        for (0..3) |k| try testing.expectApproxEqAbs((Vec3{ at[0] + 0.005, at[1] + 0.005, z })[k], found[0].centroid[k], 1e-8);
    }
}
