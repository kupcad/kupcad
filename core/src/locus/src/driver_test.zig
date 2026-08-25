const std = @import("std");
const driver = @import("../src/driver.zig");

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

    // Since there were already 3 solids (0, 1, 2) in the arena, the clone is ID 3.
    try std.testing.expectEqual(@as(usize, 3), translated_handle);

    // 5. Test the Meshing Pipeline
    const mesh_data = driver.driver.getMeshFn(cube_handle) orelse return error.MeshingFailed;

    // Our dummy `tessellateFace` currently pushes 1 vertex per face, so a cube (6 faces) = 6 vertices.
    // 6 vertices * 3 floats (x,y,z) = 18 floats total.
    try std.testing.expectEqual(@as(usize, 18), mesh_data.vertex_len);
}
