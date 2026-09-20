const std = @import("std");

// --- Typed Geometry Indices (u24 allows perfect 32-bit packing with the u8 type tags) ---
pub const PointIndex = enum(u32) { _ };
pub const CurveIndex = enum(u24) { _ };
pub const PCurveIndex = enum(u24) { _ };
pub const SurfaceIndex = enum(u24) { _ };

// --- Enums defining the algebraic backend ---
pub const CurveType = enum(u8) {
    line,
    circle_arc,
    nurbs,
};

pub const PCurveType = enum(u8) {
    line_2d,
    nurbs_2d,
};

pub const SurfaceType = enum(u8) {
    plane,
    sphere,
    cylinder,
    cone,
    torus,
    nurbs,
};

// --- Tagged Algebraic References ---
pub const CurveId = packed struct {
    index: CurveIndex,
    curve_type: CurveType,
};

pub const PCurveId = packed struct {
    index: PCurveIndex,
    curve_type: PCurveType,
};

pub const SurfaceId = packed struct {
    index: SurfaceIndex,
    surface_type: SurfaceType,
};
