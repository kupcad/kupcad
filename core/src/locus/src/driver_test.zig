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

    // Our tessellator currently pushes all vertices from the global arena.
    // Cube (8) + Cylinder (4) + Sphere (2) = exactly 14 vertices.
    // 14 vertices $\times$ 3 floats = 42 floats.
    try std.testing.expectEqual(@as(usize, 42), mesh_data.vertex_len);
}
