// --- API Exports ---
pub const math = @import("math.zig");
pub const topology = @import("topology.zig");
pub const geometry = @import("geometry.zig");
pub const generators = @import("generators.zig");
pub const transforms = @import("transforms.zig");
pub const quickhull = @import("quickhull.zig");
pub const sweeps = @import("sweeps.zig");
pub const minkowski = @import("minkowski.zig");
pub const booleans = @import("booleans.zig");
pub const tessellate = @import("tessellate.zig");
pub const driver = @import("driver.zig");

test {
    _ = @import("booleans_test.zig");
    _ = @import("driver_test.zig");
    _ = @import("generators_test.zig");
    _ = @import("geometry_test.zig");
    _ = @import("minkowski_test.zig");
    _ = @import("quickhull_test.zig");
    _ = @import("sweeps_test.zig");
    _ = @import("tessellate_test.zig");
    _ = @import("transforms_test.zig");
}
