//! A model as a drawing, what the 2D exporters (SVG, DXF) write: each shape's outlines
//! (the kernel's contours, their chords turned back into the arcs they were drawn from,
//! arcs.zig) with the name and colour it carries, and the drawing's bounds. `api.drawingOf`
//! builds it from the model's Sketches and from its Solids projected onto the XY plane, so a
//! 3D model exports as a 2D format too.

const std = @import("std");
const geom = @import("../../kernel/geometry_handle.zig");

/// The circle an arc lies on.
pub const Arc = struct {
    center: [2]f64,
    radius: f64,
};

/// One edge of an outline: a straight line to `to`, or the arc of `arc`'s circle to it,
/// counter-clockwise about the centre when `ccw`, sweeping `angle` radians (more than π:
/// the long way round). The angle is the arc's own, as the matcher knows it, not derived
/// from the chord, which the kernel's vertices place a little off the ideal circle.
pub const Edge = struct {
    to: [2]f64,
    arc: ?Arc = null,
    ccw: bool = true,
    angle: f64 = 0,

    pub fn large(self: Edge) bool {
        return self.angle > std.math.pi;
    }

    /// Whether the arc from `from` passes `p`, a point of its circle: `p`'s angle lies
    /// within the arc's, going its way.
    pub fn passes(self: Edge, from: [2]f64, p: [2]f64) bool {
        const arc = self.arc orelse return false;
        return sweep(arc.center, from, p, self.ccw) <= self.angle;
    }
};

/// The angle swept about `center` from `from` to `to` going the `ccw` way, in [0, 2π).
pub fn sweep(center: [2]f64, from: [2]f64, to: [2]f64, ccw: bool) f64 {
    const a0 = std.math.atan2(from[1] - center[1], from[0] - center[0]);
    const a1 = std.math.atan2(to[1] - center[1], to[0] - center[0]);
    const d = if (ccw) a1 - a0 else a0 - a1;
    return if (d < 0) d + 2 * std.math.pi else d;
}

/// A closed outline: from `start` along its edges back to it (the last edge ends there).
pub const Outline = struct {
    start: [2]f64,
    edges: []Edge,

    /// The box around the outline, its arcs' bulges included.
    pub fn bounds(self: Outline) ?geom.Rect2D {
        var box: ?geom.Rect2D = null;
        var from = self.start;
        include(&box, from);
        for (self.edges) |edge| {
            include(&box, edge.to);
            if (edge.arc) |arc| {
                // Wherever the arc crosses an axis through the centre, it reaches the
                // circle's extreme on that side
                const extremes = [4][2]f64{
                    .{ arc.center[0] + arc.radius, arc.center[1] },
                    .{ arc.center[0], arc.center[1] + arc.radius },
                    .{ arc.center[0] - arc.radius, arc.center[1] },
                    .{ arc.center[0], arc.center[1] - arc.radius },
                };
                for (extremes) |p| {
                    if (edge.passes(from, p)) include(&box, p);
                }
            }
            from = edge.to;
        }
        return box;
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
                const b = outline.bounds() orelse continue;
                Outline.include(&box, b.min);
                Outline.include(&box, b.max);
            }
        }
        return box;
    }
};
