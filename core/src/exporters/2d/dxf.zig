//! DXF export: `build` writes a drawing (drawing.zig) as ASCII DXF (AutoCAD 2004, AC1018),
//! in millimetres (`$INSUNITS`), Y up as a sketch's is. Each outline is a closed
//! `LWPOLYLINE` on the layer named after its shape (`named`; the layer `0` for one without a
//! name), its arcs as bulges (the exact circle, not the chords the kernel drew; a circle is
//! two half turns), the layer coloured as the shape's material (true colour, and the
//! nearest of the basic index colours for readers without it). The file holds the header, the layer and
//! line type tables and the entities: what CAD, CAM and laser tools read.

const std = @import("std");
const drawing_mod = @import("drawing.zig");

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
/// `70` of an LWPOLYLINE: closed.
const CLOSED = 1;

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
            try file.pair(0, "LWPOLYLINE");
            try file.handle();
            try file.pair(100, "AcDbEntity");
            try file.layerOf(8, shape.name);
            try file.pair(100, "AcDbPolyline");
            // A vertex per edge: its start; the last edge ends at the first vertex
            try file.int(90, outline.edges.len);
            try file.int(70, CLOSED);
            var from = outline.start;
            for (outline.edges) |edge| {
                try file.number(10, from[0]);
                try file.number(20, from[1]);
                if (edge.arc != null) try file.number(42, bulgeOf(edge));
                from = edge.to;
            }
        }
    }
    try file.endSection();
    try file.pair(0, "EOF");
    return out.toOwnedSlice();
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
