const std = @import("std");
const driver = @import("driver.zig");
const geom = @import("../../../core/geometry_handle.zig");
const EngineConfig = @import("../../../core/engine_config.zig").EngineConfig;
const locus = @import("locus");

const TEST_CONFIG: EngineConfig = .{ .engine = .brep_native };

fn bodyOf(handle: anytype) *const locus.Body {
    return &@as(*driver.BrepSolid, @ptrCast(@alignCast(handle.ptr))).body;
}

fn boxOf(handle: geom.GeometryHandle) !geom.BoundingBox {
    return driver.driver.boundingBoxFn(handle) orelse error.NoBounds;
}

test "Driver: the primitives it has, each a valid body with the right counts" {
    const cube = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube);
    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(cube));
    const cube_box = try boxOf(cube);
    try std.testing.expectEqual([3]f64{ -5, -5, -5 }, cube_box.min);
    try std.testing.expectEqual([3]f64{ 5, 5, 5 }, cube_box.max);

    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 5, 5, 15, true, 32) orelse return error.CylinderFailed;
    defer driver.driver.destructFn(cyl);
    try std.testing.expectEqual(@as(usize, 4), driver.driver.numVertsFn(cyl));
    try std.testing.expect(driver.hasCurvedFaces(cyl));
    try std.testing.expect(!driver.hasCurvedFaces(cube));
    // Bad arguments are refused, nothing kept
    try std.testing.expect(driver.driver.cubeFn(&TEST_CONFIG, 0, 10, 10, true) == null);
    try std.testing.expect(driver.driver.cylinderFn(&TEST_CONFIG, 0, 0, 15, true, 32) == null);
    try std.testing.expect(driver.driver.sphereFn(&TEST_CONFIG, -1, 0) == null);
}

test "Driver: the exact sphere and cone, their boxes, and the mesh engine's segments ignored" {
    const sphere = driver.driver.sphereFn(&TEST_CONFIG, 4, 7) orelse return error.SphereFailed;
    defer driver.driver.destructFn(sphere);
    try std.testing.expectEqual(@as(usize, 2), driver.driver.numVertsFn(sphere));
    try std.testing.expectEqual([3]f64{ -4, -4, -4 }, (try boxOf(sphere)).min);
    try std.testing.expectEqual([3]f64{ 4, 4, 4 }, (try boxOf(sphere)).max);
    try std.testing.expectEqual(@as(usize, 1), bodyOf(sphere).geometry.spheres.items.len);

    const frustum = driver.driver.cylinderFn(&TEST_CONFIG, 3, 1, 6, true, 5) orelse return error.ConeFailed;
    defer driver.driver.destructFn(frustum);
    try std.testing.expectEqual(@as(usize, 4), driver.driver.numVertsFn(frustum));
    try std.testing.expectEqual([3]f64{ -3, -3, -3 }, (try boxOf(frustum)).min);
    try std.testing.expectEqual([3]f64{ 3, 3, 3 }, (try boxOf(frustum)).max);
    try std.testing.expectEqual(@as(usize, 1), bodyOf(frustum).geometry.cones.items.len);

    const pointed = driver.driver.cylinderFn(&TEST_CONFIG, 0, 2, 5, false, 5) orelse return error.ConeFailed;
    defer driver.driver.destructFn(pointed);
    try std.testing.expectEqual(@as(usize, 3), driver.driver.numVertsFn(pointed));
    try std.testing.expect(driver.supports(.sphere));
    try std.testing.expect(driver.supports(.cone));
    try std.testing.expect(driver.hasCurvedFaces(sphere));
}

test "Driver: an extrusion is exact and refuses a twist or a taper" {
    const sq = driver.driver.squareFn(&TEST_CONFIG, 10, 20, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq);
    const box = driver.driver.extrudeFn(sq, 5, 7, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(box);
    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(box));
    try std.testing.expectEqual([3]f64{ 10, 20, 5 }, (try boxOf(box)).max);
    try std.testing.expect(driver.driver.extrudeFn(sq, 5, 0, 30, 1, 1) == null);
    try std.testing.expect(driver.driver.extrudeFn(sq, 5, 0, 0, 2, 1) == null);
    try std.testing.expect(driver.supports(.extrude));
    try std.testing.expect(!driver.supports(.extrude_twist));
    const ci = driver.driver.circleFn(&TEST_CONFIG, 3, 64) orelse return error.CircleFailed;
    defer driver.driver.destructCrossSectionFn(ci);
    const cyl = driver.driver.extrudeFn(ci, 2, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(cyl);
    try std.testing.expect(driver.hasCurvedFaces(cyl));
    try std.testing.expectEqual([3]f64{ -3, -3, 0 }, (try boxOf(cyl)).min);
}

test "Driver: a revolution is exact; a sketch across the axis is refused with its reason" {
    const sq = driver.driver.squareFn(&TEST_CONFIG, 4, 3, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq);
    const drum = driver.driver.revolveFn(sq, 16, 360) orelse return error.RevolveFailed;
    defer driver.driver.destructFn(drum);
    try std.testing.expectEqual([3]f64{ -4, -4, 0 }, (try boxOf(drum)).min);
    try std.testing.expectEqual([3]f64{ 4, 4, 3 }, (try boxOf(drum)).max);
    try std.testing.expect(driver.hasCurvedFaces(drum));
    const quarter = driver.driver.revolveFn(sq, 16, 90) orelse return error.RevolveFailed;
    defer driver.driver.destructFn(quarter);
    const qbox = try boxOf(quarter);
    try std.testing.expectApproxEqAbs(@as(f64, 0), qbox.min[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4), qbox.max[1], 1e-12);
    try std.testing.expect(driver.supports(.revolve));

    const centred = driver.driver.squareFn(&TEST_CONFIG, 4, 3, true) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(centred);
    try std.testing.expect(driver.driver.revolveFn(centred, 16, 360) == null);
    const why = driver.driver.takeFailureFn() orelse return error.NoReason;
    try std.testing.expect(std.mem.indexOf(u8, why, "crossing the axis") != null);
}

test "Driver: volume, area, genus and a sketch's area are exact" {
    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 2, 2, 5, false, 32) orelse return error.CylinderFailed;
    defer driver.driver.destructFn(cyl);
    try std.testing.expectApproxEqRel(std.math.pi * 4 * 5, driver.driver.volumeFn(cyl), 1e-9);
    try std.testing.expectApproxEqRel(2 * std.math.pi * 2 * 5 + 2 * std.math.pi * 4, driver.driver.surfaceAreaFn(cyl), 1e-9);
    try std.testing.expectEqual(@as(i32, 0), driver.driver.genusFn(cyl));
    const ci = driver.driver.circleFn(&TEST_CONFIG, 3, 64) orelse return error.CircleFailed;
    defer driver.driver.destructCrossSectionFn(ci);
    try std.testing.expectApproxEqRel(std.math.pi * 9, driver.driver.crossSectionAreaFn(ci), 1e-9);
    try std.testing.expect(driver.supports(.volume));
    try std.testing.expect(driver.supports(.surface_area));
    try std.testing.expect(driver.supports(.genus));
    try std.testing.expect(driver.supports(.bounding_box));
    try std.testing.expect(driver.supports(.sketch_measure));
}

test "Driver: sketch booleans are exact, two at a time and in a batch" {
    const plate = driver.driver.squareFn(&TEST_CONFIG, 10, 10, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(plate);
    const disc = driver.driver.circleFn(&TEST_CONFIG, 2, 64) orelse return error.CircleFailed;
    defer driver.driver.destructCrossSectionFn(disc);
    const hole = driver.driver.crossSectionTransformFn(disc, .{ 1, 0, 0, 1, 5, 5 }) orelse return error.TransformFailed;
    defer driver.driver.destructCrossSectionFn(hole);
    const pierced = driver.driver.crossSectionBooleanFn(plate, hole, .difference_op) orelse return error.BooleanFailed;
    defer driver.driver.destructCrossSectionFn(pierced);
    try std.testing.expectApproxEqRel(100 - std.math.pi * 4, driver.driver.crossSectionAreaFn(pierced), 1e-9);
    const all = driver.driver.crossSectionBatchBooleanFn(std.testing.allocator, &.{ plate, hole, disc }, .union_op) orelse return error.BooleanFailed;
    defer driver.driver.destructCrossSectionFn(all);
    try std.testing.expectApproxEqRel(100 + std.math.pi * 4 * 3.0 / 4.0, driver.driver.crossSectionAreaFn(all), 1e-9);
    try std.testing.expect(driver.supports(.sketch_boolean));
}

test "Driver: a sketch's offset is exact, its round joins arcs" {
    const sq = driver.driver.squareFn(&TEST_CONFIG, 4, 4, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq);
    const round = driver.driver.offsetFn(sq, 1, 1, 8, 2) orelse return error.OffsetFailed;
    defer driver.driver.destructCrossSectionFn(round);
    try std.testing.expectApproxEqRel(16 + 16 + std.math.pi, driver.driver.crossSectionAreaFn(round), 1e-9);
    const miter = driver.driver.offsetFn(sq, 1, 2, 8, 2) orelse return error.OffsetFailed;
    defer driver.driver.destructCrossSectionFn(miter);
    try std.testing.expectApproxEqRel(@as(f64, 36), driver.driver.crossSectionAreaFn(miter), 1e-9);
    const shrunk = driver.driver.offsetFn(sq, -1, 1, 8, 2) orelse return error.OffsetFailed;
    defer driver.driver.destructCrossSectionFn(shrunk);
    try std.testing.expectApproxEqRel(@as(f64, 4), driver.driver.crossSectionAreaFn(shrunk), 1e-9);
    try std.testing.expect(driver.supports(.offset));
}

test "Driver: a closed path keeps its arcs, a rounded square its corners, exact; a cubic is chorded" {
    const path_mod = @import("../../../core/path.zig");
    // A stadium: a 4 by 2 rectangle with half-discs at its ends
    const stadium = [_]path_mod.Segment{
        .{ .to = .{ 4, 0 } },
        .{ .to = .{ 4, 2 }, .arc = .{ .center = .{ 4, 1 }, .radius = 1 }, .ccw = true, .angle = std.math.pi },
        .{ .to = .{ 0, 2 } },
        .{ .to = .{ 0, 0 }, .arc = .{ .center = .{ 0, 1 }, .radius = 1 }, .ccw = true, .angle = std.math.pi },
    };
    const slot = driver.driver.closedPathFn(&TEST_CONFIG, std.testing.allocator, .{ 0, 0 }, &stadium, &.{ 1, 8, 1, 8 }) orelse return error.PathFailed;
    defer driver.driver.destructCrossSectionFn(slot);
    try std.testing.expectApproxEqRel(8 + std.math.pi, driver.driver.crossSectionAreaFn(slot), 1e-9);
    // A full circle as one arc back to its start, and a path left open (closed straight)
    const ring = [_]path_mod.Segment{.{ .to = .{ 2, 0 }, .arc = .{ .center = .{ 0, 0 }, .radius = 2 }, .ccw = true, .angle = 2 * std.math.pi }};
    const disc = driver.driver.closedPathFn(&TEST_CONFIG, std.testing.allocator, .{ 2, 0 }, &ring, &.{16}) orelse return error.PathFailed;
    defer driver.driver.destructCrossSectionFn(disc);
    try std.testing.expectApproxEqRel(4 * std.math.pi, driver.driver.crossSectionAreaFn(disc), 1e-9);
    const open = [_]path_mod.Segment{ .{ .to = .{ 3, 0 } }, .{ .to = .{ 3, 4 } } };
    const tri = driver.driver.closedPathFn(&TEST_CONFIG, std.testing.allocator, .{ 0, 0 }, &open, &.{ 1, 1 }) orelse return error.PathFailed;
    defer driver.driver.destructCrossSectionFn(tri);
    try std.testing.expectApproxEqRel(@as(f64, 6), driver.driver.crossSectionAreaFn(tri), 1e-9);
    // A cubic curve is chorded by its count: a bulge of six straight pieces, within a
    // few percent of the curve's own area, 216/30 (y = 9t(1 − t), dx = −24t(1 − t) dt)
    const bowed = [_]path_mod.Segment{ .{ .to = .{ 4, 0 } }, .{ .to = .{ 0, 0 }, .cubic = .{ .c1 = .{ 4, 3 }, .c2 = .{ 0, 3 } } } };
    const bow = driver.driver.closedPathFn(&TEST_CONFIG, std.testing.allocator, .{ 0, 0 }, &bowed, &.{ 1, 6 }) orelse return error.PathFailed;
    defer driver.driver.destructCrossSectionFn(bow);
    const bow_area = driver.driver.crossSectionAreaFn(bow);
    try std.testing.expect(bow_area > 7.2 * 0.95 and bow_area < 7.2);
    // A 4 by 2 rectangle with corners of radius a half: 8 − (4 − π) r²; and a stadium by
    // a radius of half the short side; a radius of nothing is the rectangle
    const rounded = driver.driver.roundedSquareFn(&TEST_CONFIG, std.testing.allocator, .{ .x = 4, .y = 2, .center = false, .radius = 0.5, .segments = 16 }) orelse return error.RoundedFailed;
    defer driver.driver.destructCrossSectionFn(rounded);
    try std.testing.expectApproxEqRel(8 - (4 - std.math.pi) * 0.25, driver.driver.crossSectionAreaFn(rounded), 1e-9);
    const capsule = driver.driver.roundedSquareFn(&TEST_CONFIG, std.testing.allocator, .{ .x = 4, .y = 2, .center = true, .radius = 1, .segments = 16 }) orelse return error.RoundedFailed;
    defer driver.driver.destructCrossSectionFn(capsule);
    try std.testing.expectApproxEqRel(4 + std.math.pi, driver.driver.crossSectionAreaFn(capsule), 1e-9);
    const plain = driver.driver.roundedSquareFn(&TEST_CONFIG, std.testing.allocator, .{ .x = 4, .y = 2, .center = false, .radius = 0, .segments = 16 }) orelse return error.RoundedFailed;
    defer driver.driver.destructCrossSectionFn(plain);
    try std.testing.expectApproxEqRel(@as(f64, 8), driver.driver.crossSectionAreaFn(plain), 1e-9);
}

test "Driver: a sketch's hull, contours, containment and convexity" {
    const sq = driver.driver.squareFn(&TEST_CONFIG, 2, 2, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq);
    const far = driver.driver.crossSectionTransformFn(sq, .{ 1, 0, 0, 1, 5, 1 }) orelse return error.TransformFailed;
    defer driver.driver.destructCrossSectionFn(far);
    const both = driver.driver.crossSectionHullFn(std.testing.allocator, &.{ sq, far }) orelse return error.HullFailed;
    defer driver.driver.destructCrossSectionFn(both);
    try std.testing.expectApproxEqRel(@as(f64, 16), driver.driver.crossSectionAreaFn(both), 1e-9);
    try std.testing.expectEqual(true, driver.driver.crossSectionIsConvexFn(both));
    try std.testing.expectEqual(true, driver.driver.crossSectionContainsPointFn(both, .{ 3, 1.5 }, 1e-9));
    try std.testing.expectEqual(false, driver.driver.crossSectionContainsPointFn(both, .{ 3, 2.9 }, 1e-9));

    const disc = driver.driver.circleFn(&TEST_CONFIG, 2, 0) orelse return error.CircleFailed;
    defer driver.driver.destructCrossSectionFn(disc);
    const contours = driver.driver.crossSectionContoursFn(disc, std.testing.allocator) orelse return error.ContoursFailed;
    defer std.testing.allocator.free(contours.points);
    defer std.testing.allocator.free(contours.starts);
    try std.testing.expectEqual(@as(usize, 1), contours.count());
    // Each of the circle's two halves gets its share of the segments a full circle has at
    // the test settings' resolution, rounded up (an odd count can't be halved), every
    // point on the circle
    const per_turn = TEST_CONFIG.segmentsFor(2);
    try std.testing.expectEqual(@as(usize, 2 * ((per_turn + 1) / 2)), contours.points.len);
    for (contours.points) |p| try std.testing.expectApproxEqAbs(@as(f64, 2), @sqrt(p[0] * p[0] + p[1] * p[1]), 1e-12);
    try std.testing.expect(driver.supports(.sketch_hull));
    try std.testing.expect(driver.supports(.sketch_contours));
}

test "Driver: transforms keep the topology and move the box; the matrix is column-major" {
    const cube = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, false) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube);

    const moved = driver.driver.translateFn(cube, 10, 0, 0) orelse return error.TranslateFailed;
    defer driver.driver.destructFn(moved);
    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(moved));
    try std.testing.expectEqual([3]f64{ 10, 0, 0 }, (try boxOf(moved)).min);

    // The images of the axes, then the translation: a move by 20 along x
    const matrix = [12]f64{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 20, 0, 0 };
    const transformed = driver.driver.transformMatrixFn(cube, matrix) orelse return error.TransformFailed;
    defer driver.driver.destructFn(transformed);
    try std.testing.expectEqual([3]f64{ 20, 0, 0 }, (try boxOf(transformed)).min);

    // Rotations about x, then y, then z, in degrees: 90° about z takes the box to −y
    const turned = driver.driver.rotateFn(cube, 0, 0, 90) orelse return error.RotateFailed;
    defer driver.driver.destructFn(turned);
    const tbox = try boxOf(turned);
    try std.testing.expectApproxEqAbs(@as(f64, -10), tbox.min[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10), tbox.max[1], 1e-12);

    const scaled = driver.driver.scaleFn(cube, 2, 2, 2) orelse return error.ScaleFailed;
    defer driver.driver.destructFn(scaled);
    try std.testing.expectEqual([3]f64{ 20, 20, 20 }, (try boxOf(scaled)).max);

    const mirrored = driver.driver.mirrorFn(cube, 1, 0, 0) orelse return error.MirrorFailed;
    defer driver.driver.destructFn(mirrored);
    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(mirrored));
    try std.testing.expectEqual([3]f64{ -10, 0, 0 }, (try boxOf(mirrored)).min);
    for (bodyOf(mirrored).faces.items) |f| try std.testing.expect(!f.same_sense);

    // A non-uniform scale keeps a box exact and refuses a cylinder
    const stretched = driver.driver.scaleFn(cube, 2, 1, 1) orelse return error.ScaleFailed;
    defer driver.driver.destructFn(stretched);
    try std.testing.expectEqual([3]f64{ 20, 10, 10 }, (try boxOf(stretched)).max);
    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 5, 5, 15, true, 32) orelse return error.CylinderFailed;
    defer driver.driver.destructFn(cyl);
    try std.testing.expect(driver.driver.scaleFn(cyl, 2, 1, 1) == null);
    try std.testing.expect(driver.supports(.transform));
    // The refusal's reason is kept for the script's error, once
    const why = driver.driver.takeFailureFn() orelse return error.NoReason;
    try std.testing.expect(std.mem.indexOf(u8, why, "non-uniform scale") != null);
    try std.testing.expect(driver.driver.takeFailureFn() == null);

    // A sketch moved in the plane
    const sq = driver.driver.squareFn(&TEST_CONFIG, 10, 10, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq);
    const moved_sq = driver.driver.crossSectionTransformFn(sq, .{ 1, 0, 0, 1, 5, 5 }) orelse return error.TransformFailed;
    defer driver.driver.destructCrossSectionFn(moved_sq);
    const sq_box = driver.driver.crossSectionBoundsFn(moved_sq) orelse return error.NoBounds;
    try std.testing.expectEqual([2]f64{ 5, 5 }, sq_box.min);
    try std.testing.expectEqual([2]f64{ 15, 15 }, sq_box.max);
}

test "Driver: a trace sink set on the thread receives each operation's phases, until unset" {
    const Count = struct {
        var phases: usize = 0;
        fn write(_: ?*anyopaque, operation: []const u8, phase: []const u8, body_json: []const u8) void {
            std.debug.assert(std.mem.eql(u8, operation, "transform"));
            std.debug.assert(std.mem.eql(u8, phase, "arguments") or std.mem.eql(u8, phase, "mapped") or std.mem.eql(u8, phase, "checked"));
            std.debug.assert(std.mem.startsWith(u8, body_json, "{"));
            phases += 1;
        }
    };
    const cube = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, false) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube);
    driver.setTrace(.{ .write = Count.write });
    const moved = driver.driver.translateFn(cube, 1, 0, 0) orelse return error.TranslateFailed;
    defer driver.driver.destructFn(moved);
    driver.setTrace(null);
    try std.testing.expectEqual(@as(usize, 3), Count.phases);
    const again = driver.driver.translateFn(cube, 1, 0, 0) orelse return error.TranslateFailed;
    defer driver.driver.destructFn(again);
    try std.testing.expectEqual(@as(usize, 3), Count.phases);
}

test "Driver: a polyhedron from triangles, and polygons by the even-odd rule" {
    const pts = [_][3]f64{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 } };
    const faces = [_][3]u32{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 } };
    const poly = driver.driver.polyhedronFn(&TEST_CONFIG, std.testing.allocator, &pts, &faces) orelse return error.PolyhedronFailed;
    defer driver.driver.destructFn(poly);
    try std.testing.expectEqual(@as(usize, 5), driver.driver.numVertsFn(poly));
    // A bad index is refused
    try std.testing.expect(driver.driver.polyhedronFn(&TEST_CONFIG, std.testing.allocator, &pts, &.{.{ 0, 1, 9 }}) == null);

    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };
    const cs = driver.driver.polygonsEvenOddFn(&TEST_CONFIG, std.testing.allocator, &contours) orelse return error.EvenOddFailed;
    defer driver.driver.destructCrossSectionFn(cs);
    // The 20 mm square less the 10 mm hole: one face of an outline and a hole, all eight corners
    try std.testing.expectEqual(@as(usize, 8), driver.driver.crossSectionNumVertsFn(cs));
    try std.testing.expectEqual(@as(usize, 2), bodyOf(cs).counts().loops);
    try std.testing.expectEqual(@as(usize, 1), bodyOf(cs).counts().faces);
    // A clockwise polygon is the same face as its reverse
    const cw = driver.driver.polygonFn(&TEST_CONFIG, std.testing.allocator, &.{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 } }) orelse return error.PolygonFailed;
    defer driver.driver.destructCrossSectionFn(cw);
    try std.testing.expectEqual(@as(usize, 3), driver.driver.crossSectionNumVertsFn(cw));
    const circle = driver.driver.circleFn(&TEST_CONFIG, 4, 32) orelse return error.CircleFailed;
    defer driver.driver.destructCrossSectionFn(circle);
    // Exact: two half-circle edges, whatever the segments
    try std.testing.expectEqual(@as(usize, 2), driver.driver.crossSectionNumVertsFn(circle));
    try std.testing.expectEqual([2]f64{ -4, -4 }, (driver.driver.crossSectionBoundsFn(circle) orelse return error.NoBounds).min);
}

test "Driver: convex hulls of flat solids, single and batch" {
    const cube1 = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube1);
    const hull1 = driver.driver.hullFn(cube1) orelse return error.Hull;
    defer driver.driver.destructFn(hull1);
    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(hull1));

    const cube2 = driver.driver.translateFn(cube1, 20, 0, 0) orelse return error.Translate;
    defer driver.driver.destructFn(cube2);
    const hull2 = driver.driver.batchHullFn(std.testing.allocator, &.{ cube1, cube2 }) orelse return error.Hull;
    defer driver.driver.destructFn(hull2);
    // Only the points the hull's faces use become its vertices: the eight outer corners
    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(hull2));
    const box = try boxOf(hull2);
    try std.testing.expectEqual([3]f64{ -5, -5, -5 }, box.min);
    try std.testing.expectEqual([3]f64{ 25, 5, 5 }, box.max);
}

test "Driver: STEP export of what it builds, every number exact; a mesh part refused" {
    const cube = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube);
    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 2.5, 2.5, 20, true, 16) orelse return error.CylFailed;
    defer driver.driver.destructFn(cyl);
    const step = try driver.exportStep(std.testing.allocator, &.{ cube, cyl });
    defer std.testing.allocator.free(step);
    try std.testing.expect(std.mem.startsWith(u8, step, "ISO-10303-21;"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, step, "MANIFOLD_SOLID_BREP("));
    try std.testing.expectEqual(@as(usize, 12), std.mem.count(u8, step, "VERTEX_POINT("));
    try std.testing.expect(std.mem.count(u8, step, "CIRCLE(") == 4);
    try std.testing.expect(std.mem.count(u8, step, ",2.5)") >= 4);
    try std.testing.expectError(error.NotExactGeometry, driver.exportStep(std.testing.allocator, &.{.{ .engine = .manifold, .ptr = cube.ptr }}));
    try std.testing.expectError(error.NoGeometry, driver.exportStep(std.testing.allocator, &.{}));
}

test "Driver: no-op operations return new handles, never their input" {
    const cube = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, false) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cube);
    const mat = driver.driver.setMaterialFn(cube, 1) orelse return error.KernelFailed;
    defer driver.driver.destructFn(mat);
    try std.testing.expect(mat.ptr != cube.ptr);
    const simp = driver.driver.simplifyFn(cube, 0.01) orelse return error.KernelFailed;
    defer driver.driver.destructFn(simp);
    try std.testing.expect(simp.ptr != cube.ptr);
    const parts = driver.driver.decomposeFn(std.testing.allocator, cube) orelse return error.KernelFailed;
    defer {
        for (parts) |p| driver.driver.destructFn(p);
        std.testing.allocator.free(parts);
    }
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expect(parts[0].ptr != cube.ptr);
    const single = driver.driver.batchBooleanFn(std.testing.allocator, &.{cube}, .union_op) orelse return error.KernelFailed;
    defer driver.driver.destructFn(single);
    try std.testing.expect(single.ptr != cube.ptr);
}

test "Driver: unsupported operations report null, never a stand-in result" {
    const sq = driver.driver.squareFn(&TEST_CONFIG, 10, 10, false) orelse return error.KernelFailed;
    defer driver.driver.destructCrossSectionFn(sq);
    const cube = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, false) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cube);
    try std.testing.expect(driver.driver.booleanFn(cube, cube, .difference_op) == null);
    try std.testing.expect(driver.driver.batchBooleanFn(std.testing.allocator, &.{ cube, cube }, .union_op) == null);
    try std.testing.expect(driver.driver.sliceFn(cube, 5) == null);
    try std.testing.expect(driver.driver.projectFn(cube) == null);
    try std.testing.expect(driver.driver.trimByPlaneFn(cube, 0, 0, 1, 5) == null);
    try std.testing.expect(driver.driver.containsPointFn(std.testing.allocator, cube, &TEST_CONFIG, .{ 1, 1, 1 }) == null);
    try std.testing.expect(driver.driver.rayCastFn(std.testing.allocator, cube, .{ 5, 5, -5 }, .{ 5, 5, 15 }) == null);
    try std.testing.expect(driver.driver.queryFacesFn(std.testing.allocator, cube, .{ 0, 0, 1 }, 0.01) == null);
    try std.testing.expect(!driver.supports(.boolean));
    try std.testing.expect(driver.driver.problemFn(cube) == null);
}

test "Driver: the mesh of a cube and of a cylinder, the cylinder's on the mesh engine's circle grid, closed; a swept face refused" {
    const cube = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, false) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cube);
    const box_mesh = driver.driver.getMeshFn(std.testing.allocator, cube) orelse return error.KernelFailed;
    defer std.testing.allocator.free(box_mesh.vert_props);
    defer std.testing.allocator.free(box_mesh.tri_verts);
    try std.testing.expectEqual(@as(usize, 3), box_mesh.num_prop);
    try std.testing.expectEqual(@as(usize, 8 * 3), box_mesh.vert_props.len);
    try std.testing.expectEqual(@as(usize, 12 * 3), box_mesh.tri_verts.len);
    try std.testing.expectEqual(@as(?usize, 12), driver.driver.numTrisFn(cube));
    // A cylinder of radius 5: 16 segments at the default resolution (by length), the
    // `segments:` given ignored as the exact engine does; two circles of 16 vertices
    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 5, 5, 15, false, 32) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cyl);
    const n = TEST_CONFIG.segmentsFor(5);
    try std.testing.expectEqual(@as(u32, 16), n);
    const mesh = driver.driver.getMeshFn(std.testing.allocator, cyl) orelse return error.KernelFailed;
    defer std.testing.allocator.free(mesh.vert_props);
    defer std.testing.allocator.free(mesh.tri_verts);
    try std.testing.expectEqual(@as(usize, 2 * n * 3), mesh.vert_props.len);
    try std.testing.expectEqual(@as(usize, (4 * n - 4) * 3), mesh.tri_verts.len);
    try std.testing.expectEqual(@as(?usize, 4 * n - 4), driver.driver.numTrisFn(cyl));
    // Closed: every directed edge once each way
    var directed: std.AutoHashMapUnmanaged([2]u32, void) = .empty;
    defer directed.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < mesh.tri_verts.len) : (i += 3) {
        for (0..3) |k| {
            const entry = try directed.getOrPut(std.testing.allocator, .{ mesh.tri_verts[i + k], mesh.tri_verts[i + (k + 1) % 3] });
            try std.testing.expect(!entry.found_existing);
        }
    }
    var it = directed.keyIterator();
    while (it.next()) |edge| try std.testing.expect(directed.contains(.{ edge[1], edge[0] }));
    // Every vertex on the cylinder, in single precision
    var v: usize = 0;
    while (v < mesh.vert_props.len) : (v += 3) {
        const x = mesh.vert_props[v];
        const y = mesh.vert_props[v + 1];
        try std.testing.expectApproxEqAbs(@as(f32, 5), @sqrt(x * x + y * y), 1e-5);
    }
    try std.testing.expect(driver.supports(.mesh));
}

test "Driver: a preview mesh is bounded for a large part and marked, the part's own for a small one, and the meshes are kept" {
    // A sphere of radius 30 at a fine resolution: 1200 segments a turn, a mesh of some
    // 719k points at the part's resolution; the preview budget bounds it
    const fine: EngineConfig = .{ .engine = .brep_native, .resolution = .{ .min_angle = 0.3, .min_length = 0.02 } };
    const ball = driver.driver.sphereFn(&fine, 30, 0) orelse return error.KernelFailed;
    defer driver.driver.destructFn(ball);
    const preview = driver.driver.getPreviewMeshFn(std.testing.allocator, ball) orelse return error.KernelFailed;
    defer std.testing.allocator.free(preview.vert_props);
    defer std.testing.allocator.free(preview.tri_verts);
    try std.testing.expect(preview.provisional);
    const points = preview.vert_props.len / 3;
    try std.testing.expect(points > 1000 and points <= driver.PREVIEW_BUDGET.points_per_body + 4 * driver.PREVIEW_BUDGET.points_per_edge + 2);
    try std.testing.expect(driver.previewIsProvisional(ball));
    // Every preview vertex on the sphere
    var v: usize = 0;
    while (v < preview.vert_props.len) : (v += 3) {
        const x = preview.vert_props[v];
        const y = preview.vert_props[v + 1];
        const z = preview.vert_props[v + 2];
        try std.testing.expectApproxEqAbs(@as(f32, 30), @sqrt(x * x + y * y + z * z), 1e-3);
    }
    // A small part's preview is its own mesh, kept for the export and the count
    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 5, 5, 15, false, 0) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cyl);
    const first = driver.driver.getPreviewMeshFn(std.testing.allocator, cyl) orelse return error.KernelFailed;
    defer std.testing.allocator.free(first.vert_props);
    defer std.testing.allocator.free(first.tri_verts);
    try std.testing.expect(!first.provisional);
    try std.testing.expect(!driver.previewIsProvisional(cyl));
    const full = driver.driver.getMeshFn(std.testing.allocator, cyl) orelse return error.KernelFailed;
    defer std.testing.allocator.free(full.vert_props);
    defer std.testing.allocator.free(full.tri_verts);
    try std.testing.expectEqualSlices(u32, first.tri_verts, full.tri_verts);
    try std.testing.expectEqualSlices(f32, first.vert_props, full.vert_props);
    try std.testing.expectEqual(@as(?usize, full.tri_verts.len / 3), driver.driver.numTrisFn(cyl));
}

test "BRep Driver: solids keep the tolerance they were built under, and pass it on" {
    var config = TEST_CONFIG;
    config.tolerance = 1e-3;
    config.brep.max_newton_trials = 7;
    const cube = driver.driver.cubeFn(&config, 10, 10, 10, false) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cube);
    const moved = driver.driver.translateFn(cube, 5, 0, 0) orelse return error.KernelFailed;
    defer driver.driver.destructFn(moved);
    for ([_]geom.GeometryHandle{ cube, moved }) |h| {
        const solid: *driver.BrepSolid = @ptrCast(@alignCast(h.ptr));
        try std.testing.expectEqual(@as(f64, 1e-3), solid.body.tol.zone);
        try std.testing.expectEqual(@as(f64, 2e-3), solid.body.tol.xsect);
        try std.testing.expectEqual(@as(u32, 7), solid.settings.limits.newton_trials);
    }
}

test "BRep Driver: a clone is the same solid, curved surfaces included" {
    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 5, 5, 10, false, 0) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cyl);
    const copy = driver.driver.cloneFn(cyl) orelse return error.KernelFailed;
    defer driver.driver.destructFn(copy);
    try std.testing.expect(copy.ptr != cyl.ptr);
    const original_step = try driver.exportStep(std.testing.allocator, &.{cyl});
    defer std.testing.allocator.free(original_step);
    const copy_step = try driver.exportStep(std.testing.allocator, &.{copy});
    defer std.testing.allocator.free(copy_step);
    try std.testing.expectEqualStrings(original_step, copy_step);
}

test "Driver: Locus's parallel loop runs on oneTBB whenever the build has it" {
    // parallel_for tested a flag only Manifold's sources were compiled with, so Locus ran
    // every parallel loop on one thread although oneTBB was linked in.
    const parallel_binding = @import("../../../bindings/parallel.zig");
    try std.testing.expectEqual(@import("build_info").tbb, parallel_binding.spreadsOverThreads());
    try std.testing.expectEqual(@import("build_info").tbb, driver.parallel.threads() > 1);
    if (!parallel_binding.spreadsOverThreads() or (std.Thread.getCpuCount() catch 1) < 2) return error.SkipZigTest;
    // Each index waits until a second thread has run one: on oneTBB's threads the waiting one
    // holds its worker, and another takes the rest of the range, however busy the machine
    const Meeting = struct {
        /// How many times an index waits (yielding) for another thread to run one: long
        /// past any scheduler's delay, and bounded, so a loop on one thread fails rather
        /// than hangs.
        const MAX_WAITS = 10_000_000;
        first: std.atomic.Value(std.Thread.Id) = .init(0),
        met: std.atomic.Value(bool) = .init(false),

        fn visit(_: usize, self: *@This()) void {
            const id = std.Thread.getCurrentId();
            if (self.first.cmpxchgStrong(0, id, .acq_rel, .acquire)) |first| {
                if (first != id) self.met.store(true, .release);
            }
            var waits: usize = 0;
            while (!self.met.load(.acquire) and waits < MAX_WAITS) : (waits += 1) std.Thread.yield() catch {};
        }
    };
    var meeting: Meeting = .{};
    driver.parallel.forRange(0, 1024, Meeting, &meeting, Meeting.visit);
    try std.testing.expect(meeting.met.load(.acquire));
}
