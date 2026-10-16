//! Turns a string into 2D outlines: `extractText` lays out glyphs from one of the embedded
//! fonts (`FontKey`, `getFace`), flattens their curves into closed contours scaled to the
//! given size in mm, and aligns the result (`HAlign`, `VAlign`) into `TextPolygons`.

const std = @import("std");
const tatfi = @import("tatfi");
const bezier = @import("bezier.zig");

pub const FontKey = enum {
    sans,
    mono,
    serif,
    stencil,

    pub fn fromString(name: []const u8) ?FontKey {
        if (std.mem.eql(u8, name, "sans") or std.mem.eql(u8, name, "default")) return .sans;
        if (std.mem.eql(u8, name, "mono") or std.mem.eql(u8, name, "monospace")) return .mono;
        if (std.mem.eql(u8, name, "serif")) return .serif;
        if (std.mem.eql(u8, name, "stencil")) return .stencil;
        return null;
    }
};

pub const HAlign = enum { left, center, right };
pub const VAlign = enum { baseline, bottom, center, top };

pub const TextPolygons = struct {
    // A list of closed contours. Each contour is an array of [2]f64 points.
    contours: std.ArrayListUnmanaged(std.ArrayListUnmanaged([2]f64)),

    pub fn deinit(self: *TextPolygons, alloc: std.mem.Allocator) void {
        for (self.contours.items) |*c| c.deinit(alloc);
        self.contours.deinit(alloc);
    }
};

// Embed all TTF files into the binary (Zero allocation runtime overhead)
pub const fonts = struct {
    pub const sans = @embedFile("fonts/Roboto-Regular.ttf");
    pub const mono = @embedFile("fonts/RobotoMono-Regular.ttf");
    pub const serif = @embedFile("fonts/RobotoSerif-Regular.ttf");
    pub const stencil = @embedFile("fonts/AllertaStencil-Regular.ttf");
};

pub fn getFontBytes(key: FontKey) []const u8 {
    return switch (key) {
        .sans => fonts.sans,
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

/// Parses and returns a tatfi.Face by string name (defaults to :sans if unknown)
pub fn getFaceByName(name: []const u8) !tatfi.Face {
    const key = FontKey.fromString(name) orelse .sans;
    return getFace(key);
}

/// Helper for backwards compatibility
pub fn getDefaultFace() !tatfi.Face {
    return getFace(.sans);
}

const BuilderContext = struct {
    allocator: std.mem.Allocator,
    polygons: *TextPolygons,
    current_contour: ?std.ArrayListUnmanaged([2]f64) = null,
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

    ctx.current_contour = std.ArrayListUnmanaged([2]f64).empty;
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

    const GpaType = @typeInfo(@TypeOf(tatfi.Face.glyph_hor_advance)).@"fn".param_types[1].?;
    const gpa_val: GpaType = if (GpaType == void) {} else allocator;

    // Checked, not assumed: the iterator asserts on a malformed sequence.
    const view = std.unicode.Utf8View.init(text_str) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        // A character the font lacks was left out without a word: `text("中")` made an
        // empty sketch. firstMissingGlyph names it.
        const glyph_id = face.glyph_index(cp) orelse return error.MissingGlyph;
        // Extract outlines and route to flattener
        _ = face.outline_glyph(gpa_val, glyph_id, builder);
        if (ctx.failed) return error.OutOfMemory;
        try ctx.flushContour();

        // Advance cursor for next letter
        if (face.glyph_hor_advance(gpa_val, glyph_id)) |adv| {
            ctx.cursor_x += @as(f64, @floatFromInt(adv)) * scale;
        }
    }

    // --- Text Alignment Post-Shift ---
    if (halign != .left or valign != .baseline) {
        var min_x: f64 = std.math.inf(f64);
        var max_x: f64 = -std.math.inf(f64);
        var min_y: f64 = std.math.inf(f64);
        var max_y: f64 = -std.math.inf(f64);

        // 1. Calculate physical bounding box
        for (polygons.contours.items) |c| {
            for (c.items) |pt| {
                if (pt[0] < min_x) min_x = pt[0];
                if (pt[0] > max_x) max_x = pt[0];
                if (pt[1] < min_y) min_y = pt[1];
                if (pt[1] > max_y) max_y = pt[1];
            }
        }

        // 2. Apply offsets if text isn't empty
        if (min_x <= max_x) {
            var dx: f64 = 0.0;
            var dy: f64 = 0.0;

            switch (halign) {
                .left => dx = 0.0, // Standard typography baseline start
                .center => dx = -(min_x + max_x) / 2.0,
                .right => dx = -max_x,
            }
            switch (valign) {
                .baseline => dy = 0.0, // Standard typography Y=0
                .bottom => dy = -min_y,
                .center => dy = -(min_y + max_y) / 2.0,
                .top => dy = -max_y,
            }

            if (dx != 0.0 or dy != 0.0) {
                for (polygons.contours.items) |*c| {
                    for (c.items) |*pt| {
                        pt.*[0] += dx;
                        pt.*[1] += dy;
                    }
                }
            }
        }
    }

    return polygons;
}
