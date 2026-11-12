//! Plane sections: a box at every kind of height (inside, on its bottom, on its top,
//! beside it); a cylinder, a sphere, a cone and a torus cut in exact circles and touched
//! (nothing); a cylinder lying down cut in lines and touched along its side; a plate with
//! a hole; a stepped solid of revolution at its step; a groove's floor (two faces rising
//! from one edge, which cancel); a tetrahedron by its corners; turned solids whose slices'
//! areas integrate to their volumes; two parts; and the refusals (a tilted cylinder's
//! ellipse, a free-form face, a sheet, a height that is not a number). Every section is
//! checked.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Affine = @import("../math/mat.zig").Affine;
const tolerance = @import("../tolerance.zig");
const diagnostics = @import("../diagnostics.zig");
const Diagnostics = diagnostics.Diagnostics;
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const transform = @import("../construct/transform.zig");
const test_bodies = @import("../construct/test_bodies.zig");
const mass = @import("../measure/mass.zig");
const section = @import("section.zig");
const Vec2 = vec.Vec2;
const Vec3 = vec.Vec3;

const tol = tolerance.Tolerance.fromZone(1e-5);
const PI = std.math.pi;
/// Exact areas agree to rounding.
const EXACT = 1e-9;

/// The section of `body` at `height`, checked as a sheet: valid, on `z = 0`.
fn sliced(body: *const Body, height: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try section.slice(testing.allocator, body, height, .{}, &diag);
    errdefer sheet.deinit();
    try testing.expectEqual(.sheet, sheet.kind);
    var report = try check.run(testing.allocator, &sheet, .geometric);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try f.format(&w);
        std.debug.print("checker: {s}\n", .{w.buffered()});
    }
    try testing.expect(report.ok());
    for (sheet.geometry.points.items) |p| try testing.expectEqual(@as(f64, 0), p[2]);
    return sheet;
}

fn areaOf(sheet: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(sheet, .{}, &diag)).area;
}

/// The section's area at `height`, against `want` (relative), and its face count.
fn expectSection(body: *const Body, height: f64, want: f64, faces: usize) !void {
    var sheet = try sliced(body, height);
    defer sheet.deinit();
    try testing.expectEqual(faces, sheet.counts().faces);
    if (want == 0) return testing.expect(sheet.isEmpty());
    try testing.expectApproxEqRel(want, try areaOf(&sheet), EXACT);
}

/// How many of the section's edges are arcs (its circles cut exact, not as polygons).
fn arcs(body: *const Body, height: f64) !usize {
    var sheet = try sliced(body, height);
    defer sheet.deinit();
    var n: usize = 0;
    for (sheet.edges.items) |e| n += @intFromBool(e.curve.kind == .circle);
    return n;
}

fn turned(body: *const Body, affine: Affine) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return transform.transform(testing.allocator, body, &affine, .{}, &diag);
}

fn expectRefused(body: *const Body, height: f64, err: diagnostics.Error) !diagnostics.Finding {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(err, section.slice(testing.allocator, body, height, .{}, &diag));
    return diag.first().?;
}

test "slice: a box inside, on its bottom (its bottom square), on its top and beside it (nothing)" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 10, 4, 6, false, &diag);
    defer box.deinit();
    try expectSection(&box, 3, 40, 1);
    try expectSection(&box, 0, 40, 1);
    try expectSection(&box, 1e-12, 40, 1);
    try expectSection(&box, 6, 0, 0);
    try expectSection(&box, -1, 0, 0);
    try expectSection(&box, 7, 0, 0);
    // The square is the box's own: its corners
    var sheet = try sliced(&box, 2);
    defer sheet.deinit();
    try testing.expectEqual(@as(usize, 4), sheet.counts().vertices);
    for (sheet.geometry.points.items) |p| {
        try testing.expect(p[0] == 0 or p[0] == 10);
        try testing.expect(p[1] == 0 or p[1] == 4);
    }
}

test "slice: a cylinder, a sphere, a cone and a torus are cut in exact circles; touching them gives nothing" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 5, 10, false, &diag);
    defer cyl.deinit();
    try expectSection(&cyl, 3, 25 * PI, 1);
    try expectSection(&cyl, 0, 25 * PI, 1);
    try expectSection(&cyl, 10, 0, 0);
    try testing.expect(try arcs(&cyl, 3) >= 1);
    var ball = try primitives.sphere(testing.allocator, tol, 5, &diag);
    defer ball.deinit();
    try expectSection(&ball, 3, 16 * PI, 1);
    try expectSection(&ball, -3, 16 * PI, 1);
    try expectSection(&ball, 0, 25 * PI, 1);
    try expectSection(&ball, 5, 0, 0);
    try expectSection(&ball, -5, 0, 0);
    try testing.expect(try arcs(&ball, 1) >= 1);
    var cone = try primitives.cone(testing.allocator, tol, 5, 2, 6, false, &diag);
    defer cone.deinit();
    try expectSection(&cone, 2, 16 * PI, 1);
    var spike = try primitives.cone(testing.allocator, tol, 3, 0, 6, false, &diag);
    defer spike.deinit();
    try expectSection(&spike, 4, PI, 1);
    try expectSection(&spike, 6, 0, 0);
    var ring = try primitives.torus(testing.allocator, tol, 5, 1, &diag);
    defer ring.deinit();
    try expectSection(&ring, 0, 20 * PI, 1);
    try expectSection(&ring, 0.5, 20 * PI * @sqrt(0.75), 1);
    try expectSection(&ring, 1, 0, 0);
    try expectSection(&ring, -1, 0, 0);
}

test "slice: a cylinder lying down is cut in a band between two lines, and touched along its sides gives nothing" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 10, false, &diag);
    defer cyl.deinit();
    // Turned a right angle about x: its axis along −y, its side from z = −2 to 2
    var lying = try turned(&cyl, Affine.rotate(vec.X3, PI / 2.0));
    defer lying.deinit();
    try expectSection(&lying, 0, 40, 1);
    try expectSection(&lying, 1, 20 * @sqrt(3.0), 1);
    try expectSection(&lying, -1.5, 20 * @sqrt(1.75), 1);
    try expectSection(&lying, 2, 0, 0);
    try expectSection(&lying, -2, 0, 0);
}

test "slice: a plate with a hole is a face with a hole; a stepped solid at its step is its upper part" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var square = try primitives.square(testing.allocator, tol, 10, 10, true, &diag);
    defer square.deinit();
    var hole = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer hole.deinit();
    const sketch_boolean = @import("../sketch/boolean.zig");
    var plate_sheet = try sketch_boolean.boolean(testing.allocator, &.{ &square, &hole }, .difference, .{}, &diag);
    defer plate_sheet.deinit();
    var plate = try sweep.extrude(testing.allocator, &plate_sheet, .{ 0, 0, 3 }, .{}, &diag);
    defer plate.deinit();
    try expectSection(&plate, 1.5, 100 - 4 * PI, 1);
    var sheet = try sliced(&plate, 1.5);
    defer sheet.deinit();
    try testing.expectEqual(@as(usize, 2), sheet.counts().loops);
    // A step: radius 4 up to 2, radius 2 up to 5, revolved about y and stood up
    var profile = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 2 }, .{ 2, 2 }, .{ 2, 5 }, .{ 0, 5 } }, &diag);
    defer profile.deinit();
    var lathe = try sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Y3, 2 * PI, .{}, &diag);
    defer lathe.deinit();
    var stepped = try turned(&lathe, Affine.rotate(vec.X3, PI / 2.0));
    defer stepped.deinit();
    try expectSection(&stepped, 1, 16 * PI, 1);
    try expectSection(&stepped, 2, 4 * PI, 1);
    try expectSection(&stepped, 0, 16 * PI, 1);
    try expectSection(&stepped, 5, 0, 0);
}

test "slice: two faces rising from one edge on the plane (a groove's floor) cancel; above it they bound a band" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var profile = try primitives.polygon(testing.allocator, tol, &.{ .{ -5, 2 }, .{ 0, 0 }, .{ 5, 2 }, .{ 5, 5 }, .{ -5, 5 } }, &diag);
    defer profile.deinit();
    var prism = try sweep.extrude(testing.allocator, &profile, .{ 0, 0, 10 }, .{}, &diag);
    defer prism.deinit();
    // The profile's y up: its floor the edge along y = 0 at the valley
    var groove = try turned(&prism, Affine.rotate(vec.X3, PI / 2.0));
    defer groove.deinit();
    try expectSection(&groove, 0, 0, 0);
    try expectSection(&groove, 1, 50, 1);
    try expectSection(&groove, 2, 100, 1);
    try expectSection(&groove, 4, 100, 1);
}

test "slice: a tetrahedron by its corners: its base, a scaled triangle, its apex" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 0, 0 }, .{ 6, 0, 0 }, .{ 0, 6, 0 }, .{ 0, 0, 6 } };
    const triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 0, 3, 2 } };
    var tetra = try primitives.polyhedron(testing.allocator, tol, &points, &triangles, &diag);
    defer tetra.deinit();
    try expectSection(&tetra, 0, 18, 1);
    try expectSection(&tetra, 3, 4.5, 1);
    try expectSection(&tetra, 4, 2, 1);
    try expectSection(&tetra, 6, 0, 0);
}

/// The volume by Simpson's rule over `n` slices between `low` and `high`.
fn integrated(body: *const Body, low: f64, high: f64, n: usize) !f64 {
    const step = (high - low) / @as(f64, @floatFromInt(n));
    var sum: f64 = 0;
    for (0..n + 1) |k| {
        var sheet = try sliced(body, low + step * @as(f64, @floatFromInt(k)));
        defer sheet.deinit();
        const weight: f64 = if (k == 0 or k == n) 1 else if (k % 2 == 1) 4 else 2;
        sum += weight * (if (sheet.isEmpty()) 0 else try areaOf(&sheet));
    }
    return sum * step / 3;
}

test "slice: the areas of a turned box's and a turned sphere's slices integrate to their volumes" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 4, 5, 6, true, &diag);
    defer box.deinit();
    var tilted = try turned(&box, Affine.rotateXyzDegrees(30, 40, 10));
    defer tilted.deinit();
    const bounds = try @import("../measure/bbox.zig").bodyBounds(&tilted);
    // The area is piecewise quadratic in the height: Simpson's rule is exact on each piece,
    // and the pieces' ends cost little at this count
    try testing.expectApproxEqRel(@as(f64, 120), try integrated(&tilted, bounds.min[2], bounds.max[2], 120), 1e-3);
    var ball = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer ball.deinit();
    var moved = try turned(&ball, Affine.translate(.{ 1, 2, 3 }).compose(&Affine.rotateXyzDegrees(20, 70, 0)));
    defer moved.deinit();
    try testing.expectApproxEqRel(4.0 / 3.0 * PI * 27.0, try integrated(&moved, 0, 6, 12), EXACT);
}

test "slice: two parts are two faces" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var two = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } }, &.{ .{ 5, 0 }, .{ 8, 0 }, .{ 8, 3 }, .{ 5, 3 } } }, &diag);
    defer two.deinit();
    var blocks = try sweep.extrude(testing.allocator, &two, .{ 0, 0, 4 }, .{}, &diag);
    defer blocks.deinit();
    try expectSection(&blocks, 2, 13, 2);
}

test "slice: a tilted cylinder's ellipse, a free-form face, a sheet and a height that is not a number are refused" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 10, false, &diag);
    defer cyl.deinit();
    var tilted = try turned(&cyl, Affine.rotate(vec.X3, PI / 6.0));
    defer tilted.deinit();
    const ellipse = try expectRefused(&tilted, 3, error.NotImplemented);
    try testing.expectEqual(.not_implemented, ellipse.code);
    try testing.expectEqual(.face, ellipse.entity.kind);
    // Below the box's free-form top only its flat sides are cut
    var patch = try test_bodies.patchTopBox(testing.allocator, tol, 1, &diag);
    defer patch.deinit();
    try expectSection(&patch, 2, 6, 1);
    const free = try expectRefused(&patch, 4.2, error.NotImplemented);
    try testing.expectEqual(.face, free.entity.kind);
    var square = try primitives.square(testing.allocator, tol, 1, 1, false, &diag);
    defer square.deinit();
    _ = try expectRefused(&square, 0, error.InvalidInput);
    _ = try expectRefused(&cyl, std.math.nan(f64), error.InvalidInput);
}

test "slice: an empty solid's section is empty" {
    var empty = Body.empty(testing.allocator, tol);
    defer empty.deinit();
    try expectSection(&empty, 0, 0, 0);
}
