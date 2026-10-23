//! A model as a drawing, what the 2D exporters (SVG, DXF) write: each shape's outlines
//! (the kernel's contours, their chords turned back into the arcs they were drawn from,
//! arcs.zig; a Path's segments as they are, open) with the name and colour it carries, and
//! the drawing's bounds. `api.drawingOf` builds it from the model's Sketches and Paths and
//! from its Solids projected onto the XY plane, so a 3D model exports as a 2D format too.

const std = @import("std");
const geom = @import("../../kernel/geometry_handle.zig");
const path_mod = @import("../../core/path.zig");

/// An outline's edge is a path segment, and an arc its circle (core/path.zig).
pub const Arc = path_mod.Arc;
pub const Edge = path_mod.Segment;
pub const sweep = path_mod.sweep;

/// An outline: from `start` along its edges, back to it when `closed` (the last edge ends
/// there) or left open, as a Path is.
pub const Outline = struct {
    start: [2]f64,
    edges: []Edge,
    closed: bool = true,

    /// The box around the outline, its arcs' bulges included.
    pub fn bounds(self: Outline) geom.Rect2D {
        const b = path_mod.bounds(self.start, self.edges);
        return .{ .min = b.min, .max = b.max };
    }

    pub fn include(box: *?geom.Rect2D, p: [2]f64) void {
        if (box.*) |*b| {
            b.min = .{ @min(b.min[0], p[0]), @min(b.min[1], p[1]) };
            b.max = .{ @max(b.max[0], p[0]), @max(b.max[1], p[1]) };
        } else box.* = .{ .min = p, .max = p };
    }
};

/// One shape of the drawing: a Sketch's outlines, or a projected Solid's.
pub const Shape = struct {
    /// The sketch's name (`named`), or the part's for a projected Solid; null when none.
    /// Owned by the drawing's allocator.
    name: ?[]const u8,
    /// The sketch's or part's material colour, sRGB; null for the exporter's default.
    rgb: ?[3]u8,
    /// Its opacity, 0 to 1.
    alpha: f64,
    outlines: []Outline,

    pub fn deinit(self: Shape, allocator: std.mem.Allocator) void {
        for (self.outlines) |outline| allocator.free(outline.edges);
        allocator.free(self.outlines);
        if (self.name) |name| allocator.free(name);
    }
};

pub const Drawing = struct {
    /// In the model's order.
    shapes: []Shape,
    /// How many of the shapes are Solids projected onto XY (the last ones).
    projected: usize,
    /// The box around every outline; null for a drawing with no point.
    bounds: ?geom.Rect2D,

    pub fn deinit(self: *Drawing, allocator: std.mem.Allocator) void {
        for (self.shapes) |shape| shape.deinit(allocator);
        allocator.free(self.shapes);
    }

    /// The box around every shape's outlines, or null when there is none.
    pub fn boundsOf(shapes: []const Shape) ?geom.Rect2D {
        var box: ?geom.Rect2D = null;
        for (shapes) |shape| {
            for (shape.outlines) |outline| {
                const b = outline.bounds();
                Outline.include(&box, b.min);
                Outline.include(&box, b.max);
            }
        }
        return box;
    }
};
