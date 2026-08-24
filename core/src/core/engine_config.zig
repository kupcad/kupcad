const std = @import("std");
const geom = @import("../kernel/geometry_handle.zig");

pub const EngineConfig = struct {
    engine: geom.EngineType = .manifold,
    segments: i32 = 0,
    fa: f64 = 12.0,
    fs: f64 = 2.0,
    tolerance: f64 = 1e-5,
};
