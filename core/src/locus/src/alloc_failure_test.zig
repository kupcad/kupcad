//! Every public operation under a failing allocator (README rule 6, architecture §9.2):
//! whichever allocation fails, the operation returns `error.OutOfMemory`, leaves nothing
//! allocated, and touches no input. `std.testing.checkAllAllocationFailures` fails each
//! allocation in turn and checks for leaks after each.

const std = @import("std");
const testing = std.testing;
const vec = @import("math/vec.zig");
const mat = @import("math/mat.zig");
const Tolerance = @import("tolerance.zig").Tolerance;
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const Body = @import("topology/body.zig").Body;
const primitives = @import("construct/primitives.zig");
const hull = @import("construct/hull.zig");
const transform = @import("construct/transform.zig");
const body_json = @import("io/body_json.zig");
const step_write = @import("io/step_write.zig");
const check = @import("topology/check.zig");
const bvh = @import("spatial/bvh.zig");

const tol = Tolerance.fromZone(1e-5);

fn buildBox(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try primitives.box(allocator, tol, 1, 2, 3, true, &diag);
    b.deinit();
}

fn buildCylinder(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try primitives.cylinder(allocator, tol, 1, 2, false, &diag);
    b.deinit();
}

fn buildCircle(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var b = try primitives.circle(allocator, tol, 1, &diag);
    b.deinit();
}

fn buildEvenOdd(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    var b = try primitives.polygonsEvenOdd(allocator, tol, &.{ &outer, &inner }, &diag);
    b.deinit();
}

fn buildPolyhedron(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 } };
    const tris = [_][3]u32{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 } };
    var b = try primitives.polyhedron(allocator, tol, &pts, &tris, &diag);
    b.deinit();
}

fn buildHull(allocator: std.mem.Allocator) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 }, .{ 5, 5, 5 }, .{ 2, 2, 2 } };
    var b = try hull.hull(allocator, tol, &pts, &diag);
    b.deinit();
}

/// The input body, built with an allocator that never fails, so a failure inside the
/// operation cannot be one of its own.
fn withBody(allocator: std.mem.Allocator, op: *const fn (std.mem.Allocator, *const Body) anyerror!void) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var body = try primitives.cylinder(testing.allocator, tol, 2, 5, true, &diag);
    defer body.deinit();
    const before = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(before);
    try op(allocator, &body);
    // The input is untouched whatever happened
    const after = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

fn opTransform(allocator: std.mem.Allocator, body: *const Body) !void {
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const affine = mat.Affine.mirror(vec.X3).compose(&mat.Affine.scaleBy(.{ 2, 2, 2 }));
    var out = try transform.transform(allocator, body, &affine, .{}, &diag);
    out.deinit();
}

fn opDumpLoad(allocator: std.mem.Allocator, body: *const Body) !void {
    const text = try body_json.dump(allocator, body);
    defer allocator.free(text);
    var loaded = try body_json.load(allocator, text);
    loaded.deinit();
    _ = try body_json.hash(allocator, body);
}

fn opStep(allocator: std.mem.Allocator, body: *const Body) !void {
    const text = try step_write.write(allocator, &.{body});
    allocator.free(text);
}

fn opCheck(allocator: std.mem.Allocator, body: *const Body) !void {
    var report = try check.run(allocator, body, .geometric);
    report.deinit(allocator);
}

fn opClone(allocator: std.mem.Allocator, body: *const Body) !void {
    var copy = try body.clone(allocator);
    copy.deinit();
}

fn opCompact(allocator: std.mem.Allocator, body: *const Body) !void {
    var copy = try body.clone(allocator);
    defer copy.deinit();
    var remap = try copy.compact();
    remap.deinit(allocator);
}

fn opBvh(allocator: std.mem.Allocator, body: *const Body) !void {
    _ = body;
    var boxes: [40]@import("geometry/types.zig").Box3 = undefined;
    for (&boxes, 0..) |*b, i| {
        const x: f64 = @floatFromInt(i % 7);
        const y: f64 = @floatFromInt(i / 7);
        b.* = .{ .min = .{ x, y, 0 }, .max = .{ x + 1.5, y + 1.5, 1 } };
    }
    var tree = try bvh.Bvh.build(allocator, &boxes);
    tree.deinit(allocator);
}

test "allocation failure: every primitive leaves nothing allocated whichever allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, buildBox, .{});
    try testing.checkAllAllocationFailures(testing.allocator, buildCylinder, .{});
    try testing.checkAllAllocationFailures(testing.allocator, buildCircle, .{});
    try testing.checkAllAllocationFailures(testing.allocator, buildEvenOdd, .{});
    try testing.checkAllAllocationFailures(testing.allocator, buildPolyhedron, .{});
    try testing.checkAllAllocationFailures(testing.allocator, buildHull, .{});
}

test "allocation failure: every operation on a body leaves nothing allocated and the input untouched" {
    try testing.checkAllAllocationFailures(testing.allocator, withBody, .{opTransform});
    try testing.checkAllAllocationFailures(testing.allocator, withBody, .{opDumpLoad});
    try testing.checkAllAllocationFailures(testing.allocator, withBody, .{opStep});
    try testing.checkAllAllocationFailures(testing.allocator, withBody, .{opCheck});
    try testing.checkAllAllocationFailures(testing.allocator, withBody, .{opClone});
    try testing.checkAllAllocationFailures(testing.allocator, withBody, .{opCompact});
    try testing.checkAllAllocationFailures(testing.allocator, withBody, .{opBvh});
}

test "cancel: a flag set before the call is error.Canceled, with nothing allocated and the input untouched" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var body = try primitives.cylinder(testing.allocator, tol, 2, 5, true, &diag);
    defer body.deinit();
    const before = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(before);
    var flag = std.atomic.Value(bool).init(true);
    const affine = mat.Affine.translate(.{ 1, 0, 0 });
    try testing.expectError(error.Canceled, transform.transform(testing.allocator, &body, &affine, .{ .cancel = &flag }, &diag));
    const after = try body_json.dump(testing.allocator, &body);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}
