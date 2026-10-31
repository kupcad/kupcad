//! Turns a string into 2D outlines. `layout` places a line's glyphs: in one of the embedded
//! fonts (`FontKey`, `getFace`) or an imported one, a character the font lacks in the embedded
//! symbol font (`symbolFace`); split by SheenBidi into runs of one direction, drawn in their
//! order, and of one script, each shaped by HarfBuzz (kerning, ligatures, joining forms, marks).
//! `extractText` draws the glyphs' outlines with tatfi, flattening their curves into closed
//! contours scaled to the given size in mm, keeping each curve with the points it became
//! (bezier.zig's `Flattened`, so a drawing writes it exactly), and aligns the result (`HAlign`,
//! `VAlign`) into `TextPolygons`.

const std = @import("std");
const tatfi = @import("tatfi");
const hb = @import("harfbuzz");
const bidi = @import("sheenbidi");
const bezier = @import("bezier.zig");

/// A parsed font (tatfi's), which the functions here draw with; their callers name it so.
pub const Face = tatfi.Face;

/// The names `text(font:)` takes for the embedded fonts: each font's own, then its aliases.
const FONT_NAMES = [_]struct { name: []const u8, key: FontKey }{
    .{ .name = "sans", .key = .sans },
    .{ .name = "sans-bold", .key = .sans_bold },
    .{ .name = "mono", .key = .mono },
    .{ .name = "serif", .key = .serif },
    .{ .name = "stencil", .key = .stencil },
    .{ .name = "default", .key = .sans },
    // A Symbol can't hold the dash: `font: :sans_bold`
    .{ .name = "sans_bold", .key = .sans_bold },
    .{ .name = "monospace", .key = .mono },
};

/// The longest font name a Font takes from its font file: longer, it is named after the file.
pub const MAX_FONT_NAME_BYTES = 256;

/// The embedded fonts' own names, for an error that lists them: `"sans", "mono", ...`.
pub const FONT_LIST = blk: {
    const keys = std.enums.values(FontKey);
    var text: []const u8 = "";
    for (keys, 0..) |key, i| {
        const separator = if (i == 0) "" else if (i + 1 == keys.len) " and " else ", ";
        text = text ++ separator ++ "\"" ++ key.name() ++ "\"";
    }
    break :blk text;
};

pub const FontKey = enum {
    sans,
    /// Roboto Bold: strokes 0.14 of the size against sans's 0.09, for text printed small
    sans_bold,
    mono,
    serif,
    stencil,

    /// The font named `name` (its own name or an alias), or null for none of them.
    pub fn fromString(name_or_alias: []const u8) ?FontKey {
        for (FONT_NAMES) |entry| {
            if (std.mem.eql(u8, entry.name, name_or_alias)) return entry.key;
        }
        return null;
    }

    /// The font's own name, as `text(font:)` takes it.
    pub fn name(self: FontKey) []const u8 {
        for (FONT_NAMES) |entry| {
            if (entry.key == self) return entry.name;
        }
        unreachable;
    }
};

pub const HAlign = enum { left, center, right };
pub const VAlign = enum { baseline, bottom, center, top };

pub const TextPolygons = struct {
    // A list of closed contours. Each contour is an array of [2]f64 points.
    contours: std.ArrayList(std.ArrayList([2]f64)),
    /// The curves the contours' points were flattened from, in the order drawn.
    curves: std.ArrayList(bezier.Flattened),

    pub fn deinit(self: *TextPolygons, alloc: std.mem.Allocator) void {
        for (self.contours.items) |*c| c.deinit(alloc);
        self.contours.deinit(alloc);
        self.curves.deinit(alloc);
    }
};

// Embed all TTF files into the binary (Zero allocation runtime overhead)
pub const fonts = struct {
    pub const sans = @embedFile("fonts/Roboto-Regular.ttf");
    pub const sans_bold = @embedFile("fonts/Roboto-Bold.ttf");
    pub const mono = @embedFile("fonts/RobotoMono-Regular.ttf");
    pub const serif = @embedFile("fonts/RobotoSerif-Regular.ttf");
    pub const stencil = @embedFile("fonts/AllertaStencil-Regular.ttf");
    /// KupCAD Symbols: the symbols of drawings, tolerances, panels and labels, which a text's
    /// font lacks (scripts/make-symbol-font.py makes it from three Noto fonts)
    pub const symbols = @embedFile("fonts/KupCADSymbols-Regular.ttf");
};

/// The symbol font, which draws a character the text's font has no glyph for.
pub fn symbolFace() !tatfi.Face {
    return tatfi.Face.parse(fonts.symbols, 0) catch return error.InvalidFont;
}

pub fn getFontBytes(key: FontKey) []const u8 {
    return switch (key) {
        .sans => fonts.sans,
        .sans_bold => fonts.sans_bold,
        .mono => fonts.mono,
        .serif => fonts.serif,
        .stencil => fonts.stencil,
    };
}

/// Parses and returns a tatfi.Face for the given FontKey
pub fn getFace(key: FontKey) !tatfi.Face {
    const bytes = getFontBytes(key);
    return tatfi.Face.parse(bytes, 0) catch return error.InvalidFont;
}

const BuilderContext = struct {
    allocator: std.mem.Allocator,
    polygons: *TextPolygons,
    current_contour: ?std.ArrayList([2]f64) = null,
    cursor_x: f64,
    cursor_y: f64,
    scale: f64,
    tolerance_sq: f64,
    /// The outline callbacks can't return errors, so an allocation failure in one is kept
    /// here and reported after the glyph: it used to drop points, truncating the outline.
    failed: bool = false,

    fn record(self: *BuilderContext, result: anyerror!void) void {
        result catch {
            self.failed = true;
        };
    }

    fn flushContour(self: *BuilderContext) !void {
        if (self.current_contour) |*c| {
            if (c.items.len > 0) {
                try self.polygons.contours.append(self.allocator, c.*);
            } else {
                c.deinit(self.allocator);
            }
            self.current_contour = null;
        }
    }

    /// The font's point (`x`, `y`) in mm, where the cursor has the glyph.
    fn point(self: *const BuilderContext, x: f32, y: f32) [2]f64 {
        return .{ self.cursor_x + @as(f64, x) * self.scale, self.cursor_y + @as(f64, y) * self.scale };
    }

    /// Keeps `cubic`, just flattened into the contour's points from `first` on (the
    /// contour's index is the one it gets when flushed: it has its first point, so it
    /// will be).
    fn keepCurve(self: *BuilderContext, first: usize, cubic: bezier.Cubic) void {
        if (self.failed) return;
        self.record(self.polygons.curves.append(self.allocator, .{
            .contour = @intCast(self.polygons.contours.items.len),
            .first = @intCast(first),
            .count = @intCast(self.current_contour.?.items.len - first),
            .cubic = cubic,
        }));
    }
};

// --- tatfi.OutlineBuilder VTable Callbacks ---
fn moveTo(ptr: *anyopaque, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed) return;
    ctx.record(ctx.flushContour());
    if (ctx.failed) return;

    ctx.current_contour = std.ArrayList([2]f64).empty;
    ctx.record(ctx.current_contour.?.append(ctx.allocator, ctx.point(x, y)));
}

fn lineTo(ptr: *anyopaque, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed or ctx.current_contour == null) return;
    ctx.record(ctx.current_contour.?.append(ctx.allocator, ctx.point(x, y)));
}

/// A TrueType quadratic: flattened as one, kept as the cubic it is exactly, so every
/// curve a drawing writes is one kind.
fn quadTo(ptr: *anyopaque, x1: f32, y1: f32, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed or ctx.current_contour == null) return;
    const contour = &ctx.current_contour.?;
    const first = contour.items.len - 1;
    const p0 = contour.items[first];
    const q = ctx.point(x1, y1);
    const end = ctx.point(x, y);
    ctx.record(bezier.flattenQuadratic(ctx.allocator, contour, p0, q, end, ctx.tolerance_sq));
    ctx.keepCurve(first, bezier.quadraticAsCubic(p0, q, end));
}

fn curveTo(ptr: *anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed or ctx.current_contour == null) return;
    const contour = &ctx.current_contour.?;
    const first = contour.items.len - 1;
    const cubic = bezier.Cubic{ .c1 = ctx.point(x1, y1), .c2 = ctx.point(x2, y2) };
    ctx.record(bezier.flattenCubic(ctx.allocator, contour, contour.items[first], cubic.c1, cubic.c2, ctx.point(x, y), ctx.tolerance_sq));
    ctx.keepCurve(first, cubic);
}

fn closePath(ptr: *anyopaque) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed) return;
    ctx.record(ctx.flushContour());
}

/// Which font a glyph is drawn from: the text's own, or the symbol font standing in for it.
pub const Source = enum { text, symbols };

/// The font that draws `cp`: the text's, else the symbol font; null when neither has it.
fn sourceOf(face: *const tatfi.Face, symbols: *const tatfi.Face, cp: u21) ?Source {
    if (face.glyph_index(cp) != null) return .text;
    if (symbols.glyph_index(cp) != null) return .symbols;
    return null;
}

/// The first character of `text_str` (valid UTF-8) that neither `face` nor the symbol font has
/// a glyph for.
pub fn firstMissingGlyph(face: *const tatfi.Face, text_str: []const u8) ?u21 {
    const symbols = symbolFace() catch return null;
    var iter = (std.unicode.Utf8View.init(text_str) catch return null).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (sourceOf(face, &symbols, cp) == null) return cp;
    }
    return null;
}

/// Why a font file a script imports can't be drawn with.
pub const ImportedFontError = error{
    /// tatfi can't read it as a font
    InvalidFont,
    /// It has no outlines text draws: TrueType's (glyf) or CFF's. A variable CFF2 font's
    /// aren't read, nor a bitmap font's images.
    NoOutlines,
    /// It maps no characters to glyphs (no cmap table)
    NoCharacterMap,
};

/// The face of the font file `bytes`, which a script imported: anything, so checked for what
/// text needs before it draws with it. The bytes must outlive the face.
pub fn importedFace(bytes: []const u8) ImportedFontError!tatfi.Face {
    const face = tatfi.Face.parse(bytes, 0) catch return error.InvalidFont;
    if (face.tables.glyf == null and face.tables.cff == null) return error.NoOutlines;
    if (face.tables.cmap == null) return error.NoCharacterMap;
    return face;
}

/// The font's name for a person, as its name table gives it: its full name (`Inter Bold`),
/// else its family and style, from the first record of each in Unicode. Null for a font that
/// gives neither, or a name past MAX_FONT_NAME_BYTES. The caller owns it.
pub fn fontName(allocator: std.mem.Allocator, face: *const tatfi.Face) !?[]const u8 {
    const names = (face.tables.name orelse return null).names;
    if (try nameRecord(allocator, names, .full_name)) |full| return full;
    const family = try nameRecord(allocator, names, .family) orelse return null;
    defer allocator.free(family);
    const style = try nameRecord(allocator, names, .subfamily) orelse return try allocator.dupe(u8, family);
    defer allocator.free(style);
    if (family.len + 1 + style.len > MAX_FONT_NAME_BYTES) return null;
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ family, style });
}

/// The first Unicode record of `id` in `names`, as UTF-8, if one is short enough.
fn nameRecord(allocator: std.mem.Allocator, names: tatfi.tables.name.Names, id: tatfi.tables.name.NameId) !?[]const u8 {
    var it = names.iterator();
    while (it.next()) |record| {
        if (record.name_id != id or !record.is_unicode()) continue;
        // Two bytes a UTF-16 unit, up to three in UTF-8: a name too long is refused unread
        if (record.name.len / 2 * 3 > MAX_FONT_NAME_BYTES) return null;
        const text = record.to_string(allocator) orelse continue;
        if (text.len == 0) {
            allocator.free(text);
            continue;
        }
        return text;
    }
    return null;
}

/// A glyph laid out: its font, its id there, and where its origin is, in mm.
pub const Placed = struct { source: Source, glyph: tatfi.GlyphId, x: f64, y: f64 };

/// The glyphs of `text_str`, one line `size_mm` high (an em), from left to right as they are
/// drawn: each character in `face`, or in `symbols` when `face` lacks it, a character neither
/// has an error (firstMissingGlyph names it). The caller owns the slice.
pub fn layout(allocator: std.mem.Allocator, face: *const tatfi.Face, symbols: *const tatfi.Face, text_str: []const u8, size_mm: f64) ![]Placed {
    // Checked, not assumed: the iterator asserts on a malformed sequence
    const view = std.unicode.Utf8View.init(text_str) catch return error.InvalidUtf8;
    // Each byte's font, its character's: a character the font lacked was left out without a
    // word (`text("中")` made an empty sketch)
    const sources = try allocator.alloc(Source, text_str.len);
    defer allocator.free(sources);
    var iter = view.iterator();
    var at: usize = 0;
    while (iter.nextCodepointSlice()) |slice| : (at += slice.len) {
        const cp = std.unicode.utf8Decode(slice) catch unreachable;
        @memset(sources[at..][0..slice.len], sourceOf(face, symbols, cp) orelse return error.MissingGlyph);
    }

    var placed: std.ArrayList(Placed) = .empty;
    errdefer placed.deinit(allocator);
    if (text_str.len == 0) return placed.toOwnedSlice(allocator);

    var shapers = [_]Shaper{ .init(face, size_mm), .init(symbols, size_mm) };
    defer for (&shapers) |*shaper| shaper.deinit();
    const sequence = bidi.CodepointSequence{ .string_encoding = bidi.encoding_utf8, .string_buffer = text_str.ptr, .string_length = text_str.len };
    const script_ends = try scriptEnds(allocator, &sequence);
    defer allocator.free(script_ends);

    const algorithm = bidi.SBAlgorithmCreate(&sequence) orelse return error.OutOfMemory;
    defer bidi.SBAlgorithmRelease(algorithm);
    var cursor: f64 = 0;
    var paragraph_start: usize = 0;
    // A paragraph ends at a separator the font has a glyph for: the next goes on along the line
    while (paragraph_start < text_str.len) {
        const paragraph = bidi.SBAlgorithmCreateParagraph(algorithm, paragraph_start, text_str.len - paragraph_start, bidi.level_default_ltr) orelse return error.OutOfMemory;
        defer bidi.SBParagraphRelease(paragraph);
        const paragraph_length = bidi.SBParagraphGetLength(paragraph);
        const line = bidi.SBParagraphCreateLine(paragraph, paragraph_start, paragraph_length) orelse return error.OutOfMemory;
        defer bidi.SBLineRelease(line);
        for (bidi.SBLineGetRunsPtr(line)[0..bidi.SBLineGetRunCount(line)]) |run| {
            try placeRun(allocator, &placed, &shapers, text_str, sources, script_ends, run, &cursor);
        }
        paragraph_start += paragraph_length;
    }
    return placed.toOwnedSlice(allocator);
}

/// A font as HarfBuzz shapes with it, made from the bytes tatfi read the face from, and the
/// scale from its units to mm.
const Shaper = struct {
    blob: *hb.Blob,
    face: *hb.Face,
    font: *hb.Font,
    scale: f64,

    fn init(face: *const tatfi.Face, size_mm: f64) Shaper {
        const data = face.raw_face.data;
        const blob = hb.hb_blob_create(data.ptr, @intCast(data.len), .readonly, null, null);
        const hb_face = hb.hb_face_create(blob, 0);
        return .{ .blob = blob, .face = hb_face, .font = hb.hb_font_create(hb_face), .scale = scaleOf(face, size_mm) };
    }

    fn deinit(self: *Shaper) void {
        hb.hb_font_destroy(self.font);
        hb.hb_face_destroy(self.face);
        hb.hb_blob_destroy(self.blob);
    }
};

/// Where each of the text's runs of one script ends, a byte offset, in order.
fn scriptEnds(allocator: std.mem.Allocator, sequence: *const bidi.CodepointSequence) ![]usize {
    const locator = bidi.SBScriptLocatorCreate() orelse return error.OutOfMemory;
    defer bidi.SBScriptLocatorRelease(locator);
    bidi.SBScriptLocatorLoadCodepoints(locator, sequence);
    var ends: std.ArrayList(usize) = .empty;
    errdefer ends.deinit(allocator);
    while (bidi.SBScriptLocatorMoveNext(locator) != 0) {
        const agent = bidi.SBScriptLocatorGetAgent(locator);
        try ends.append(allocator, agent.offset + agent.length);
    }
    return ends.toOwnedSlice(allocator);
}

/// Places `run`, a run of one direction, after `cursor`: shaped in pieces of one script and
/// one font, a right-to-left run's from its end, so its first character is drawn rightmost.
fn placeRun(allocator: std.mem.Allocator, placed: *std.ArrayList(Placed), shapers: *[2]Shaper, text_str: []const u8, sources: []const Source, script_ends: []const usize, run: bidi.Run, cursor: *f64) !void {
    const rtl = run.level % 2 == 1;
    var pieces: std.ArrayList([2]usize) = .empty;
    defer pieces.deinit(allocator);
    const end = run.offset + run.length;
    var start = run.offset;
    for (run.offset + 1..end + 1) |at| {
        const boundary = at == end or sources[at] != sources[at - 1] or std.mem.indexOfScalar(usize, script_ends, at) != null;
        if (!boundary) continue;
        try pieces.append(allocator, .{ start, at });
        start = at;
    }
    if (rtl) std.mem.reverse([2]usize, pieces.items);
    for (pieces.items) |piece| {
        const source = sources[piece[0]];
        try shape(allocator, placed, &shapers[@backingInt(source)], source, text_str, piece, if (rtl) .rtl else .ltr, cursor);
    }
}

/// Shapes `piece` of `text_str` (the whole line its context) with `shaper`, placing its
/// glyphs after `cursor` and moving it past them.
fn shape(allocator: std.mem.Allocator, placed: *std.ArrayList(Placed), shaper: *const Shaper, source: Source, text_str: []const u8, piece: [2]usize, direction: hb.Direction, cursor: *f64) !void {
    const buffer = hb.hb_buffer_create();
    defer hb.hb_buffer_destroy(buffer);
    hb.hb_buffer_add_utf8(buffer, text_str.ptr, @intCast(text_str.len), @intCast(piece[0]), @intCast(piece[1] - piece[0]));
    hb.hb_buffer_set_direction(buffer, direction);
    // The piece is one script: HarfBuzz reads which from its characters
    hb.hb_buffer_guess_segment_properties(buffer);
    hb.hb_shape(shaper.font, buffer, null, 0);
    if (hb.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
    var count: c_uint = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buffer, &count)[0..count];
    const positions = hb.hb_buffer_get_glyph_positions(buffer, &count)[0..count];
    for (infos, positions) |info, position| {
        const glyph = std.math.cast(u16, info.codepoint) orelse return error.InvalidFont;
        try placed.append(allocator, .{
            .source = source,
            .glyph = .{glyph},
            .x = cursor.* + @as(f64, @floatFromInt(position.x_offset)) * shaper.scale,
            .y = @as(f64, @floatFromInt(position.y_offset)) * shaper.scale,
        });
        cursor.* += @as(f64, @floatFromInt(position.x_advance)) * shaper.scale;
    }
}

pub fn extractText(
    allocator: std.mem.Allocator,
    face: *const tatfi.Face,
    text_str: []const u8,
    size_mm: f64,
    tolerance: f64,
    halign: HAlign,
    valign: VAlign,
) !TextPolygons {
    const symbols = try symbolFace();
    const glyphs = try layout(allocator, face, &symbols, text_str, size_mm);
    defer allocator.free(glyphs);

    var polygons = TextPolygons{ .contours = .empty, .curves = .empty };
    errdefer polygons.deinit(allocator);
    var ctx = BuilderContext{
        .allocator = allocator,
        .polygons = &polygons,
        .cursor_x = 0.0,
        .cursor_y = 0.0,
        .scale = 0.0,
        .tolerance_sq = tolerance * tolerance,
    };
    errdefer if (ctx.current_contour) |*c| c.deinit(allocator);
    const builder = tatfi.OutlineBuilder{
        .ptr = &ctx,
        .vtable = .{
            .move_to = moveTo,
            .line_to = lineTo,
            .quad_to = quadTo,
            .curve_to = curveTo,
            .close = closePath,
        },
    };

    // By Source
    const faces = [_]*const tatfi.Face{ face, &symbols };
    for (glyphs) |glyph| {
        const glyph_face = faces[@backingInt(glyph.source)];
        ctx.scale = scaleOf(glyph_face, size_mm);
        ctx.cursor_x = glyph.x;
        ctx.cursor_y = glyph.y;
        _ = glyph_face.outline_glyph({}, glyph.glyph, builder);
        if (ctx.failed) return error.OutOfMemory;
        try ctx.flushContour();
    }

    alignContours(&polygons, halign, valign);
    return polygons;
}

/// The scale from `face`'s design units to mm, for text `size_mm` high (an em).
fn scaleOf(face: *const tatfi.Face, size_mm: f64) f64 {
    return size_mm / @as(f64, @floatFromInt(face.units_per_em()));
}

/// Moves `polygons` so their bounding box sits as `halign` and `valign` say against the
/// origin; left and baseline leave them where the layout put them.
fn alignContours(polygons: *TextPolygons, halign: HAlign, valign: VAlign) void {
    if (halign == .left and valign == .baseline) return;
    var min_x: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    for (polygons.contours.items) |c| for (c.items) |pt| {
        min_x = @min(min_x, pt[0]);
        max_x = @max(max_x, pt[0]);
        min_y = @min(min_y, pt[1]);
        max_y = @max(max_y, pt[1]);
    };
    // Empty text has nothing to move
    if (min_x > max_x) return;
    const dx: f64 = switch (halign) {
        .left => 0,
        .center => -(min_x + max_x) / 2.0,
        .right => -max_x,
    };
    const dy: f64 = switch (valign) {
        .baseline => 0,
        .bottom => -min_y,
        .center => -(min_y + max_y) / 2.0,
        .top => -max_y,
    };
    for (polygons.contours.items) |*c| for (c.items) |*pt| {
        pt[0] += dx;
        pt[1] += dy;
    };
    for (polygons.curves.items) |*curve| {
        for ([_]*[2]f64{ &curve.cubic.c1, &curve.cubic.c2 }) |control| {
            control[0] += dx;
            control[1] += dy;
        }
    }
}
