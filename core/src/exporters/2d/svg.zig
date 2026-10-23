//! SVG export: `build` writes a drawing (drawing.zig) as SVG, in millimetres (`width` and
//! `height` in mm, the `viewBox` the drawing's bounds), with Y turned over (SVG's Y runs
//! down, a sketch's up) so the file shows the sketch as the script has it. Each shape is one
//! `<path>` of all its outlines, lines as `L` and arcs as `A` (the exact circle, not the
//! chords the kernel drew), filled by the even-odd rule so its holes are holes, in its
//! material colour (or a neutral grey), with a thin black outline; a Path, open, is not
//! filled and is stroked in its colour; a named shape carries its name as the path's `id`.

const std = @import("std");
const drawing_mod = @import("drawing.zig");

const DEFAULT_FILL = "#CCCCCC";
const STROKE = "#000000";
/// mm
const STROKE_WIDTH = 0.1;

/// `drawing` as SVG text, owned by `allocator`. error.NoGeometry for a drawing with no point.
pub fn build(allocator: std.mem.Allocator, drawing: *const drawing_mod.Drawing) ![]u8 {
    const bounds = drawing.bounds orelse return error.NoGeometry;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    const width = bounds.max[0] - bounds.min[0];
    const height = bounds.max[1] - bounds.min[1];
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}mm\" height=\"{d}mm\" viewBox=\"{d} {d} {d} {d}\">\n", .{ width, height, bounds.min[0], flipped(bounds.max[1]), width, height });
    try w.print("<!-- KupCAD Export: millimetres -->\n", .{});
    for (drawing.shapes) |shape| {
        if (shape.outlines.len == 0) continue;
        try w.writeAll("  <path");
        if (shape.name) |name| {
            try w.writeAll(" id=\"");
            try writeId(w, name);
            try w.writeByte('"');
        }
        // A Path encloses nothing: its colour is its stroke's
        var open = true;
        for (shape.outlines) |outline| open = open and !outline.closed;
        const fill = if (open) "none" else null;
        var color_buf: [7]u8 = undefined;
        const color: []const u8 = if (shape.rgb) |rgb| try std.fmt.bufPrint(&color_buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ rgb[0], rgb[1], rgb[2] }) else DEFAULT_FILL;
        try w.print(" fill=\"{s}\"", .{fill orelse color});
        if (shape.alpha < 1) try w.print(" fill-opacity=\"{d}\"", .{shape.alpha});
        try w.print(" fill-rule=\"evenodd\" stroke=\"{s}\" stroke-width=\"{d}\" d=\"", .{ if (open and shape.rgb != null) color else STROKE, STROKE_WIDTH });
        for (shape.outlines, 0..) |outline, i| {
            if (i > 0) try w.writeByte(' ');
            try w.print("M {d} {d}", .{ outline.start[0], flipped(outline.start[1]) });
            for (outline.edges, 0..) |edge, e| {
                // `Z` draws the last line back to the start itself
                if (outline.closed and e == outline.edges.len - 1 and edge.arc == null) break;
                if (edge.arc) |arc| {
                    // Turned over, a counter-clockwise arc runs the other way: SVG's sweep
                    // flag is 1 for the positive-angle direction of its downward Y
                    try w.print(" A {d} {d} 0 {d} {d} {d} {d}", .{ arc.radius, arc.radius, @intFromBool(edge.large()), @intFromBool(!edge.ccw), edge.to[0], flipped(edge.to[1]) });
                } else try w.print(" L {d} {d}", .{ edge.to[0], flipped(edge.to[1]) });
            }
            if (outline.closed) try w.writeAll(" Z");
        }
        try w.writeAll("\"/>\n");
    }
    try w.writeAll("</svg>\n");
    return out.toOwnedSlice();
}

/// A sketch's y as SVG's, which runs down the page; a zero stays `0`, not `-0`.
fn flipped(y: f64) f64 {
    return -y + 0.0;
}

/// `name` as an XML id: letters, digits, `_` and `-` as they are, anything else `_`, and a
/// leading `_` when it doesn't start with a letter or `_`.
fn writeId(w: *std.Io.Writer, name: []const u8) !void {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) try w.writeByte('_');
    for (name) |c| try w.writeByte(if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') c else '_');
}
