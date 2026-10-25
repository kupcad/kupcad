//! A grid of square cells over the plane, to find the points near a point without comparing
//! every one: a point's cell, and the cells around it. The 2D files' point indexes are kept
//! on it: curves.zig's (the points a drawing's curves pass) and dxf_read.zig's (the ends of
//! the pieces it joins).

const std = @import("std");

/// The cell of side `size` that holds `p`. Saturating: a point further out than a cell's
/// index holds (past 2^63 cells) shares an edge cell, its points still compared by distance.
pub fn cellOf(p: [2]f64, size: f64) [2]i64 {
    return .{ std.math.lossyCast(i64, @floor(p[0] / size)), std.math.lossyCast(i64, @floor(p[1] / size)) };
}

/// The cell `dx`, `dy` (each -1, 0 or 1) from `cell`: an edge cell again past the edge.
pub fn around(cell: [2]i64, dx: i64, dy: i64) [2]i64 {
    return .{ cell[0] +| dx, cell[1] +| dy };
}
