const std = @import("std");
const driver = @import("driver.zig");
const geom = @import("../../../core/geometry_handle.zig");
const step_exporter = @import("../../../exporters/3d/step.zig");
const EngineConfig = @import("../../../core/engine_config.zig").EngineConfig;

const TEST_CONFIG: EngineConfig = .{ .engine = .brep_native };

test "Driver: End-to-End API Calls" {
    // Verifies creation, transformation, and destruction of basic 3D B-Rep primitives
    const cube_handle = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const cyl_handle = driver.driver.cylinderFn(&TEST_CONFIG, 5, 5, 15, true, 32) orelse return error.CylinderFailed;
    defer driver.driver.destructFn(cyl_handle);

    const sphere_handle = driver.driver.sphereFn(&TEST_CONFIG, 5, 0) orelse return error.SphereFailed;
    defer driver.driver.destructFn(sphere_handle);

    // Ensure translation succeeds on a valid B-Rep handle
    const trans_handle = driver.driver.translateFn(cube_handle, 10.0, 0.0, 0.0) orelse return error.TranslateFailed;
    defer driver.driver.destructFn(trans_handle);

    // Verify vertex count on working cube primitive
    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(cube_handle));
}

test "Driver: Custom Matrix Transformations" {
    // Verifies 4x4 row-major affine transformation matrix application
    const cube_handle = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const translation_matrix = [12]f64{
        1, 0, 0, 20,
        0, 1, 0, 0,
        0, 0, 1, 0,
    };
    const transformed = driver.driver.transformMatrixFn(cube_handle, translation_matrix) orelse return error.TransformFailed;
    defer driver.driver.destructFn(transformed);

    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(transformed));
}

test "Driver: Mirror Solid" {
    const cube_handle = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, false) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const mirrored_handle = driver.driver.mirrorFn(cube_handle, 1, 0, 0) orelse return error.MirrorFailed;
    defer driver.driver.destructFn(mirrored_handle);

    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(mirrored_handle));
}

// --- Mesh & Sweeps Import/Generation ---

test "Driver: Polyhedron Import (Mesh to B-Rep)" {
    const pts = [_][3]f64{
        .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 },
    };
    const faces = [_][3]u32{
        .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 },
    };
    const poly_handle = driver.driver.polyhedronFn(&TEST_CONFIG, std.testing.allocator, &pts, &faces) orelse return error.PolyhedronFailed;
    defer driver.driver.destructFn(poly_handle);

    try std.testing.expectEqual(@as(usize, 5), driver.driver.numVertsFn(poly_handle));
}

test "Driver: Revolve 2D Profile" {
    const cs_handle = driver.driver.squareFn(&TEST_CONFIG, 10.0, 10.0, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(cs_handle);

    const rev_handle = driver.driver.revolveFn(cs_handle, 36, 360.0) orelse return error.RevolveFailed;
    defer driver.driver.destructFn(rev_handle);

    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(rev_handle));
}

// --- 2D Cross Sections & Booleans ---

test "Driver: 2D Operations (Boolean, Transform)" {
    const sq1 = driver.driver.squareFn(&TEST_CONFIG, 10.0, 10.0, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq1);

    const sq2 = driver.driver.squareFn(&TEST_CONFIG, 10.0, 10.0, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(sq2);

    const mat = [6]f64{ 1, 0, 5, 0, 1, 5 };
    const transformed_sq2 = driver.driver.crossSectionTransformFn(sq2, mat) orelse return error.TransformFailed;
    defer driver.driver.destructCrossSectionFn(transformed_sq2);

    const union_2d = driver.driver.crossSectionBooleanFn(sq1, transformed_sq2, .union_op) orelse return error.BooleanFailed;
    defer driver.driver.destructCrossSectionFn(union_2d);

    const final_solid = driver.driver.extrudeFn(union_2d, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(final_solid);

    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(final_solid));
}

test "Driver: Polygons Even-Odd" {
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const cs_handle = driver.driver.polygonsEvenOddFn(&TEST_CONFIG, std.testing.allocator, &contours) orelse return error.EvenOddFailed;
    defer driver.driver.destructCrossSectionFn(cs_handle);

    const solid_handle = driver.driver.extrudeFn(cs_handle, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(solid_handle);

    const solid_ptr: *driver.BrepSolid = @ptrCast(@alignCast(solid_handle.ptr));
    try std.testing.expect(solid_ptr.t_arena.solids.items.len > 0);
}

// --- Projections & Slicing ---

test "Driver: Slice Solid to 2D" {
    const cyl = driver.driver.cylinderFn(&TEST_CONFIG, 5.0, 5.0, 20.0, true, 32) orelse return error.Cyl;
    defer driver.driver.destructFn(cyl);

    const cs = driver.driver.sliceFn(cyl, 0.0) orelse return error.Slice;
    defer driver.driver.destructCrossSectionFn(cs);

    const res = driver.driver.extrudeFn(cs, 10.0, 0, 0, 1.0, 1.0) orelse return error.Extrude;
    defer driver.driver.destructFn(res);

    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(res));
}

// --- Convex Hulls & Queries ---

test "Driver: Convex Hull (Single and Batch)" {
    const cube1 = driver.driver.cubeFn(&TEST_CONFIG, 10, 10, 10, true) orelse return error.Cube;
    defer driver.driver.destructFn(cube1);

    const hull1 = driver.driver.hullFn(cube1) orelse return error.Hull;
    defer driver.driver.destructFn(hull1);

    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(hull1));

    // Hull of two disjoint boxes along X is one box spanning both: 8 corners, from x = -5
    // to x = 25. (It used to be the first box alone: its points hid the second's.)
    const cube2 = driver.driver.translateFn(cube1, 20, 0, 0) orelse return error.Translate;
    defer driver.driver.destructFn(cube2);
    const hull2 = driver.driver.batchHullFn(std.testing.allocator, &.{ cube1, cube2 }) orelse return error.Hull;
    defer driver.driver.destructFn(hull2);

    try std.testing.expectEqual(@as(usize, 8), driver.driver.numVertsFn(hull2));
    const points = @as(*driver.BrepSolid, @ptrCast(@alignCast(hull2.ptr))).g_arena.points.items;
    var min_x: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    for (points) |p| {
        min_x = @min(min_x, p[0]);
        max_x = @max(max_x, p[0]);
    }
    try std.testing.expectEqual(@as(f64, -5), min_x);
    try std.testing.expectEqual(@as(f64, 25), max_x);
}

test "Driver: STEP Export of CSG Boolean Result" {
    const alloc = std.testing.allocator;

    const base = driver.driver.cubeFn(&TEST_CONFIG, 10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(base);

    const hole = driver.driver.cylinderFn(&TEST_CONFIG, 2.5, 2.5, 20.0, true, 16) orelse return error.CylFailed;
    defer driver.driver.destructFn(hole);

    const result = driver.driver.booleanFn(base, hole, .difference_op) orelse return error.BoolFailed;
    defer driver.driver.destructFn(result);

    const handles = [_]geom.GeometryHandle{result};
    const step_bytes = try step_exporter.buildStepBuffer(alloc, &handles);
    defer alloc.free(step_bytes);

    try std.testing.expect(std.mem.find(u8, step_bytes, "ISO-10303-21;") != null);
}

// --- Handle Ownership ---

test "Driver: No-op Ops Return New Handles, Never Their Input" {
    // Drivers must never return their input handle (single-owner rule).
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
    for (parts) |p| try std.testing.expect(p.ptr != cube.ptr);

    const single = driver.driver.batchBooleanFn(std.testing.allocator, &.{cube}, .union_op) orelse return error.KernelFailed;
    defer driver.driver.destructFn(single);
    try std.testing.expect(single.ptr != cube.ptr);
}

test "Driver: unsupported or failed B-Rep operations report null, never a stand-in result" {
    // offset is unimplemented; it used to return the unchanged sketch (silently wrong).
    const sq = driver.driver.squareFn(&TEST_CONFIG, 10, 10, false) orelse return error.KernelFailed;
    defer driver.driver.destructCrossSectionFn(sq);
    try std.testing.expect(driver.driver.offsetFn(sq, 1, 0, 8, 2) == null);
    // Nor contours, which Locus doesn't expose yet
    try std.testing.expect(driver.driver.crossSectionContoursFn(sq, std.testing.allocator) == null);
    try std.testing.expect(!driver.supports(.sketch_contours));
}

test "BRep Driver: solids keep the tolerance they were built under, and pass it on" {
    // Every operation used Locus's default tolerances, whatever CAD.config said.
    const config: EngineConfig = .{ .engine = .brep_native, .tolerance = 1e-3, .resolution = .{ .segments = 12 }, .brep = .{ .max_newton_trials = 7 } };
    const cube = driver.driver.cubeFn(&config, 10, 10, 10, false) orelse return error.KernelFailed;
    defer driver.driver.destructFn(cube);
    const moved = driver.driver.translateFn(cube, 5, 0, 0) orelse return error.KernelFailed;
    defer driver.driver.destructFn(moved);

    for ([_]geom.GeometryHandle{ cube, moved }) |h| {
        const env = @as(*driver.BrepSolid, @ptrCast(@alignCast(h.ptr))).env;
        try std.testing.expectEqual(@as(f64, 1e-3), env.vertex_tolerance);
        try std.testing.expectEqual(@as(f64, 1e-6), env.vertex_tol_sq); // the hot-loop square follows it
        try std.testing.expectEqual(@as(f64, 1e-3), env.sewing_tolerance);
        try std.testing.expectEqual(@as(u32, 12), env.resolution.segments);
        try std.testing.expectEqual(@as(u32, 7), env.max_newton_trials);
    }
}

test "BRep Driver: a mesh copy leaves nothing allocated when an allocation fails" {
    // getMesh leaked the vertices when allocating the triangles failed. (Locus tessellates
    // its solids to empty meshes for now, so the copy is tested on a mesh built here.)
    const locus_tess = @import("../../../locus/src/operations/tessellate.zig");
    var mesh = locus_tess.Mesh{};
    defer mesh.deinit(std.testing.allocator);
    try mesh.vertices.appendSlice(std.testing.allocator, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } });
    try mesh.triangles.append(std.testing.allocator, .{ 0, 1, 2 });

    const copy = try driver.copyMesh(std.testing.allocator, &mesh);
    defer std.testing.allocator.free(copy.vert_props);
    defer std.testing.allocator.free(copy.tri_verts);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 1, 0, 0, 0, 1, 0 }, copy.vert_props);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, copy.tri_verts);

    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, driver.copyMesh(failing.allocator(), &mesh));
    }
}

test "BRep Driver: a clone is the same solid, curved surfaces included" {
    // Clones went through an identity transform, which copies only points, lines and
    // planes: a cylinder's copy lost its curved face and failed STEP export.
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
    const locus = @import("../../../locus/src/root.zig");
    try std.testing.expectEqual(@import("build_info").tbb, locus.parallel.spreadsOverThreads());
}
