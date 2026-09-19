// const std = @import("std");
// const driver = @import("driver.zig");
// const kernel = @import("../../kernel.zig");
// const geom = @import("../../geometry_handle.zig");
// const step_exporter = @import("../../../exporters/3d/step.zig");

// test "Driver: End-to-End API Calls" {
//     // Verifies creation, transformation, and destruction of basic 3D B-Rep primitives
//     const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
//     defer driver.driver.destructFn(cube_handle);

//     const cyl_handle = driver.driver.cylinderFn(5, 5, 15, true, 32) orelse return error.CylinderFailed;
//     defer driver.driver.destructFn(cyl_handle);

//     const sphere_handle = driver.driver.sphereFn(5) orelse return error.SphereFailed;
//     defer driver.driver.destructFn(sphere_handle);

//     // Ensure translation succeeds on a valid B-Rep handle
//     const trans_handle = driver.driver.translateFn(cube_handle, 10.0, 0.0, 0.0) orelse return error.TranslateFailed;
//     defer driver.driver.destructFn(trans_handle);

//     // Verify vertex count on working cube primitive
//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(cube_handle));
// }

// test "Driver: Custom Matrix Transformations" {
//     // Verifies 4x4 row-major affine transformation matrix application
//     const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
//     defer driver.driver.destructFn(cube_handle);

//     const translation_matrix = [12]f64{
//         1, 0, 0, 20,
//         0, 1, 0, 0,
//         0, 0, 1, 0,
//     };
//     const transformed = driver.driver.transformMatrixFn(cube_handle, translation_matrix) orelse return error.TransformFailed;
//     defer driver.driver.destructFn(transformed);

//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(transformed));
// }

// test "Driver: Mirror Solid" {
//     const cube_handle = driver.driver.cubeFn(10, 10, 10, false) orelse return error.CubeFailed;
//     defer driver.driver.destructFn(cube_handle);

//     const mirrored_handle = driver.driver.mirrorFn(cube_handle, 1, 0, 0) orelse return error.MirrorFailed;
//     defer driver.driver.destructFn(mirrored_handle);

//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(mirrored_handle));
// }

// // --- Mesh & Sweeps Import/Generation ---

// test "Driver: Polyhedron Import (Mesh to B-Rep)" {
//     const pts = [_][3]f64{
//         .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 },
//     };
//     const faces = [_][3]u32{
//         .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 },
//     };
//     const poly_handle = driver.driver.polyhedronFn(std.testing.allocator, &pts, &faces) orelse return error.PolyhedronFailed;
//     defer driver.driver.destructFn(poly_handle);

//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(poly_handle));
// }

// test "Driver: Revolve 2D Profile" {
//     const cs_handle = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
//     defer driver.driver.destructCrossSectionFn(cs_handle);

//     const rev_handle = driver.driver.revolveFn(cs_handle, 36, 360.0) orelse return error.RevolveFailed;
//     defer driver.driver.destructFn(rev_handle);

//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(rev_handle));
// }

// // --- 2D Cross Sections & Booleans ---

// test "Driver: 2D Operations (Boolean, Transform)" {
//     const sq1 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
//     defer driver.driver.destructCrossSectionFn(sq1);

//     const sq2 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
//     defer driver.driver.destructCrossSectionFn(sq2);

//     const mat = [6]f64{ 1, 0, 5, 0, 1, 5 };
//     const transformed_sq2 = driver.driver.crossSectionTransformFn(sq2, mat) orelse return error.TransformFailed;
//     defer driver.driver.destructCrossSectionFn(transformed_sq2);

//     const union_2d = driver.driver.crossSectionBooleanFn(sq1, transformed_sq2, .union_op) orelse return error.BooleanFailed;
//     defer driver.driver.destructCrossSectionFn(union_2d);

//     const final_solid = driver.driver.extrudeFn(union_2d, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
//     defer driver.driver.destructFn(final_solid);

//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(final_solid));
// }

// test "Driver: Polygons Even-Odd" {
//     const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
//     const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
//     const contours = [_][]const [2]f64{ &outer, &inner };

//     const cs_handle = driver.driver.polygonsEvenOddFn(std.testing.allocator, &contours) orelse return error.EvenOddFailed;
//     defer driver.driver.destructCrossSectionFn(cs_handle);

//     const solid_handle = driver.driver.extrudeFn(cs_handle, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
//     defer driver.driver.destructFn(solid_handle);

//     const solid_ptr: *driver.BrepSolid = @ptrCast(@alignCast(solid_handle.ptr));
//     try std.testing.expect(solid_ptr.t_arena.solids.items.len > 0);
// }

// // --- Projections & Slicing ---

// test "Driver: Slice Solid to 2D" {
//     const cyl = driver.driver.cylinderFn(5.0, 5.0, 20.0, true, 32) orelse return error.Cyl;
//     defer driver.driver.destructFn(cyl);

//     const cs = driver.driver.sliceFn(cyl, 0.0) orelse return error.Slice;
//     defer driver.driver.destructCrossSectionFn(cs);

//     const res = driver.driver.extrudeFn(cs, 10.0, 0, 0, 1.0, 1.0) orelse return error.Extrude;
//     defer driver.driver.destructFn(res);

//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(res));
// }

// // --- Convex Hulls & Queries ---

// test "Driver: Convex Hull (Single and Batch)" {
//     const cube1 = driver.driver.cubeFn(10, 10, 10, true) orelse return error.Cube;
//     defer driver.driver.destructFn(cube1);

//     const hull1 = driver.driver.hullFn(cube1) orelse return error.Hull;
//     defer driver.driver.destructFn(hull1);

//     try std.testing.expectEqual(@as(i32, 8), driver.driver.numVertsFn(hull1));
// }

// test "Driver: STEP Export of CSG Boolean Result" {
//     const alloc = std.testing.allocator;

//     const base = driver.driver.cubeFn(10.0, 10.0, 10.0, true) orelse return error.CubeFailed;
//     defer driver.driver.destructFn(base);

//     const hole = driver.driver.cylinderFn(2.5, 2.5, 20.0, true, 16) orelse return error.CylFailed;
//     defer driver.driver.destructFn(hole);

//     const result = driver.driver.booleanFn(base, hole, .difference_op) orelse return error.BoolFailed;
//     defer driver.driver.destructFn(result);

//     const handles = [_]geom.GeometryHandle{result};
//     const step_bytes = try step_exporter.buildStepBuffer(alloc, &handles);
//     defer alloc.free(step_bytes);

//     try std.testing.expect(std.mem.indexOf(u8, step_bytes, "ISO-10303-21;") != null);
// }
