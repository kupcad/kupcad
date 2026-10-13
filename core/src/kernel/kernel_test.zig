const std = @import("std");
const testing = std.testing;
const kernel = @import("kernel.zig");
const geom = @import("geometry_handle.zig");

test "Kernel Dispatcher: routes primitives to the requested engine" {
    inline for (.{ geom.EngineType.manifold, geom.EngineType.brep_native }) |engine| {
        const handle = kernel.cube(engine, 10.0, 10.0, 10.0, true) orelse return error.DispatchFailed;
        defer kernel.destruct(handle);

        // The returned handle is tagged with, and usable by, the requested engine.
        try testing.expectEqual(engine, handle.engine);
        try testing.expectEqual(@as(i32, 8), kernel.numVerts(handle));
    }
}
