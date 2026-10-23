//! A model as a drawing, what the 2D exporters (SVG, DXF) write: each shape's outlines
//! (kernel.crossSectionContours) with the name and colour it carries, and the drawing's
//! bounds. `api.drawingOf` builds it from the model's Sketches and from its Solids projected
//! onto the XY plane, so a 3D model exports as a 2D format too.

const std = @import("std");
const geom = @import("../../kernel/geometry_handle.zig");

/// One shape of the drawing: a Sketch's outlines, or a projected Solid's.
pub const Shape = struct {
    /// The sketch's name (`named`), or the part's for a projected Solid; null when none.
    /// Owned by the drawing's allocator.
    name: ?[]const u8,
    /// The sketch's or part's material colour, sRGB; null for the exporter's default.
    rgb: ?[3]u8,
    /// Its opacity, 0 to 1.
    alpha: f64,
    contours: geom.Contours,
};

pub const Drawing = struct {
    /// In the model's order.
    shapes: []Shape,
    /// How many of the shapes are Solids projected onto XY (the last ones).
    projected: usize,
    /// The box around every contour; null for a drawing with no point.
    bounds: ?geom.Rect2D,

    pub fn deinit(self: *Drawing, allocator: std.mem.Allocator) void {
        for (self.shapes) |shape| {
            shape.contours.deinit(allocator);
            if (shape.name) |name| allocator.free(name);
        }
        allocator.free(self.shapes);
    }

    /// The box around every shape's points, or null when there is none.
    pub fn boundsOf(shapes: []const Shape) ?geom.Rect2D {
        var box: ?geom.Rect2D = null;
        for (shapes) |shape| {
            for (shape.contours.points) |p| {
                if (box) |*b| {
                    b.min = .{ @min(b.min[0], p[0]), @min(b.min[1], p[1]) };
                    b.max = .{ @max(b.max[0], p[0]), @max(b.max[1], p[1]) };
                } else box = .{ .min = p, .max = p };
            }
        }
        return box;
    }
};
