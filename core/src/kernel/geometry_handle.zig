const std = @import("std");

pub const EngineType = enum {
    manifold,
    occt,
    brep_native,
};

/// A safe, tagged wrapper around C++ opaque pointers.
pub const GeometryHandle = struct {
    engine: EngineType,
    ptr: *anyopaque,
};
