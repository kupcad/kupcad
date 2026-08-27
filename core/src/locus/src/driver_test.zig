const std = @import("std");
const driver = @import("driver.zig");

test "Driver: End-to-End API Calls" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    const cyl_handle = driver.driver.cylinderFn(5, 15, true) orelse return error.CylinderFailed;
    const sphere_handle = driver.driver.sphereFn(5) orelse return error.SphereFailed;

    try std.testing.expectEqual(@as(usize, 0), cube_handle);
    try std.testing.expectEqual(@as(usize, 1), cyl_handle);
    try std.testing.expectEqual(@as(usize, 2), sphere_handle);

    // 4. Test a transform
    const translated_handle = driver.driver.translateFn(cube_handle, 10.0, 0.0, 0.0) orelse return error.TranslateFailed;

    // Because it modifies in-place, the handle remains 0
    try std.testing.expectEqual(@as(usize, 0), translated_handle);

    // 5. Test the Meshing Pipeline
    const mesh_data = driver.driver.getMeshFn(cube_handle) orelse return error.MeshingFailed;

    // The tessellator pushes all vertices from the shared topology arena:
    // Cube (8) + Cylinder (32) + Sphere (32) = 72 vertices.
    // 72 vertices * 3 floats = 216 floats.
    try std.testing.expectEqual(@as(usize, 216), mesh_data.vertex_len);
}

test "Driver: Measurements (Volume, Surface Area, Bounding Box, Contains)" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    // Generate a 10x10x10 cube, centered at the origin
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;

    // 1. Bounding Box
    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    // A 10-unit centered cube goes from -5 to +5 on all axes
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[0], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, bbox.max[0], 1e-6);

    // 2. Volume
    const vol = driver.driver.volumeFn(cube_handle);
    // 10 * 10 * 10 = 1000
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-6);

    // 3. Surface Area
    const area = driver.driver.surfaceAreaFn(cube_handle);
    // 6 faces * (10 * 10) = 600
    try std.testing.expectApproxEqAbs(600.0, area, 1e-6);

    // 4. Contains Point Raycaster
    const is_inside = driver.driver.containsPointFn(cube_handle, .{ 0, 0, 0 });
    const is_outside = driver.driver.containsPointFn(cube_handle, .{ 20, 0, 0 });

    try std.testing.expect(is_inside);
    try std.testing.expect(!is_outside);
}

test "Driver: Custom Matrix Transformations" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;

    // Define a 4x4 Translation Matrix (flattened to the 12 active floats).
    // We are translating by +20 units on the X-axis.
    // Layout: [ R00, R01, R02, TX,
    //           R10, R11, R12, TY,
    //           R20, R21, R22, TZ ]
    const translation_matrix = [12]f64{
        1, 0, 0, 20,
        0, 1, 0, 0,
        0, 0, 1, 0,
    };

    const transformed_handle = driver.driver.transformMatrixFn(cube_handle, translation_matrix) orelse return error.TransformFailed;

    // Validate the new position using the Bounding Box
    const bbox = driver.driver.boundingBoxFn(transformed_handle) orelse return error.BBoxFailed;

    // Original X max was 5.0. Plus 20 = 25.0
    try std.testing.expectApproxEqAbs(25.0, bbox.max[0], 1e-6);
}

test "Driver: Trim by Plane (Half-Space Slicing)" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    // Generate a 10x10x10 cube, centered at origin (-5 to +5 on all axes)
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;

    // Slice it perfectly in half down the Z=0 plane.
    // Normal = (0, 0, 1), offset = 0.
    // We expect the top half (+Z) to be discarded, leaving -5 to 0 on the Z axis.
    const sliced_handle = driver.driver.trimByPlaneFn(cube_handle, 0, 0, 1, 0.0) orelse return error.TrimFailed;

    // Validate using the bounding box
    const bbox = driver.driver.boundingBoxFn(sliced_handle) orelse return error.BBoxFailed;

    // The Z max should now be perfectly 0.0, while Z min remains -5.0
    try std.testing.expectApproxEqAbs(0.0, bbox.max[2], 1e-6);
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[2], 1e-6);

    // Volume of a 10x10x5 box should be exactly 500
    const vol = driver.driver.volumeFn(sliced_handle);
    try std.testing.expectApproxEqAbs(500.0, vol, 1e-5);
}

test "Driver: Polyhedron Import (Mesh to B-Rep)" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    // 10x10 square-based pyramid, height 10
    const pts = [_][3]f64{
        .{ 0, 0, 0 },
        .{ 10, 0, 0 },
        .{ 10, 10, 0 },
        .{ 0, 10, 0 },
        .{ 5, 5, 10 },
    };

    const faces = [_][3]u32{
        .{ 0, 3, 2 }, .{ 0, 2, 1 },
        .{ 0, 1, 4 }, .{ 1, 2, 4 },
        .{ 2, 3, 4 }, .{ 3, 0, 4 },
    };

    const poly_handle = driver.driver.polyhedronFn(std.testing.allocator, &pts, &faces) orelse return error.PolyhedronFailed;
    try std.testing.expectApproxEqAbs(333.333333, driver.driver.volumeFn(poly_handle), 1e-4);
}

test "Driver: Revolve 2D Profile" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    const cs_handle = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    const rev_handle = driver.driver.revolveFn(cs_handle, 36, 360.0) orelse return error.RevolveFailed;

    const expected_area = 1800.0 * @sin(10.0 * std.math.pi / 180.0);
    const expected_vol = expected_area * 10.0;

    try std.testing.expectApproxEqAbs(expected_vol, driver.driver.volumeFn(rev_handle), 1e-4);
}

test "Driver: 2D Operations (Boolean, Transform, Offset)" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    const sq1 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    const sq2 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;

    const mat = [6]f64{ 1, 0, 5, 0, 1, 5 };
    _ = driver.driver.crossSectionTransformFn(sq2, mat) orelse return error.TransformFailed;

    const union_2d = driver.driver.crossSectionBooleanFn(sq1, sq2, 0) orelse return error.BooleanFailed;
    const final_solid = driver.driver.extrudeFn(union_2d, 0, 0, 10) orelse return error.ExtrudeFailed;

    try std.testing.expectApproxEqAbs(1750.0, driver.driver.volumeFn(final_solid), 1e-4);
}

test "Driver: 2D Boolean Difference and Intersection" {
    driver.init(std.testing.allocator);
    defer driver.deinit();

    const mat = [6]f64{ 1, 0, 5, 0, 1, 5 };

    // --- INTERSECTION ---
    const sq1 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    const sq2 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    _ = driver.driver.crossSectionTransformFn(sq2, mat) orelse return error.TransformFailed;

    const inter_2d = driver.driver.crossSectionBooleanFn(sq1, sq2, 2) orelse return error.BooleanFailed;
    const inter_solid = driver.driver.extrudeFn(inter_2d, 0, 0, 10) orelse return error.ExtrudeFailed;

    try std.testing.expectApproxEqAbs(250.0, driver.driver.volumeFn(inter_solid), 1e-4);

    // --- DIFFERENCE ---
    const sq3 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    const sq4 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    _ = driver.driver.crossSectionTransformFn(sq4, mat) orelse return error.TransformFailed;

    const diff_2d = driver.driver.crossSectionBooleanFn(sq3, sq4, 1) orelse return error.BooleanFailed;
    const diff_solid = driver.driver.extrudeFn(diff_2d, 0, 0, 10) orelse return error.ExtrudeFailed;

    try std.testing.expectApproxEqAbs(750.0, driver.driver.volumeFn(diff_solid), 1e-4);
}
