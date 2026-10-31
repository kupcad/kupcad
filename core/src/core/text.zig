//! Turns a string into 2D outlines: `extractText` lays out glyphs from one of the embedded
//! fonts (`FontKey`, `getFace`) or an imported one, each pair kerned as the font says
//! (kerning.zig), a character the font lacks drawn from the embedded symbol font
//! (`symbolFace`), flattens their curves into closed contours scaled to the given size in mm,
//! keeping each curve with the points it became (bezier.zig's `Flattened`, so a drawing writes
//! it exactly), and aligns the result (`HAlign`, `VAlign`) into `TextPolygons`.

const std = @import("std");
const tatfi = @import("tatfi");
const bezier = @import("bezier.zig");
const Kerning = @import("kerning.zig").Kerning;

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

/// The first character of `text_str` (valid UTF-8) that neither `face` nor the symbol font has
/// a glyph for.
pub fn firstMissingGlyph(face: *const tatfi.Face, text_str: []const u8) ?u21 {
    const symbols = symbolFace() catch null;
    var iter = (std.unicode.Utf8View.init(text_str) catch return null).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (face.glyph_index(cp) != null) continue;
        if (symbols) |s| if (s.glyph_index(cp) != null) continue;
        return cp;
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

pub fn extractText(
    allocator: std.mem.Allocator,
    face: *const tatfi.Face,
    text_str: []const u8,
    size_mm: f64,
    tolerance: f64,
    halign: HAlign,
    valign: VAlign,
) !TextPolygons {
    var polygons = TextPolygons{ .contours = .empty, .curves = .empty };
    errdefer polygons.deinit(allocator);

    const tol_sq = tolerance * tolerance;

    var ctx = BuilderContext{
        .allocator = allocator,
        .polygons = &polygons,
        .cursor_x = 0.0,
        .cursor_y = 0.0,
        .scale = scaleOf(face, size_mm),
        .tolerance_sq = tol_sq,
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

    var kerning = try Kerning.init(allocator, face);
    defer kerning.deinit(allocator);
    // The glyph before, when it is the text's font's: kerning is between two of its own
    var previous: ?tatfi.GlyphId = null;
    // Parsed when a character first needs it
    var symbols: ?tatfi.Face = null;

    // Checked, not assumed: the iterator asserts on a malformed sequence.
    const view = std.unicode.Utf8View.init(text_str) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        // A character the font lacks comes from the symbol font, at the same size and on
        // the same baseline; one neither has was left out without a word (`text("中")` made
        // an empty sketch): firstMissingGlyph names it.
        const drawn: struct { face: *const tatfi.Face, glyph: tatfi.GlyphId } = if (face.glyph_index(cp)) |glyph| .{ .face = face, .glyph = glyph } else blk: {
            if (symbols == null) symbols = try symbolFace();
            const glyph = symbols.?.glyph_index(cp) orelse return error.MissingGlyph;
            break :blk .{ .face = &symbols.?, .glyph = glyph };
        };
        ctx.scale = scaleOf(drawn.face, size_mm);
        if (drawn.face == face) {
            // The font's kerning moves a glyph closer to the one before it ("AV", "To"), or
            // further from it
            if (previous) |left| ctx.cursor_x += @as(f64, @floatFromInt(kerning.between(left, drawn.glyph))) * ctx.scale;
            previous = drawn.glyph;
        } else previous = null;
        _ = drawn.face.outline_glyph({}, drawn.glyph, builder);
        if (ctx.failed) return error.OutOfMemory;
        try ctx.flushContour();

        if (drawn.face.glyph_hor_advance({}, drawn.glyph)) |adv| {
            ctx.cursor_x += @as(f64, @floatFromInt(adv)) * ctx.scale;
        }
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
