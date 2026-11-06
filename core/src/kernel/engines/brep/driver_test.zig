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
    // A cone is refused (supports(.cone) is false): never a plain cylinder in its place
    try std.testing.expect(driver.driver.cylinderFn(&TEST_CONFIG, 5, 2, 15, true, 32) == null);
    // Spheres are not built yet
    try std.testing.expect(driver.driver.sphereFn(&TEST_CONFIG, 5, 0) == null);
    try std.testing.expect(!driver.supports(.sphere));
    // Bad arguments are refused, nothing kept
    try std.testing.expect(driver.driver.cubeFn(&TEST_CONFIG, 0, 10, 10, true) == null);
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
            std.debug.assert(std.mem.eql(u8, phase, "mapped") or std.mem.eql(u8, phase, "checked"));
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
    try std.testing.expectEqual(@as(usize, 2), Count.phases);
    const again = driver.driver.translateFn(cube, 1, 0, 0) orelse return error.TranslateFailed;
    defer driver.driver.destructFn(again);
    try std.testing.expectEqual(@as(usize, 2), Count.phases);
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
    try std.testing.expect(driver.driver.offsetFn(sq, 1, 0, 8, 2) == null);
    try std.testing.expect(driver.driver.crossSectionContoursFn(sq, std.testing.allocator) == null);
    try std.testing.expect(driver.driver.extrudeFn(sq, 10, 0, 0, 1, 1) == null);
    try std.testing.expect(driver.driver.revolveFn(sq, 36, 360) == null);
    try std.testing.expect(driver.driver.booleanFn(cube, cube, .difference_op) == null);
    try std.testing.expect(driver.driver.batchBooleanFn(std.testing.allocator, &.{ cube, cube }, .union_op) == null);
    try std.testing.expect(driver.driver.sliceFn(cube, 5) == null);
    try std.testing.expect(driver.driver.projectFn(cube) == null);
    try std.testing.expect(driver.driver.trimByPlaneFn(cube, 0, 0, 1, 5) == null);
    try std.testing.expect(driver.driver.containsPointFn(std.testing.allocator, cube, &TEST_CONFIG, .{ 1, 1, 1 }) == null);
    try std.testing.expect(driver.driver.rayCastFn(std.testing.allocator, cube, .{ 5, 5, -5 }, .{ 5, 5, 15 }) == null);
    try std.testing.expect(driver.driver.queryFacesFn(std.testing.allocator, cube, .{ 0, 0, 1 }, 0.01) == null);
    try std.testing.expect(!driver.supports(.sketch_contours));
    try std.testing.expect(driver.driver.problemFn(cube) == null);
    // The mesh of a B-Rep part is empty until tessellation lands: a viewer draws nothing
    const mesh = driver.driver.getMeshFn(std.testing.allocator, cube) orelse return error.KernelFailed;
    defer std.testing.allocator.free(mesh.vert_props);
    defer std.testing.allocator.free(mesh.tri_verts);
    try std.testing.expectEqual(@as(usize, 0), mesh.tri_verts.len);
    try std.testing.expect(driver.driver.numTrisFn(cube) == null);
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
        try std.testing.expectEqual(@as(u32, 7), solid.limits.newton_trials);
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
