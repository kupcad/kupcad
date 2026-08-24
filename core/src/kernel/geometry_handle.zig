const std = @import("std");

pub const EngineType = enum {
    manifold,
    brep_native,
};

/// A safe, tagged wrapper around C++ opaque pointers.
pub const GeometryHandle = struct {
    engine: EngineType,
    ptr: *anyopaque,
};

pub const CrossSectionHandle = struct {
    engine: EngineType,
    ptr: *anyopaque,
};

pub const SolidPair = struct {
    first: ?GeometryHandle,
    second: ?GeometryHandle,
};

pub const BoundingBox = struct {
    min: [3]f64,
    max: [3]f64,
};

pub const FaceHandle = struct {
    index: u32,
    normal: [3]f64,
    centroid: [3]f64,
};

pub const Mesh = struct {
    vert_props: []f32,
    tri_verts: []u32,
    num_prop: usize,
};

pub const RayHit = struct {
    distance: f64,
    position: [3]f64,
    normal: [3]f64,
};
