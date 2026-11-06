//! What "close enough" means for a body (`Tolerance`, docs/architecture.md §6; to come) and
//! how finely a curve is cut into straight edges (`Resolution`), which KupCAD imports so
//! that both of its engines cut a circle into the same polygon (§7.7, §9.3).

const std = @import("std");

/// Fewest straight edges an automatically resolved circle gets.
const MIN_AUTO_SEGMENTS: u32 = 5;

/// How finely a curve is cut into straight edges wherever it has to be (meshing, export):
/// `segments` edges per full circle when set, otherwise as many as keep each edge within
/// `min_angle` degrees of arc and `min_length` long, whichever gives fewer (OpenSCAD's
/// $fn, $fa and $fs). KupCAD's mesh engine follows the same rule, so both kernels cut a
/// curve alike.
pub const Resolution = struct {
    segments: u32 = 0, // 0 = from min_angle and min_length
    min_angle: f64 = 12.0,
    min_length: f64 = 2.0,

    /// The number of edges a full circle of `radius` gets.
    pub fn segmentsFor(self: Resolution, radius: f64) u32 {
        if (self.segments > 0) return self.segments;
        if (!(radius > 0.0)) return MIN_AUTO_SEGMENTS;
        const by_angle = 360.0 / self.min_angle;
        const by_length = 2.0 * std.math.pi * radius / self.min_length;
        const count = @ceil(@min(by_angle, by_length));
        // Past u32 the count is meaningless anyway; callers clamp to their own limits.
        if (!(count < @as(f64, std.math.maxInt(u32)))) return std.math.maxInt(u32);
        return @max(MIN_AUTO_SEGMENTS, @as(u32, @intFromFloat(count)));
    }
};
