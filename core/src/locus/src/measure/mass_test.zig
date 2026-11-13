//! Volumes and areas against closed forms, on every primitive and sweep, under moves and
//! scales; genus by shells.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const transform = @import("../construct/transform.zig");
const mass = @import("mass.zig");

const tol = Tolerance.fromZone(1e-5);
const PI = std.math.pi;
/// How close the quadrature gets to a closed form, relative.
const CLOSE = 1e-9;
/// Far from the origin: coordinates of 1e5, where one's ulp is 1.5e-11.
const FAR: vec.Vec3 = .{ 1e5, -2e5, 3e5 };

fn expectMeasures(body: *const Body, volume: f64, area: f64) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const m = try mass.mass(body, .{}, &diag);
    try testing.expectApproxEqRel(volume, m.volume, CLOSE);
    try testing.expectApproxEqRel(area, m.area, CLOSE);
    try testing.expect(m.volume_error <= CLOSE * @max(volume, 1));
    try testing.expect(m.area_error <= CLOSE * @max(area, 1));
}

test "mass: the primitives measure their closed forms" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    try expectMeasures(&box, 24, 2 * (6 + 12 + 8));

    var cyl = try primitives.cylinder(testing.allocator, tol, 2, 5, true, &diag);
    defer cyl.deinit();
    try expectMeasures(&cyl, PI * 4 * 5, 2 * PI * 2 * 5 + 2 * PI * 4);

    var sphere = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer sphere.deinit();
    try expectMeasures(&sphere, 4.0 / 3.0 * PI * 27, 4 * PI * 9);

    // A frustum: r1 = 2 to r2 = 1 over h = 3; its slant is √(9 + 1)
    var frustum = try primitives.cone(testing.allocator, tol, 2, 1, 3, false, &diag);
    defer frustum.deinit();
    const slant = @sqrt(10.0);
    try expectMeasures(&frustum, PI * 3 / 3.0 * (4 + 2 + 1), PI * (2 + 1) * slant + PI * 4 + PI * 1);

    var pointed = try primitives.cone(testing.allocator, tol, 2, 0, 3, false, &diag);
    defer pointed.deinit();
    try expectMeasures(&pointed, PI * 4 * 3 / 3.0, PI * 2 * @sqrt(13.0) + PI * 4);

    var torus = try primitives.torus(testing.allocator, tol, 5, 2, &diag);
    defer torus.deinit();
    try expectMeasures(&torus, 2 * PI * PI * 5 * 4, 4 * PI * PI * 5 * 2);

    // A polyhedron: the unit tetrahedron scaled by 10
    const pts = [_]vec.Vec3{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 0, 10, 0 }, .{ 0, 0, 10 } };
    const tris = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 0, 3, 2 }, .{ 1, 2, 3 } };
    var tet = try primitives.polyhedron(testing.allocator, tol, &pts, &tris, &diag);
    defer tet.deinit();
    try expectMeasures(&tet, 1000.0 / 6.0, 3 * 50 + 50 * @sqrt(3.0));
}

test "mass: sheets have their area and no volume" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sq = try primitives.square(testing.allocator, tol, 4, 3, true, &diag);
    defer sq.deinit();
    try expectMeasures(&sq, 0, 12);
    var ci = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer ci.deinit();
    try expectMeasures(&ci, 0, PI * 4);
    const outer = [_]vec.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]vec.Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var plate = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer plate.deinit();
    try expectMeasures(&plate, 0, 100 - 4);
}

test "mass: sweeps measure their closed forms, and a move keeps them while a scale cubes and squares them" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const outer = [_]vec.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]vec.Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var plate = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer plate.deinit();
    var slab = try sweep.extrude(testing.allocator, &plate, .{ 0, 0, 3 }, .{}, &diag);
    defer slab.deinit();
    try expectMeasures(&slab, 96 * 3, 2 * 96 + 40 * 3 + 8 * 3);

    var ci = try primitives.circle(testing.allocator, tol, 2, &diag);
    defer ci.deinit();
    var drum = try sweep.extrude(testing.allocator, &ci, .{ 0, 0, 5 }, .{}, &diag);
    defer drum.deinit();
    try expectMeasures(&drum, PI * 4 * 5, 2 * PI * 2 * 5 + 2 * PI * 4);

    // A ring: the square x ∈ [1, 3], y ∈ [0, 3] turned about z
    var sq = try primitives.square(testing.allocator, tol, 2, 3, false, &diag);
    defer sq.deinit();
    var shifted = try transform.transform(testing.allocator, &sq, &mat.Affine.translate(.{ 1, 0, 0 }), .{}, &diag);
    defer shifted.deinit();
    var profile = try transform.transform(testing.allocator, &shifted, &mat.Affine.rotate(vec.X3, PI / 2.0), .{}, &diag);
    defer profile.deinit();
    var ring = try sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Z3, 2 * PI, .{}, &diag);
    defer ring.deinit();
    const ring_volume = PI * (9 - 1) * 3;
    const ring_area = 2 * PI * (3 + 1) * 3 + 2 * PI * (9 - 1);
    try expectMeasures(&ring, ring_volume, ring_area);
    var quarter = try sweep.revolve(testing.allocator, &profile, vec.ZERO3, vec.Z3, PI / 2.0, .{}, &diag);
    defer quarter.deinit();
    try expectMeasures(&quarter, ring_volume / 4.0, ring_area / 4.0 + 2 * 6);

    // A cone by revolution, with its apex on the axis
    var tri = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 0, 3 } }, &diag);
    defer tri.deinit();
    var tri_up = try transform.transform(testing.allocator, &tri, &mat.Affine.rotate(vec.X3, PI / 2.0), .{}, &diag);
    defer tri_up.deinit();
    var cone = try sweep.revolve(testing.allocator, &tri_up, vec.ZERO3, vec.Z3, 2 * PI, .{}, &diag);
    defer cone.deinit();
    try expectMeasures(&cone, PI * 4 * 3 / 3.0, PI * 2 * @sqrt(13.0) + PI * 4);

    // Moved and turned: the same; scaled by 2: eight and four times
    const move = mat.Affine.translate(.{ 7, -3, 2 }).compose(&mat.Affine.rotate(vec.normalized(.{ 1, 2, 3 }).?, 0.7));
    var moved = try transform.transform(testing.allocator, &ring, &move, .{}, &diag);
    defer moved.deinit();
    try expectMeasures(&moved, ring_volume, ring_area);
    var scaled = try transform.transform(testing.allocator, &ring, &mat.Affine.scaleBy(.{ 2, 2, 2 }), .{}, &diag);
    defer scaled.deinit();
    try expectMeasures(&scaled, 8 * ring_volume, 4 * ring_area);
}

test "mass: a body far from the origin measures what it does at the origin" {
    // About the origin, a 2-unit box out here measured 4.5e-7 off: its faces' terms were
    // the size of the distance times the face, cancelling to the box's volume
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const far = mat.Affine.translate(FAR).compose(&mat.Affine.rotate(vec.normalized(.{ 1, 1, 0 }).?, PI / 4.0));
    var cube = try primitives.box(testing.allocator, tol, 2, 2, 2, true, &diag);
    defer cube.deinit();
    var far_cube = try transform.transform(testing.allocator, &cube, &far, .{}, &diag);
    defer far_cube.deinit();
    try expectMeasures(&far_cube, 8, 24);
    // Curved faces and arcs: a cylinder
    var drum = try primitives.cylinder(testing.allocator, tol, 2, 5, true, &diag);
    defer drum.deinit();
    var far_drum = try transform.transform(testing.allocator, &drum, &far, .{}, &diag);
    defer far_drum.deinit();
    try expectMeasures(&far_drum, PI * 4 * 5, 2 * PI * 2 * 5 + 2 * PI * 4);
}

test "genus: a sphere 0, a torus 1, a slab with a hole 1, as the mesh engine counts them" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sphere = try primitives.sphere(testing.allocator, tol, 3, &diag);
    defer sphere.deinit();
    try testing.expectEqual(@as(i32, 0), try mass.genus(&sphere, &diag));
    var box = try primitives.box(testing.allocator, tol, 2, 3, 4, false, &diag);
    defer box.deinit();
    try testing.expectEqual(@as(i32, 0), try mass.genus(&box, &diag));
    var torus = try primitives.torus(testing.allocator, tol, 5, 2, &diag);
    defer torus.deinit();
    try testing.expectEqual(@as(i32, 1), try mass.genus(&torus, &diag));
    const outer = [_]vec.Vec2{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const inner = [_]vec.Vec2{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    var plate = try primitives.polygonsEvenOdd(testing.allocator, tol, &.{ &outer, &inner }, &diag);
    defer plate.deinit();
    var slab = try sweep.extrude(testing.allocator, &plate, .{ 0, 0, 3 }, .{}, &diag);
    defer slab.deinit();
    try testing.expectEqual(@as(i32, 1), try mass.genus(&slab, &diag));
    try testing.expectEqual(@as(i32, 0), try mass.genus(&plate, &diag));
}
