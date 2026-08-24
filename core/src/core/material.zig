const std = @import("std");

pub const MaterialRole = enum { standard, ghost, highlight };

pub const MaterialDef = struct {
    color_hex: []const u8 = "#FFFFFF",
    alpha: f64 = 1.0,
    roughness: f64 = 0.5,
    metallic: f64 = 0.0,
    transmission: f64 = 0.0,
    role: MaterialRole = .standard,
};
