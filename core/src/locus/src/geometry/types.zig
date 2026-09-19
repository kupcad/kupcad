const std = @import("std");

// --- Strongly-Typed Indices ---
pub const PointIndex = enum(u32) { _ };
pub const CurveIndex = enum(u32) { _ };
pub const PCurveIndex = enum(u32) { _ };
pub const SurfaceIndex = enum(u32) { _ };

// --- Primitive Kind Enums ---
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

// --- Packed Tagged Handles ---
pub const CurveHandle = packed struct {
    index: u24,
    curve_type: CurveType,
};

pub const PCurveHandle = packed struct {
    index: u24,
    p_curve_type: PCurveType,
};

pub const SurfaceHandle = packed struct {
    index: u24,
    surface_type: SurfaceType,
};
