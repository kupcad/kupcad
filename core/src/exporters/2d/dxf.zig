//! DXF export: `build` writes a drawing (drawing.zig) as ASCII DXF (AutoCAD 2004, AC1018),
//! in millimetres (`$INSUNITS`), Y up as a sketch's is. Each outline is a closed
//! `LWPOLYLINE` on the layer named after its shape (`named`; the layer `0` for one without a
//! name), its arcs as bulges (the exact circle, not the chords the kernel drew), an
//! outline that is one circle a `CIRCLE`, and one with a glyph's curve a cubic `SPLINE`
//! (a polyline can't bend that way: the curves exact, a line a straight piece, and an arc
//! pieces of a quarter turn at most, within 0.03% of its circle), the layer coloured as
//! the shape's material (true colour, and the nearest of the basic index colours for
//! readers without it). The file holds the header, the layer and line type tables and the
//! entities: what CAD, CAM and laser tools read.

const std = @import("std");
const drawing_mod = @import("drawing.zig");
const bezier = @import("../../core/bezier.zig");

/// AutoCAD 2004, the first with true colours (group 420).
const VERSION = "AC1018";
/// `$INSUNITS` 4: millimetres.
const UNITS_MM = 4;
/// The layer of shapes without a name; every DXF has it.
const DEFAULT_LAYER = "0";
/// `62` colour of a layer without a material: 7, black or white as the background is.
const DEFAULT_COLOR_INDEX = 7;
/// The first handle given out; AutoCAD keeps the ones below for itself.
const FIRST_HANDLE = 0x20;
/// `70` of an LWPOLYLINE: closed, or open (a Path's).
const CLOSED = 1;
const OPEN = 0;
/// `70` of a SPLINE: planar (it lies in XY).
const PLANAR = 8;
/// A SPLINE of cubic pieces: its degree, and its knots beyond its control points.
const SPLINE_DEGREE = 3;
/// The most an arc's cubic piece sweeps: a quarter turn, where the usual cubic stays
/// within 0.03% of the circle.
const ARC_PIECE_MAX = std.math.pi / 2.0;

/// The basic index colours (`62`) a true colour is matched to: AutoCAD's 1 to 7.
const INDEX_COLORS = [_]struct { index: u8, rgb: [3]u8 }{
    .{ .index = 1, .rgb = .{ 255, 0, 0 } },
    .{ .index = 2, .rgb = .{ 255, 255, 0 } },
    .{ .index = 3, .rgb = .{ 0, 255, 0 } },
    .{ .index = 4, .rgb = .{ 0, 255, 255 } },
    .{ .index = 5, .rgb = .{ 0, 0, 255 } },
    .{ .index = 6, .rgb = .{ 255, 0, 255 } },
    .{ .index = 7, .rgb = .{ 255, 255, 255 } },
};

/// A layer of the file: a shape name, with the colour of the first shape of that name.
const Layer = struct {
    name: []const u8,
    rgb: ?[3]u8,
};

/// `drawing` as DXF text, owned by `allocator`. error.NoGeometry for a drawing with no point.
pub fn build(allocator: std.mem.Allocator, drawing: *const drawing_mod.Drawing) ![]u8 {
    const bounds = drawing.bounds orelse return error.NoGeometry;
    var layers = try layersOf(allocator, drawing);
    defer layers.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var file = File{ .w = &out.writer };

    // How many handles the file gives out: the tables', the layers' and the outlines'
    var outlines: usize = 0;
    for (drawing.shapes) |shape| outlines += shape.outlines.len;
    const handles = 2 + 1 + layers.items.len + outlines;

    try file.section("HEADER");
    try file.pair(9, "$ACADVER");
    try file.pair(1, VERSION);
    try file.pair(9, "$INSUNITS");
    try file.int(70, UNITS_MM);
    try file.pair(9, "$EXTMIN");
    try file.point(bounds.min);
    try file.pair(9, "$EXTMAX");
    try file.point(bounds.max);
    try file.pair(9, "$HANDSEED");
    try file.handleValue(5, FIRST_HANDLE + handles);
    try file.endSection();

    try file.section("TABLES");
    try file.table("LTYPE", 1);
    try file.pair(0, "LTYPE");
    try file.handle();
    try file.pair(100, "AcDbSymbolTableRecord");
    try file.pair(100, "AcDbLinetypeTableRecord");
    try file.pair(2, "CONTINUOUS");
    try file.int(70, 0);
    try file.pair(3, "Solid line");
    try file.int(72, 65);
    try file.int(73, 0);
    try file.pair(40, "0");
    try file.pair(0, "ENDTAB");
    try file.table("LAYER", layers.items.len);
    for (layers.items) |layer| {
        try file.pair(0, "LAYER");
        try file.handle();
        try file.pair(100, "AcDbSymbolTableRecord");
        try file.pair(100, "AcDbLayerTableRecord");
        try file.layerName(layer.name);
        try file.int(70, 0);
        try file.int(62, if (layer.rgb) |rgb| nearestIndexColor(rgb) else DEFAULT_COLOR_INDEX);
        if (layer.rgb) |rgb| try file.int(420, (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | rgb[2]);
        try file.pair(6, "CONTINUOUS");
    }
    try file.pair(0, "ENDTAB");
    try file.endSection();

    try file.section("ENTITIES");
    for (drawing.shapes) |shape| {
        for (shape.outlines) |outline| {
            if (outline.edges.len == 0) continue;
            if (wholeCircle(outline)) |arc| {
                try file.pair(0, "CIRCLE");
                try file.handle();
                try file.pair(100, "AcDbEntity");
                try file.layerOf(8, shape.name);
                try file.pair(100, "AcDbCircle");
                try file.number(10, arc.center[0]);
                try file.number(20, arc.center[1]);
                try file.number(40, arc.radius);
                continue;
            }
            if (hasCurve(outline)) {
                try writeSpline(allocator, &file, shape.name, outline);
                continue;
            }
            try file.pair(0, "LWPOLYLINE");
            try file.handle();
            try file.pair(100, "AcDbEntity");
            try file.layerOf(8, shape.name);
            try file.pair(100, "AcDbPolyline");
            // A vertex per edge, its start; a closed outline's last edge ends at the first
            // vertex, an open one's end is a vertex of its own
            try file.int(90, outline.edges.len + @intFromBool(!outline.closed));
            try file.int(70, if (outline.closed) CLOSED else OPEN);
            var from = outline.start;
            for (outline.edges) |edge| {
                try file.number(10, from[0]);
                try file.number(20, from[1]);
                if (edge.arc != null) try file.number(42, bulgeOf(edge));
                from = edge.to;
            }
            if (!outline.closed) {
                try file.number(10, from[0]);
                try file.number(20, from[1]);
            }
        }
    }
    try file.endSection();
    try file.pair(0, "EOF");
    return out.toOwnedSlice();
}

/// The circle a closed outline is, if it is one: two half turns of one circle (what the
/// arc matcher makes of a contour that is all one circle's chords).
fn wholeCircle(outline: drawing_mod.Outline) ?drawing_mod.Arc {
    if (!outline.closed or outline.edges.len != 2) return null;
    const first = outline.edges[0].arc orelse return null;
    const second = outline.edges[1].arc orelse return null;
    if (first.radius != second.radius or first.center[0] != second.center[0] or first.center[1] != second.center[1]) return null;
    if (outline.edges[0].angle != std.math.pi or outline.edges[1].angle != std.math.pi) return null;
    return first;
}

/// Whether the outline has a glyph's curve, which only a spline can hold.
fn hasCurve(outline: drawing_mod.Outline) bool {
    for (outline.edges) |edge| {
        if (edge.cubic != null) return true;
    }
    return false;
}

/// A piece of a spline: a cubic to `to`.
const SplinePiece = struct { c1: [2]f64, c2: [2]f64, to: [2]f64 };

/// `outline` as a `SPLINE` of cubic pieces (a piecewise Bézier: degree 3, each piece's
/// knot thrice, the ends' four times), its control points the start and each piece's.
fn writeSpline(allocator: std.mem.Allocator, file: *File, layer: ?[]const u8, outline: drawing_mod.Outline) !void {
    const pieces = try splinePieces(allocator, outline);
    defer allocator.free(pieces);
    const controls = 1 + SPLINE_DEGREE * pieces.len;
    try file.pair(0, "SPLINE");
    try file.handle();
    try file.pair(100, "AcDbEntity");
    try file.layerOf(8, layer);
    try file.pair(100, "AcDbSpline");
    try file.int(70, PLANAR);
    try file.int(71, SPLINE_DEGREE);
    try file.int(72, controls + SPLINE_DEGREE + 1);
    try file.int(73, controls);
    try file.int(74, 0);
    for (0..pieces.len + 1) |knot| {
        const repeats: usize = if (knot == 0 or knot == pieces.len) SPLINE_DEGREE + 1 else SPLINE_DEGREE;
        for (0..repeats) |_| try file.number(40, @floatFromInt(knot));
    }
    try file.point(outline.start);
    for (pieces) |piece| {
        try file.point(piece.c1);
        try file.point(piece.c2);
        try file.point(piece.to);
    }
}

/// `outline`'s edges as cubic pieces: a curve as it is, a line as the cubic with its
/// controls a third of the way along, an arc as pieces of ARC_PIECE_MAX at most, each the
/// usual cubic (its controls along the tangents, 4/3 tan(θ/4) of the radius out).
fn splinePieces(allocator: std.mem.Allocator, outline: drawing_mod.Outline) ![]SplinePiece {
    var pieces: std.ArrayList(SplinePiece) = .empty;
    errdefer pieces.deinit(allocator);
    var from = outline.start;
    for (outline.edges) |edge| {
        if (edge.cubic) |cubic| {
            try pieces.append(allocator, .{ .c1 = cubic.c1, .c2 = cubic.c2, .to = edge.to });
        } else if (edge.arc) |arc| {
            const count: usize = @intFromFloat(@max(1, @ceil(edge.angle / ARC_PIECE_MAX)));
            const theta = edge.angle / @as(f64, @floatFromInt(count));
            const kappa = 4.0 / 3.0 * @tan(theta / 4) * arc.radius;
            const way: f64 = if (edge.ccw) 1 else -1;
            var a0 = std.math.atan2(from[1] - arc.center[1], from[0] - arc.center[0]);
            for (0..count) |k| {
                const a1 = a0 + way * theta;
                const p0 = [2]f64{ arc.center[0] + arc.radius * @cos(a0), arc.center[1] + arc.radius * @sin(a0) };
                // The last piece ends exactly where the edge does
                const p3 = if (k + 1 == count) edge.to else [2]f64{ arc.center[0] + arc.radius * @cos(a1), arc.center[1] + arc.radius * @sin(a1) };
                try pieces.append(allocator, .{
                    .c1 = .{ p0[0] - way * kappa * @sin(a0), p0[1] + way * kappa * @cos(a0) },
                    .c2 = .{ p3[0] + way * kappa * @sin(a1), p3[1] - way * kappa * @cos(a1) },
                    .to = p3,
                });
                a0 = a1;
            }
        } else {
            try pieces.append(allocator, .{
                .c1 = .{ from[0] + (edge.to[0] - from[0]) / 3, from[1] + (edge.to[1] - from[1]) / 3 },
                .c2 = .{ from[0] + 2 * (edge.to[0] - from[0]) / 3, from[1] + 2 * (edge.to[1] - from[1]) / 3 },
                .to = edge.to,
            });
        }
        from = edge.to;
    }
    return pieces.toOwnedSlice(allocator);
}

/// A vertex's bulge (`42`): the tangent of a quarter of the angle the arc to the next
/// vertex sweeps, positive counter-clockwise, as DXF stores an arc in a polyline.
fn bulgeOf(edge: drawing_mod.Edge) f64 {
    // A half turn's bulge is exactly 1, the usual circle (tan rounds it to 0.999...)
    const bulge = if (edge.angle == std.math.pi) 1.0 else @tan(edge.angle / 4);
    return if (edge.ccw) bulge else -bulge;
}

/// The layers of `drawing`: `0` first, then each shape name once, in the shapes' order,
/// with the first shape's colour.
fn layersOf(allocator: std.mem.Allocator, drawing: *const drawing_mod.Drawing) !std.ArrayList(Layer) {
    var layers: std.ArrayList(Layer) = .empty;
    errdefer layers.deinit(allocator);
    try layers.append(allocator, .{ .name = DEFAULT_LAYER, .rgb = null });
    for (drawing.shapes) |shape| {
        const name = shape.name orelse continue;
        for (layers.items) |layer| {
            if (std.mem.eql(u8, layer.name, name)) break;
        } else try layers.append(allocator, .{ .name = name, .rgb = shape.rgb });
    }
    return layers;
}

/// The index colour (`62`) nearest `rgb`, as readers without true colour show it.
fn nearestIndexColor(rgb: [3]u8) u8 {
    var best = INDEX_COLORS[0];
    var best_distance: u32 = std.math.maxInt(u32);
    for (INDEX_COLORS) |candidate| {
        var distance: u32 = 0;
        for (rgb, candidate.rgb) |c, k| {
            const d: i32 = @as(i32, c) - @as(i32, k);
            distance += @intCast(d * d);
        }
        if (distance < best_distance) {
            best_distance = distance;
            best = candidate;
        }
    }
    return best.index;
}

/// The file as it is written: DXF is pairs of a group code line and a value line, and
/// every table entry and entity carries a handle of its own.
const File = struct {
    w: *std.Io.Writer,
    next_handle: usize = FIRST_HANDLE,

    fn pair(self: *File, code: u16, text: []const u8) !void {
        try self.w.print("{d}\n{s}\n", .{ code, text });
    }

    fn int(self: *File, code: u16, n: usize) !void {
        try self.w.print("{d}\n{d}\n", .{ code, n });
    }

    fn number(self: *File, code: u16, n: f64) !void {
        try self.w.print("{d}\n{d}\n", .{ code, n + 0.0 });
    }

    /// A header point: x, y and a zero z.
    fn point(self: *File, p: [2]f64) !void {
        try self.number(10, p[0]);
        try self.number(20, p[1]);
        try self.number(30, 0);
    }

    fn handleValue(self: *File, code: u16, h: usize) !void {
        try self.w.print("{d}\n{X}\n", .{ code, h });
    }

    /// The next handle, as group 5.
    fn handle(self: *File) !void {
        try self.handleValue(5, self.next_handle);
        self.next_handle += 1;
    }

    fn section(self: *File, name: []const u8) !void {
        try self.pair(0, "SECTION");
        try self.pair(2, name);
    }

    fn endSection(self: *File) !void {
        try self.pair(0, "ENDSEC");
    }

    fn table(self: *File, name: []const u8, entries: usize) !void {
        try self.pair(0, "TABLE");
        try self.pair(2, name);
        try self.handle();
        try self.pair(100, "AcDbSymbolTable");
        try self.int(70, entries);
    }

    /// Group `code` naming the layer of a shape called `name` (`0` without one).
    fn layerOf(self: *File, code: u16, name: ?[]const u8) !void {
        try self.w.print("{d}\n", .{code});
        try writeLayerName(self.w, name orelse DEFAULT_LAYER);
        try self.w.writeByte('\n');
    }

    fn layerName(self: *File, name: []const u8) !void {
        try self.layerOf(2, name);
    }
};

/// `name` as a layer name: the characters DXF forbids in one (`<>/\":;?*|=,` and the
/// backtick), and control characters, become `_`.
fn writeLayerName(w: *std.Io.Writer, name: []const u8) !void {
    for (name) |c| {
        const forbidden = std.mem.indexOfScalar(u8, "<>/\\\":;?*|=,`", c) != null or c < 0x20 or c == 0x7f;
        try w.writeByte(if (forbidden) '_' else c);
    }
}
