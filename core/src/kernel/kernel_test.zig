const std = @import("std");
const testing = std.testing;
const kernel = @import("kernel.zig");
const geom = @import("geometry_handle.zig");

test "Kernel Dispatcher: Routes correctly to Manifold engine" {
    // Request a cube from the Manifold engine
    const handle = kernel.cube(.manifold, 10.0, 10.0, 10.0, true) orelse return error.DispatchFailed;
    defer kernel.destruct(handle);

    // Verify the comptime dispatcher correctly returned a handle tagged with the requested engine
    try testing.expectEqual(geom.EngineType.manifold, handle.engine);

    // Verify the FFI pointer is populated
    try testing.expect(@intFromPtr(handle.ptr) != 0);
}

test "Kernel Dispatcher: Routes correctly to Native B-Rep engine" {
    // Request a cube from the B-Rep engine
    const handle = kernel.cube(.brep_native, 10.0, 10.0, 10.0, true) orelse return error.DispatchFailed;
    defer kernel.destruct(handle);

    // Verify the comptime dispatcher correctly returned a handle tagged with the requested engine
    try testing.expectEqual(geom.EngineType.brep_native, handle.engine);

    // Verify the FFI pointer is populated
    try testing.expect(@intFromPtr(handle.ptr) != 0);
}
