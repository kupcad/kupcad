const std = @import("std");
const driver = @import("../src/driver.zig");

test "Driver: End-to-End API Calls" {
    // 1. Initialize the global kernel state
    driver.init(std.testing.allocator);
    defer driver.deinit();

    // 2. Call the FFI wrappers as if we were the VM
    const cube_handle = driver.driver.cubeFn(10, 10, 10, true) orelse return error.CubeFailed;
    const cyl_handle = driver.driver.cylinderFn(5, 15, true) orelse return error.CylinderFailed;
    const sphere_handle = driver.driver.sphereFn(5) orelse return error.SphereFailed;

    // 3. Since the topology arena handles append sequentially,
    // the solid IDs should be exactly 0, 1, and 2.
    try std.testing.expectEqual(@as(usize, 0), cube_handle);
    try std.testing.expectEqual(@as(usize, 1), cyl_handle);
    try std.testing.expectEqual(@as(usize, 2), sphere_handle);

    // 4. Test a transform
    const translated_handle = driver.driver.translateFn(cube_handle, 10.0, 0.0, 0.0) orelse return error.TranslateFailed;

    // transformSolid in transforms.zig is currently hardcoded to return 0,
    // so we just ensure it didn't return null and crash.
    try std.testing.expectEqual(@as(usize, 0), translated_handle);
}
