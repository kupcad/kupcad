const std = @import("std");
const driver = @import("driver.zig");
const kernel = @import("../../kernel.zig");

test "Driver: End-to-End API Calls" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const cyl_handle = driver.driver.cylinderFn(5, 5, 15, true, 32) orelse return error.CylinderFailed;
    defer driver.driver.destructFn(cyl_handle);

    const sphere_handle = driver.driver.sphereFn(5) orelse return error.SphereFailed;
    defer driver.driver.destructFn(sphere_handle);

    _ = driver.driver.translateFn(cube_handle, 10.0, 0.0, 0.0) orelse return error.TranslateFailed;

    const mesh_data = driver.driver.getMeshFn(std.testing.allocator, cube_handle) orelse return error.MeshingFailed;
    defer std.testing.allocator.free(mesh_data.vert_props);
    defer std.testing.allocator.free(mesh_data.tri_verts);

    try std.testing.expect(mesh_data.vert_props.len > 0);
}

test "Driver: Measurements (Volume, Surface Area, Bounding Box, Contains)" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[0], 1e-6);
    try std.testing.expectApproxEqAbs(5.0, bbox.max[0], 1e-6);

    const vol = driver.driver.volumeFn(cube_handle);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-6);

    const area = driver.driver.surfaceAreaFn(cube_handle);
    try std.testing.expectApproxEqAbs(600.0, area, 1e-6);

    const is_inside = driver.driver.containsPointFn(cube_handle, .{ 0, 0, 0 });
    const is_outside = driver.driver.containsPointFn(cube_handle, .{ 20, 0, 0 });
    try std.testing.expect(is_inside);
    try std.testing.expect(!is_outside);
}

test "Driver: Custom Matrix Transformations" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const translation_matrix = [12]f64{
        1, 0, 0, 20,
        0, 1, 0, 0,
        0, 0, 1, 0,
    };
    _ = driver.driver.transformMatrixFn(cube_handle, translation_matrix) orelse return error.TransformFailed;

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(25.0, bbox.max[0], 1e-6);
}

test "Driver: Trim by Plane (Half-Space Slicing)" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    _ = driver.driver.trimByPlaneFn(cube_handle, 0, 0, 1, 0.0) orelse return error.TrimFailed;

    const bbox = driver.driver.boundingBoxFn(cube_handle) orelse return error.BBoxFailed;
    try std.testing.expectApproxEqAbs(0.0, bbox.max[2], 1e-6);
    try std.testing.expectApproxEqAbs(-5.0, bbox.min[2], 1e-6);

    const vol = driver.driver.volumeFn(cube_handle);
    try std.testing.expectApproxEqAbs(500.0, vol, 1e-5);
}

test "Driver: Polyhedron Import (Mesh to B-Rep)" {
    const pts = [_][3]f64{
        .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 }, .{ 5, 5, 10 },
    };
    const faces = [_][3]u32{
        .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 4 },
    };
    const poly_handle = driver.driver.polyhedronFn(std.testing.allocator, &pts, &faces) orelse return error.PolyhedronFailed;
    defer driver.driver.destructFn(poly_handle);

    try std.testing.expectApproxEqAbs(333.333333, driver.driver.volumeFn(poly_handle), 1e-4);
}

test "Driver: Revolve 2D Profile" {
    const cs_handle = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    defer driver.driver.destructCrossSectionFn(cs_handle);

    // Revolve creates a new disjoint solid, so we destruct both
    const rev_handle = driver.driver.revolveFn(cs_handle, 36, 360.0) orelse return error.RevolveFailed;
    defer driver.driver.destructFn(rev_handle);

    const expected_area = 1800.0 * @sin(10.0 * std.math.pi / 180.0);
    const expected_vol = expected_area * 10.0;
    try std.testing.expectApproxEqAbs(expected_vol, driver.driver.volumeFn(rev_handle), 1e-4);
}

test "Driver: 2D Operations (Boolean, Transform)" {
    const sq1 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    const sq2 = driver.driver.squareFn(10.0, 10.0, false) orelse return error.SquareFailed;
    // B merges into A, so B still exists independently and must be destructed
    defer driver.driver.destructCrossSectionFn(sq2);

    const mat = [6]f64{ 1, 0, 5, 0, 1, 5 };
    _ = driver.driver.crossSectionTransformFn(sq2, mat) orelse return error.TransformFailed;

    const union_2d = driver.driver.crossSectionBooleanFn(sq1, sq2, .union_op) orelse return error.BooleanFailed;

    // Extrude reuses `union_2d` (which is `sq1`) in place. Defer once on the final output!
    const final_solid = driver.driver.extrudeFn(union_2d, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(final_solid);

    try std.testing.expectApproxEqAbs(1750.0, driver.driver.volumeFn(final_solid), 1e-4);
}

test "Driver: Mirror Solid" {
    const cube_handle = driver.driver.cubeFn(10, 10, 10, false) orelse return error.CubeFailed;
    defer driver.driver.destructFn(cube_handle);

    const mirrored_handle = driver.driver.mirrorFn(cube_handle, 1, 0, 0) orelse return error.MirrorFailed;
    const bbox = driver.driver.boundingBoxFn(mirrored_handle) orelse return error.BBoxFailed;

    try std.testing.expectApproxEqAbs(-10.0, bbox.min[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.0, bbox.max[0], 1e-6);

    const vol = driver.driver.volumeFn(mirrored_handle);
    try std.testing.expectApproxEqAbs(1000.0, vol, 1e-5);
}

test "Driver: Polygons Even-Odd" {
    const outer = [_][2]f64{ .{ -10, -10 }, .{ 10, -10 }, .{ 10, 10 }, .{ -10, 10 } };
    const inner = [_][2]f64{ .{ -5, -5 }, .{ -5, 5 }, .{ 5, 5 }, .{ 5, -5 } };
    const contours = [_][]const [2]f64{ &outer, &inner };

    const cs_handle = driver.driver.polygonsEvenOddFn(std.testing.allocator, &contours) orelse return error.EvenOddFailed;
    // Extrude modifies cs_handle in-place. Defer the destruction on the returned handle.
    const solid_handle = driver.driver.extrudeFn(cs_handle, 10, 0, 0, 1, 1) orelse return error.ExtrudeFailed;
    defer driver.driver.destructFn(solid_handle);

    const solid_ptr: *driver.BrepSolid = @ptrCast(@alignCast(solid_handle.ptr));
    const s = solid_ptr.t_arena.solids.items[solid_ptr.solid_id];
    const shell = solid_ptr.t_arena.shells.items[solid_ptr.t_arena.solid_shells.items[s.shells_start]];
    try std.testing.expectEqual(@as(usize, 10), shell.faces_len);
}
