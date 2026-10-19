//! Turns a string into 2D outlines: `extractText` lays out glyphs from one of the embedded
//! fonts (`FontKey`, `getFace`), each pair kerned as the font says (kerning.zig), flattens
//! their curves into closed contours scaled to the given size in mm, and aligns the result
//! (`HAlign`, `VAlign`) into `TextPolygons`.

const std = @import("std");
const tatfi = @import("tatfi");
const bezier = @import("bezier.zig");
const Kerning = @import("kerning.zig").Kerning;

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

    pub fn deinit(self: *TextPolygons, alloc: std.mem.Allocator) void {
        for (self.contours.items) |*c| c.deinit(alloc);
        self.contours.deinit(alloc);
    }
};

// Embed all TTF files into the binary (Zero allocation runtime overhead)
pub const fonts = struct {
    pub const sans = @embedFile("fonts/Roboto-Regular.ttf");
    pub const sans_bold = @embedFile("fonts/Roboto-Bold.ttf");
    pub const mono = @embedFile("fonts/RobotoMono-Regular.ttf");
    pub const serif = @embedFile("fonts/RobotoSerif-Regular.ttf");
    pub const stencil = @embedFile("fonts/AllertaStencil-Regular.ttf");
};

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

    fn lastPoint(self: *const BuilderContext) [2]f64 {
        if (self.current_contour) |c| {
            if (c.items.len > 0) {
                return c.items[c.items.len - 1];
            }
        }
        return .{ self.cursor_x, self.cursor_y };
    }
};

// --- tatfi.OutlineBuilder VTable Callbacks ---
fn moveTo(ptr: *anyopaque, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed) return;
    ctx.record(ctx.flushContour());
    if (ctx.failed) return;

    ctx.current_contour = std.ArrayList([2]f64).empty;
    const pt = [2]f64{ ctx.cursor_x + @as(f64, x) * ctx.scale, ctx.cursor_y + @as(f64, y) * ctx.scale };
    ctx.record(ctx.current_contour.?.append(ctx.allocator, pt));
}

fn lineTo(ptr: *anyopaque, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed or ctx.current_contour == null) return;

    const pt = [2]f64{ ctx.cursor_x + @as(f64, x) * ctx.scale, ctx.cursor_y + @as(f64, y) * ctx.scale };
    ctx.record(ctx.current_contour.?.append(ctx.allocator, pt));
}

fn quadTo(ptr: *anyopaque, x1: f32, y1: f32, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed or ctx.current_contour == null) return;

    const p0 = ctx.lastPoint();
    const p1 = [2]f64{ ctx.cursor_x + @as(f64, x1) * ctx.scale, ctx.cursor_y + @as(f64, y1) * ctx.scale };
    const p2 = [2]f64{ ctx.cursor_x + @as(f64, x) * ctx.scale, ctx.cursor_y + @as(f64, y) * ctx.scale };

    ctx.record(bezier.flattenQuadratic(ctx.allocator, &ctx.current_contour.?, p0, p1, p2, ctx.tolerance_sq));
}

fn curveTo(ptr: *anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed or ctx.current_contour == null) return;

    const p0 = ctx.lastPoint();
    const p1 = [2]f64{ ctx.cursor_x + @as(f64, x1) * ctx.scale, ctx.cursor_y + @as(f64, y1) * ctx.scale };
    const p2 = [2]f64{ ctx.cursor_x + @as(f64, x2) * ctx.scale, ctx.cursor_y + @as(f64, y2) * ctx.scale };
    const p3 = [2]f64{ ctx.cursor_x + @as(f64, x) * ctx.scale, ctx.cursor_y + @as(f64, y) * ctx.scale };

    ctx.record(bezier.flattenCubic(ctx.allocator, &ctx.current_contour.?, p0, p1, p2, p3, ctx.tolerance_sq));
}

fn closePath(ptr: *anyopaque) void {
    var ctx: *BuilderContext = @ptrCast(@alignCast(ptr));
    if (ctx.failed) return;
    ctx.record(ctx.flushContour());
}

/// The Main Extraction Engine
/// The first character of `text_str` (valid UTF-8) that `face` has no glyph for.
pub fn firstMissingGlyph(face: *const tatfi.Face, text_str: []const u8) ?u21 {
    var iter = (std.unicode.Utf8View.init(text_str) catch return null).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (face.glyph_index(cp) == null) return cp;
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
    var polygons = TextPolygons{ .contours = .empty };
    errdefer polygons.deinit(allocator);

    // Calculate scaling factor from font design units to physical CAD units (mm)
    const units_per_em: f64 = @floatFromInt(face.units_per_em());
    const scale = size_mm / units_per_em;
    const tol_sq = tolerance * tolerance;

    var ctx = BuilderContext{
        .allocator = allocator,
        .polygons = &polygons,
        .cursor_x = 0.0,
        .cursor_y = 0.0,
        .scale = scale,
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
    var previous: ?tatfi.GlyphId = null;

    // Checked, not assumed: the iterator asserts on a malformed sequence.
    const view = std.unicode.Utf8View.init(text_str) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        // A character the font lacks was left out without a word: `text("中")` made an
        // empty sketch. firstMissingGlyph names it.
        const glyph_id = face.glyph_index(cp) orelse return error.MissingGlyph;
        // The font's kerning moves a glyph closer to the one before it ("AV", "To"), or
        // further from it
        if (previous) |left| ctx.cursor_x += @as(f64, @floatFromInt(kerning.between(left, glyph_id))) * scale;
        previous = glyph_id;
        // Extract outlines and route to flattener
        _ = face.outline_glyph({}, glyph_id, builder);
        if (ctx.failed) return error.OutOfMemory;
        try ctx.flushContour();

        // Advance cursor for next letter
        if (face.glyph_hor_advance({}, glyph_id)) |adv| {
            ctx.cursor_x += @as(f64, @floatFromInt(adv)) * scale;
        }
    }

    alignContours(&polygons, halign, valign);
    return polygons;
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
}
