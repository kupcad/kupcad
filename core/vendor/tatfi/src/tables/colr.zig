//! A [Color Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/colr) implementation.

// NOTE: Parts of the implementation have been inspired by
// [skrifa](https://github.com/googlefonts/fontations/tree/main/skrifa).

const std = @import("std");
const cfg = @import("config");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const cpalTable = @import("cpal.zig");

const ItemVariationStore = @import("../var_store.zig");
const DeltaSetIndexMap = @import("../delta_set.zig");

const Table = @This();

palettes: cpalTable,
data: []const u8,
version: u8,

// v0
base_glyphs: parser.LazyArray16(BaseGlyphRecord),
layers: parser.LazyArray16(LayerRecord),

// v1
base_glyph_paints_offset: parser.Offset32,
base_glyph_paints: parser.LazyArray32(BaseGlyphPaintRecord),
layer_paint_offsets_offset: parser.Offset32,
layer_paint_offsets: parser.LazyArray32(parser.Offset32),
clip_list_offsets_offset: parser.Offset32,
clip_list: ClipList,
variable_fonts: if (cfg.variable_fonts) struct {
    var_index_map: ?DeltaSetIndexMap = null,
    item_variation_store: ?ItemVariationStore = null,
} else void,

/// Parses a table from raw data.
pub fn parse(
    palettes: cpalTable,
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u16);
    if (version > 1) return error.ParseFail;

    const num_base_glyphs = try s.read(u16);
    const base_glyphs_offset = try s.read(parser.Offset32);
    const layers_offset = try s.read(parser.Offset32);
    const num_layers = try s.read(u16);

    const base_glyphs = bg: {
        var sbg = try parser.Stream.new_at(data, base_glyphs_offset[0]);
        break :bg try sbg.read_array(BaseGlyphRecord, num_base_glyphs);
    };

    const layers = l: {
        var sl = try parser.Stream.new_at(data, layers_offset[0]);
        break :l try sl.read_array(LayerRecord, num_layers);
    };

    var table: Table = .{
        .version = @truncate(version),
        .data = data,
        .palettes = palettes,
        .base_glyphs = base_glyphs,
        .layers = layers,

        .base_glyph_paints_offset = .{0}, // the actual value doesn't matter
        .base_glyph_paints = .{},
        .layer_paint_offsets_offset = .{0},
        .layer_paint_offsets = .{},
        .clip_list_offsets_offset = .{0},
        .clip_list = .{},
        .variable_fonts = if (cfg.variable_fonts) .{},
    };

    if (version == 0) return table;

    table.base_glyph_paints_offset = try s.read(parser.Offset32);
    const layer_list_offset = try s.read_optional(parser.Offset32);
    const clip_list_offset = try s.read_optional(parser.Offset32);

    const var_index_map_offset = if (cfg.variable_fonts)
        try s.read_optional(parser.Offset32)
    else {};

    const item_variation_offset = if (cfg.variable_fonts)
        try s.read_optional(parser.Offset32)
    else {};

    table.base_glyph_paints = bgp: {
        var sbg = try parser.Stream.new_at(data, table.base_glyph_paints_offset[0]);
        const count = try sbg.read(u32);
        break :bgp try sbg.read_array(BaseGlyphPaintRecord, count);
    };

    if (layer_list_offset) |offset| {
        table.layer_paint_offsets_offset = offset;

        var sll = try parser.Stream.new_at(data, offset[0]);
        const count = try sll.read(u32);

        table.layer_paint_offsets = try sll.read_array(parser.Offset32, count);
    }

    if (clip_list_offset) |offset| {
        table.clip_list_offsets_offset = offset;

        const clip_data = try utils.slice(data, offset[0]);
        var scl = parser.Stream.new(clip_data);
        scl.skip(u8); // Format
        const count = try scl.read(u32);
        table.clip_list = .{
            .data = clip_data,
            .records = try scl.read_array(ClipRecord, count),
        };
    }

    if (cfg.variable_fonts) {
        if (item_variation_offset) |offset| {
            const item_var_data = try utils.slice(data, offset[0]);
            var siv = parser.Stream.new(item_var_data);
            table.variable_fonts.item_variation_store =
                try ItemVariationStore.parse(&siv);
        }

        if (var_index_map_offset) |offset|
            table.variable_fonts.var_index_map = .{
                .data = try utils.slice(data, offset[0]),
            };
    }

    return table;
}

/// Returns `true` if the current table has version 0.
///
/// A simple table can only emit `outline_glyph`, `paint`, `push_clip`, and
/// `pop_clip` `Painter` methods.
pub fn is_simple(self: Table) bool {
    return self.version == 0;
}

/// Whether the table contains a definition for the given glyph.
pub fn contains(
    self: *const Table,
    glyph_id: lib.GlyphId,
) bool {
    return self.get_v1(glyph_id) != null or self.get_v0(glyph_id) != null;
}

fn get_v0(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?BaseGlyphRecord {
    _, const ret = self.base_glyphs.binary_search_by(
        glyph_id,
        BaseGlyphRecord.compare,
    ) catch return null;
    return ret;
}

fn get_v1(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?BaseGlyphPaintRecord {
    _, const ret = self.base_glyph_paints.binary_search_by(
        glyph_id,
        BaseGlyphPaintRecord.compare,
    ) catch return null;
    return ret;
}

/// Returns the clip box for a glyph.
pub fn clip_box(
    self: *const Table,
    glyph_id: lib.GlyphId,
    coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
) ?ClipBox {
    const v = self.variation_data();
    return self.clip_list.find(
        glyph_id,
        &v,
        coords,
    );
}

fn variation_data(
    self: *const Table,
) VariationData {
    return .{
        .variation_store = self.variable_fonts.item_variation_store,
        .delta_map = self.variable_fonts.var_index_map,
    };
}

// This method should only be called from outside, not from within `colr.rs`.
// From inside, you always should call paint_impl, so that the recursion stack can
// be passed on and any kind of recursion can be prevented.
/// Paints the color glyph.
pub fn paint(
    self: *const Table,
    glyph_id: lib.GlyphId,
    palette: u16,
    painter: Painter,
    coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
    foreground_color: lib.RgbaColor,
) Error!void {
    // The limit of 64 is chosen arbitrarily and not from the spec. But we have to stop somewhere...
    var recursion_stack_buffer: [64]usize = @splat(0);
    var recursion_stack: std.ArrayList(usize) = .initBuffer(&recursion_stack_buffer);

    return try self.paint_impl(
        glyph_id,
        palette,
        painter,
        &recursion_stack,
        coords,
        foreground_color,
    );
}

fn paint_impl(
    self: *const Table,
    glyph_id: lib.GlyphId,
    palette: u16,
    painter: Painter,
    recursion_stack: *std.ArrayList(usize),
    coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
    foreground_color: lib.RgbaColor,
) Error!void {
    if (self.get_v1(glyph_id)) |base|
        return self.paint_v1(
            base,
            palette,
            painter,
            recursion_stack,
            coords,
            foreground_color,
        )
    else if (self.get_v0(glyph_id)) |base|
        return try self.paint_v0(
            base,
            palette,
            painter,
            foreground_color,
        )
    else
        return error.PaintError;
}

fn paint_v0(
    self: *const Table,
    base: BaseGlyphRecord,
    palette: u16,
    painter: Painter,
    foreground_color: lib.RgbaColor,
) Error!void {
    const start = base.first_layer_index;
    const end = std.math.add(u16, start, base.num_layers) catch return error.PaintError;
    const layers = self.layers.slice(start, end);

    var iter = layers.iterator();
    while (iter.next()) |layer| {
        painter.outline_glyph(layer.glyph_id);
        painter.push_clip();
        if (layer.palette_index == 0xFFFF)
            // A special case.
            painter.paint(.{ .solid = foreground_color })
        else
            painter.paint(.{
                .solid = self.palettes.get(palette, layer.palette_index) orelse
                    return error.PaintError,
            });

        painter.pop_clip();
    }
}

fn paint_v1(
    self: *const Table,
    base: BaseGlyphPaintRecord,
    palette: u16,
    painter: Painter,
    recursion_stack: *std.ArrayList(usize),
    coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
    foreground_color: lib.RgbaColor,
) void {
    const clip_box_maybe = self.clip_box(base.glyph_id, coords);

    if (clip_box_maybe) |box| painter.push_clip_box(box);
    defer if (clip_box_maybe != null) painter.pop_clip();

    self.parse_paint(
        self.base_glyph_paints_offset[0] + base.paint_table_offset[0],
        palette,
        painter,
        recursion_stack,
        coords,
        foreground_color,
    ) catch {};
}

fn parse_paint(
    self: *const Table,
    offset: usize,
    palette: u16,
    painter: Painter,
    recursion_stack: *std.ArrayList(usize),
    coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
    foreground_color: lib.RgbaColor,
) parser.Error!void {
    var s = try parser.Stream.new_at(self.data, offset);
    const format = try s.read(u8);

    // Cycle detected
    if (std.mem.containsAtLeastScalar(usize, recursion_stack.items, 1, offset))
        return error.Overflow;

    recursion_stack.appendBounded(offset) catch return error.ParseFail;
    defer _ = recursion_stack.pop();

    return try self.parse_paint_impl(
        offset,
        palette,
        painter,
        recursion_stack,
        &s,
        format,
        coords,
        foreground_color,
    );
}

fn parse_paint_impl(
    self: *const Table,
    offset: usize,
    palette: u16,
    painter: Painter,
    recursion_stack: *std.ArrayList(usize),
    s: *parser.Stream,
    format: u8,
    coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
    foreground_color: lib.RgbaColor,
) parser.Error!void {
    switch (format) {
        1 => { // PaintColrLayers
            const layers_count = try s.read(u8);
            const first_layer_index = try s.read(u32);

            for (0..layers_count) |i| {
                const index = try std.math.add(u32, first_layer_index, @truncate(i));
                const paint_offset = self.layer_paint_offsets.get(index) orelse
                    return error.ParseFail;

                const new_offset = self.layer_paint_offsets_offset[0] + paint_offset[0];
                try self.parse_paint(
                    new_offset,
                    palette,
                    painter,
                    recursion_stack,
                    coords,
                    foreground_color,
                );
            }
        },
        2 => { // PaintSolid
            const palette_index = try s.read(u16);
            const alpha = try s.read(parser.F2DOT14);

            const color = if (palette_index == std.math.maxInt(u16))
                foreground_color
            else
                self.palettes.get(palette, palette_index) orelse return error.ParseFail;

            painter.paint(.{ .solid = color.apply_alpha(alpha.to_f32()) });
        },
        3 => if (cfg.variable_fonts) { // PaintVarSolid
            const palette_index = try s.read(u16);
            const alpha = try s.read(parser.F2DOT14);
            const var_index_base = try s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(1, var_index_base, coords);

            const color = if (palette_index == std.math.maxInt(u16))
                foreground_color
            else
                self.palettes.get(palette, palette_index) orelse return error.ParseFail;

            const alpha_color = color.apply_alpha(alpha.apply_float_delta(deltas[0]));
            painter.paint(.{ .solid = alpha_color });
        },
        4 => { // PaintLinearGradient
            const color_line_offset = try s.read(parser.Offset24);
            const color_line = try self.parse_color_line(
                offset + color_line_offset[0],
                foreground_color,
            );

            painter.paint(.{ .linear_gradient = .{
                .x0 = @floatFromInt(try s.read(i16)),
                .y0 = @floatFromInt(try s.read(i16)),
                .x1 = @floatFromInt(try s.read(i16)),
                .y1 = @floatFromInt(try s.read(i16)),
                .x2 = @floatFromInt(try s.read(i16)),
                .y2 = @floatFromInt(try s.read(i16)),
                .extend = color_line.extend,
                .variation_data = if (cfg.variable_fonts) self.variation_data(),
                .color_line = .{ .non_var_color_line = color_line },
            } });
        },
        5 => if (cfg.variable_fonts) { // PaintVarLinearGradient
            const var_color_line_offset = try s.read(parser.Offset24);
            const color_line = try self.parse_var_color_line(
                offset + var_color_line_offset[0],
                foreground_color,
            );
            var var_s = s.*;
            var_s.advance(12);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(6, var_index_base, coords);

            painter.paint(.{ .linear_gradient = .{
                .x0 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[0],
                .y0 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[1],
                .x1 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[2],
                .y1 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[3],
                .x2 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[4],
                .y2 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[5],
                .extend = color_line.extend,
                .variation_data = self.variation_data(),
                .color_line = .{ .var_color_line = color_line },
            } });
        },
        6 => { // PaintRadialGradient
            const color_line_offset = try s.read(parser.Offset24);
            const color_line = try self.parse_color_line(
                offset + color_line_offset[0],
                foreground_color,
            );

            painter.paint(.{ .radial_gradient = .{
                .x0 = @floatFromInt(try s.read(i16)),
                .y0 = @floatFromInt(try s.read(i16)),
                .r0 = @floatFromInt(try s.read(u16)),
                .x1 = @floatFromInt(try s.read(i16)),
                .y1 = @floatFromInt(try s.read(i16)),
                .r1 = @floatFromInt(try s.read(u16)),
                .extend = color_line.extend,
                .variation_data = if (cfg.variable_fonts) self.variation_data(),
                .color_line = .{ .non_var_color_line = color_line },
            } });
        },
        7 => if (cfg.variable_fonts) { // PaintVarRadialGradient
            const color_line_offset = try s.read(parser.Offset24);
            const color_line = try self.parse_var_color_line(
                offset + color_line_offset[0],
                foreground_color,
            );

            var var_s = s.*;
            var_s.advance(12);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(6, var_index_base, coords);

            painter.paint(.{ .radial_gradient = .{
                .x0 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[0],
                .y0 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[1],
                .r0 = @as(f32, @floatFromInt(try s.read(u16))) + deltas[2],
                .x1 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[3],
                .y1 = @as(f32, @floatFromInt(try s.read(i16))) + deltas[4],
                .r1 = @as(f32, @floatFromInt(try s.read(u16))) + deltas[5],
                .extend = color_line.extend,
                .variation_data = self.variation_data(),
                .color_line = .{ .var_color_line = color_line },
            } });
        },
        8 => { // PaintSweepGradient
            const color_line_offset = try s.read(parser.Offset24);
            const color_line = try self.parse_color_line(
                offset + color_line_offset[0],
                foreground_color,
            );
            painter.paint(.{ .sweep_gradient = .{
                .center_x = @floatFromInt(try s.read(i16)),
                .center_y = @floatFromInt(try s.read(i16)),
                .start_angle = (try s.read(parser.F2DOT14)).to_f32(),
                .end_angle = (try s.read(parser.F2DOT14)).to_f32(),
                .extend = color_line.extend,
                .color_line = .{ .non_var_color_line = color_line },
                .variation_data = if (cfg.variable_fonts) self.variation_data(),
            } });
        },
        9 => if (cfg.variable_fonts) { // PaintVarSweepGradient

            const color_line_offset = try s.read(parser.Offset24);
            const color_line = try self.parse_var_color_line(
                offset + color_line_offset[0],
                foreground_color,
            );

            var var_s = s.*;
            var_s.advance(8);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(4, var_index_base, coords);

            painter.paint(.{ .sweep_gradient = .{
                .center_x = @as(f32, @floatFromInt(try s.read(i16))) + deltas[0],
                .center_y = @as(f32, @floatFromInt(try s.read(i16))) + deltas[1],
                .start_angle = (try s
                    .read(parser.F2DOT14))
                    .apply_float_delta(deltas[2]),
                .end_angle = (try s
                    .read(parser.F2DOT14))
                    .apply_float_delta(deltas[3]),
                .extend = color_line.extend,
                .color_line = .{ .var_color_line = color_line },
                .variation_data = self.variation_data(),
            } });
        },
        10 => { // PaintGlyph
            const paint_offset = try s.read(parser.Offset24);
            const glyph_id = try s.read(lib.GlyphId);
            painter.outline_glyph(glyph_id);
            painter.push_clip();
            defer painter.pop_clip();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        11 => { // PaintColrGlyph
            const glyph_id = try s.read(lib.GlyphId);
            self.paint_impl(
                glyph_id,
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            ) catch return error.ParseFail;
        },
        12 => { // PaintTransform
            const paint_offset = try s.read(parser.Offset24);
            const ts_offset = try s.read(parser.Offset24);
            var s_12 = try parser.Stream.new_at(self.data, offset + ts_offset[0]);

            painter.push_transform(.{
                .a = (try s_12.read(parser.Fixed)).value,
                .b = (try s_12.read(parser.Fixed)).value,
                .c = (try s_12.read(parser.Fixed)).value,
                .d = (try s_12.read(parser.Fixed)).value,
                .e = (try s_12.read(parser.Fixed)).value,
                .f = (try s_12.read(parser.Fixed)).value,
            });
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        13 => if (cfg.variable_fonts) { // PaintVarTransform
            const paint_offset = try s.read(parser.Offset24);
            const ts_offset = try s.read(parser.Offset24);
            var s_13 = try parser.Stream.new_at(self.data, offset + ts_offset[0]);

            var var_s = s_13;
            var_s.advance(24);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(6, var_index_base, coords);

            painter.push_transform(.{
                .a = (try s_13.read(parser.Fixed)).apply_float_delta(deltas[0]),
                .b = (try s_13.read(parser.Fixed)).apply_float_delta(deltas[1]),
                .c = (try s_13.read(parser.Fixed)).apply_float_delta(deltas[2]),
                .d = (try s_13.read(parser.Fixed)).apply_float_delta(deltas[3]),
                .e = (try s_13.read(parser.Fixed)).apply_float_delta(deltas[4]),
                .f = (try s_13.read(parser.Fixed)).apply_float_delta(deltas[5]),
            });
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        14 => { // PaintTranslate
            const paint_offset = try s.read(parser.Offset24);
            const tx: f32 = @floatFromInt(try s.read(i16));
            const ty: f32 = @floatFromInt(try s.read(i16));

            painter.push_transform(.new_translate(tx, ty));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        15 => if (cfg.variable_fonts) { // PaintVarTranslate
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(4);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(2, var_index_base, coords);

            const tx = @as(f32, @floatFromInt(try s.read(i16))) + deltas[0];
            const ty = @as(f32, @floatFromInt(try s.read(i16))) + deltas[1];

            painter.push_transform(.new_translate(tx, ty));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        16 => { // PaintScale
            const paint_offset = try s.read(parser.Offset24);
            const sx = (try s.read(parser.F2DOT14)).to_f32();
            const sy = (try s.read(parser.F2DOT14)).to_f32();

            painter.push_transform(.new_scale(sx, sy));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        17 => if (cfg.variable_fonts) { // PaintVarScale
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(4);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(2, var_index_base, coords);

            const sx = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);
            const sy = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[1]);

            painter.push_transform(.new_scale(sx, sy));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        18 => { // PaintScaleAroundCenter
            const paint_offset = try s.read(parser.Offset24);
            const sx = (try s.read(parser.F2DOT14)).to_f32();
            const sy = (try s.read(parser.F2DOT14)).to_f32();
            const center_x: f32 = @floatFromInt(try s.read(i16));
            const center_y: f32 = @floatFromInt(try s.read(i16));

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_scale(sx, sy));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        19 => if (cfg.variable_fonts) { // PaintVarScaleAroundCenter
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(8);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(4, var_index_base, coords);

            const sx = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);
            const sy = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[1]);
            const center_x = @as(f32, @floatFromInt(try s.read(i16))) + deltas[2];
            const center_y = @as(f32, @floatFromInt(try s.read(i16))) + deltas[3];

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_scale(sx, sy));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        20 => { // PaintScaleUniform
            const paint_offset = try s.read(parser.Offset24);
            const scale = (try s.read(parser.F2DOT14)).to_f32();

            painter.push_transform(.new_scale(scale, scale));
            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
            painter.pop_transform();
        },
        21 => if (cfg.variable_fonts) { // PaintVarScaleUniform
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(2);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(1, var_index_base, coords);

            const scale = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);

            painter.push_transform(.new_scale(scale, scale));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        22 => { // PaintScaleUniformAroundCenter
            const paint_offset = try s.read(parser.Offset24);
            const scale = (try s.read(parser.F2DOT14)).to_f32();
            const center_x: f32 = @floatFromInt(try s.read(i16));
            const center_y: f32 = @floatFromInt(try s.read(i16));

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_scale(scale, scale));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        23 => if (cfg.variable_fonts) { // PaintVarScaleUniformAroundCenter
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(6);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(3, var_index_base, coords);

            const scale = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);
            const center_x = @as(f32, @floatFromInt(try s.read(i16))) + deltas[1];
            const center_y = @as(f32, @floatFromInt(try s.read(i16))) + deltas[2];

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_scale(scale, scale));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        24 => { // PaintRotate
            const paint_offset = try s.read(parser.Offset24);
            const angle = (try s.read(parser.F2DOT14)).to_f32();

            painter.push_transform(.new_rotate(angle));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        25 => if (cfg.variable_fonts) { // PaintVarRotate
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(2);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(1, var_index_base, coords);

            const angle = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);

            painter.push_transform(.new_rotate(angle));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        26 => { // PaintRotateAroundCenter
            const paint_offset = try s.read(parser.Offset24);
            const angle = (try s.read(parser.F2DOT14)).to_f32();
            const center_x: f32 = @floatFromInt(try s.read(i16));
            const center_y: f32 = @floatFromInt(try s.read(i16));

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_rotate(angle));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        27 => if (cfg.variable_fonts) { // PaintVarRotateAroundCenter
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(6);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(3, var_index_base, coords);

            const angle = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);
            const center_x = @as(f32, @floatFromInt(try s.read(i16))) + deltas[1];
            const center_y = @as(f32, @floatFromInt(try s.read(i16))) + deltas[2];

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_rotate(angle));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        28 => { // PaintSkew
            const paint_offset = try s.read(parser.Offset24);
            const skew_x = (try s.read(parser.F2DOT14)).to_f32();
            const skew_y = (try s.read(parser.F2DOT14)).to_f32();

            painter.push_transform(.new_skew(skew_x, skew_y));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        29 => if (cfg.variable_fonts) { // PaintVarSkew
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(4);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(2, var_index_base, coords);

            const skew_x = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);
            const skew_y = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[1]);

            painter.push_transform(.new_skew(skew_x, skew_y));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        30 => { // PaintSkewAroundCenter
            const paint_offset = try s.read(parser.Offset24);
            const skew_x = (try s.read(parser.F2DOT14)).to_f32();
            const skew_y = (try s.read(parser.F2DOT14)).to_f32();
            const center_x: f32 = @floatFromInt(try s.read(i16));
            const center_y: f32 = @floatFromInt(try s.read(i16));

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_skew(skew_x, skew_y));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        31 => if (cfg.variable_fonts) { // PaintVarSkewAroundCenter
            const paint_offset = try s.read(parser.Offset24);

            var var_s = s.*;
            var_s.advance(8);
            const var_index_base = try var_s.read(u32);

            const deltas = self
                .variation_data()
                .read_deltas(4, var_index_base, coords);

            const skew_x = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[0]);
            const skew_y = (try s.read(parser.F2DOT14)).apply_float_delta(deltas[1]);
            const center_x = @as(f32, @floatFromInt(try s.read(i16))) + deltas[2];
            const center_y = @as(f32, @floatFromInt(try s.read(i16))) + deltas[3];

            painter.push_transform(.new_translate(
                center_x,
                center_y,
            ));
            defer painter.pop_transform();

            painter.push_transform(.new_skew(skew_x, skew_y));
            defer painter.pop_transform();

            painter.push_transform(.new_translate(
                -center_x,
                -center_y,
            ));
            defer painter.pop_transform();

            try self.parse_paint(
                offset + paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        32 => { // PaintComposite
            const source_paint_offset = try s.read(parser.Offset24);
            const composite_mode = try s.read(CompositeMode);
            const backdrop_paint_offset = try s.read(parser.Offset24);

            painter.push_layer(.source_over);
            defer painter.pop_layer();

            try self.parse_paint(
                offset + backdrop_paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
            painter.push_layer(composite_mode);
            defer painter.pop_layer();

            try self.parse_paint(
                offset + source_paint_offset[0],
                palette,
                painter,
                recursion_stack,
                coords,
                foreground_color,
            );
        },
        else => {},
    }
}

fn parse_color_line(
    self: *const Table,
    offset: usize,
    foreground_color: lib.RgbaColor,
) parser.Error!NonVarColorLine {
    var s = try parser.Stream.new_at(self.data, offset);
    const extend = try s.read(GradientExtend);
    const count = try s.read(u16);
    const colors = try s.read_array(ColorStopRaw, count);
    return .{
        .extend = extend,
        .colors = colors,
        .foreground_color = foreground_color,
        .palettes = self.palettes,
    };
}

fn parse_var_color_line(
    self: *const Table,
    offset: usize,
    foreground_color: lib.RgbaColor,
) parser.Error!VarColorLine {
    var s = try parser.Stream.new_at(self.data, offset);
    const extend = try s.read(GradientExtend);
    const count = try s.read(u16);
    const colors = try s.read_array(VarColorStopRaw, count);
    return .{
        .extend = extend,
        .colors = colors,
        .foreground_color = foreground_color,
        .palettes = self.palettes,
    };
}

/// A [base glyph](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyph-and-layer-records).
const BaseGlyphRecord = struct {
    glyph_id: lib.GlyphId,
    first_layer_index: u16,
    num_layers: u16,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 6;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };

    fn compare(lhs: BaseGlyphRecord, rhs: lib.GlyphId) std.math.Order {
        return std.math.order(lhs.glyph_id[0], rhs[0]);
    }
};

/// A [layer](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyph-and-layer-records).
const LayerRecord = struct {
    glyph_id: lib.GlyphId,
    palette_index: u16,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 4;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// A [BaseGlyphPaintRecord](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyphlist-layerlist-and-cliplist).
const BaseGlyphPaintRecord = struct {
    glyph_id: lib.GlyphId,
    paint_table_offset: parser.Offset32,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 6;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };

    fn compare(lhs: BaseGlyphPaintRecord, rhs: lib.GlyphId) std.math.Order {
        return std.math.order(lhs.glyph_id[0], rhs[0]);
    }
};

/// A [clip list](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyphlist-layerlist-and-cliplist).
const ClipList = struct {
    data: []const u8 = &.{},
    records: parser.LazyArray32(ClipRecord) = .{},

    pub fn get(
        self: ClipList,
        index: u32,
        var_data: if (cfg.variable_fonts) *const VariationData else void,
        coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
    ) ?ClipBox {
        const record = self.records.get(index) orelse return null;
        const data = utils.slice(self.data, record.clip_box_offset[0]) catch return null;

        var s = parser.Stream.new(data);
        const format = s.read(u8) catch return null;

        const deltas: [4]f32 = if (cfg.variable_fonts and format == 2) d: {
            const og_offset = s.offset;
            defer s.offset = og_offset;

            s.advance(8);
            const var_index_base = s.read(u32) catch return null;
            break :d var_data.read_deltas(4, var_index_base, coords);
        } else @splat(0.0);

        return .{
            .x_min = @as(f32, @floatFromInt(s.read(i16) catch return null)) + deltas[0],
            .y_min = @as(f32, @floatFromInt(s.read(i16) catch return null)) + deltas[1],
            .x_max = @as(f32, @floatFromInt(s.read(i16) catch return null)) + deltas[2],
            .y_max = @as(f32, @floatFromInt(s.read(i16) catch return null)) + deltas[3],
        };
    }

    /// Returns a ClipBox by glyph ID.
    pub fn find(
        self: ClipList,
        glyph_id: lib.GlyphId,
        var_data: if (cfg.variable_fonts) *const VariationData else void,
        coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,
    ) ?ClipBox {
        var iter = self.records.iterator();
        var i: u32 = 0;
        const index = while (iter.next()) |v| : (i += 1) {
            // self.start_glyph_id..=self.end_glyph_id
            if (glyph_id[0] >= v.start_glyph_id[0] and
                glyph_id[0] <= v.end_glyph_id[0]) break i;
        } else return null;

        return self.get(
            index,
            var_data,
            coords,
        );
    }
};

/// A [clip record](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyphlist-layerlist-and-cliplist).
const ClipRecord = struct {
    /// The first glyph ID for the range covered by this record.
    start_glyph_id: lib.GlyphId,
    /// The last glyph ID, *inclusive*, for the range covered by this record.
    end_glyph_id: lib.GlyphId,
    /// The offset to the clip box.
    clip_box_offset: parser.Offset24,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 7;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// A trait for color glyph painting.
///
/// See [COLR](https://learn.microsoft.com/en-us/typography/opentype/spec/colr) for details.
pub const Painter = struct {
    ptr: *anyopaque,
    vtable: VTable,

    pub const VTable = struct {
        /// Outline a glyph and store it.
        outline_glyph: *const fn (*anyopaque, glyph_id: lib.GlyphId) void,
        /// Paint the stored outline using the provided color.
        paint: *const fn (*anyopaque, paint_: Paint) void,
        /// Push a new clip path using the currently stored outline.
        push_clip: *const fn (*anyopaque) void,
        /// Push a new clip path using the clip box.
        push_clip_box: *const fn (*anyopaque, clipbox: ClipBox) void,
        /// Pop the last clip path.
        pop_clip: *const fn (*anyopaque) void,
        /// Push a new layer with the given composite mode.
        push_layer: *const fn (*anyopaque, mode: CompositeMode) void,
        /// Pop the last layer.
        pop_layer: *const fn (*anyopaque) void,
        /// Push a transform.
        push_transform: *const fn (*anyopaque, transform: lib.Transform) void,
        /// Pop the last transform.
        pop_transform: *const fn (*anyopaque) void,
    };

    pub fn outline_glyph(self: Painter, glyph_id: lib.GlyphId) void {
        self.vtable.outline_glyph(self.ptr, glyph_id);
    }
    pub fn paint(self: Painter, paint_: Paint) void {
        self.vtable.paint(self.ptr, paint_);
    }
    pub fn push_clip(self: Painter) void {
        self.vtable.push_clip(self.ptr);
    }
    pub fn push_clip_box(self: Painter, clipbox: ClipBox) void {
        self.vtable.push_clip_box(self.ptr, clipbox);
    }
    pub fn pop_clip(self: Painter) void {
        self.vtable.pop_clip(self.ptr);
    }
    pub fn push_layer(self: Painter, mode: CompositeMode) void {
        self.vtable.push_layer(self.ptr, mode);
    }
    pub fn pop_layer(self: Painter) void {
        self.vtable.pop_layer(self.ptr);
    }
    pub fn push_transform(self: Painter, transform: lib.Transform) void {
        self.vtable.push_transform(self.ptr, transform);
    }
    pub fn pop_transform(self: Painter) void {
        self.vtable.pop_transform(self.ptr);
    }
};

/// A paint.
pub const Paint = union(enum) {
    /// A paint with a solid color.
    solid: lib.RgbaColor,
    /// A paint with a linear gradient.
    linear_gradient: LinearGradient,
    /// A paint with a radial gradient.
    radial_gradient: RadialGradient,
    /// A paint with a sweep gradient.
    sweep_gradient: SweepGradient,
};

/// A [linear gradient](https://learn.microsoft.com/en-us/typography/opentype/spec/colr#formats-4-and-5-paintlineargradient-paintvarlineargradient)
pub const LinearGradient = struct {
    /// The `x0` value.
    x0: f32,
    /// The `y0` value.
    y0: f32,
    /// The `x1` value.
    x1: f32,
    /// The `y1` value.
    y1: f32,
    /// The `x2` value.
    x2: f32,
    /// The `y2` value.
    y2: f32,
    /// The extend.
    extend: GradientExtend,
    variation_data: if (cfg.variable_fonts) VariationData else void,
    color_line: ColorLine,

    /// Returns an iterator over the stops of the linear gradient. Stops need to
    /// be sorted by the caller, or use `collect`.
    pub fn stops(
        self: LinearGradient,
        palette: u16,
        coords: if (cfg.variable_fonts) []lib.NormalizedCoordinate else void,
    ) GradientStopsIter {
        return .{
            .color_line = self.color_line,
            .palette = palette,
            .index = 0,
            .variation_data = self.variation_data,
            .coords = coords,
        };
    }
};

/// A [radial gradient](https://learn.microsoft.com/en-us/typography/opentype/spec/colr#formats-6-and-7-paintradialgradient-paintvarradialgradient)
pub const RadialGradient = struct {
    /// The `x0` value.
    x0: f32,
    /// The `y0` value.
    y0: f32,
    /// The `r0` value.
    r0: f32,
    /// The `r1` value.
    r1: f32,
    /// The `x1` value.
    x1: f32,
    /// The `y1` value.
    y1: f32,
    /// The extend.
    extend: GradientExtend,
    variation_data: if (cfg.variable_fonts) VariationData else void,
    color_line: ColorLine,

    /// Returns an iterator over the stops of the radial gradient. Stops need to
    /// be sorted by the caller, or use `collect`.
    pub fn stops(
        self: RadialGradient,
        palette: u16,
        coords: if (cfg.variable_fonts) []lib.NormalizedCoordinate else void,
    ) GradientStopsIter {
        return .{
            .color_line = self.color_line,
            .palette = palette,
            .index = 0,
            .variation_data = self.variation_data,
            .coords = coords,
        };
    }
};

/// A [sweep gradient](https://learn.microsoft.com/en-us/typography/opentype/spec/colr#formats-8-and-9-paintsweepgradient-paintvarsweepgradient)
pub const SweepGradient = struct {
    /// The x of the center.
    center_x: f32,
    /// The y of the center.
    center_y: f32,
    /// The start angle.
    start_angle: f32,
    /// The end angle.
    end_angle: f32,
    /// The extend.
    extend: GradientExtend,
    variation_data: if (cfg.variable_fonts) VariationData else void,
    color_line: ColorLine,

    /// Returns an iterator over the stops of the radial gradient. Stops need to
    /// be sorted by the caller, or use `collect`.
    pub fn stops(
        self: SweepGradient,
        palette: u16,
        coords: if (cfg.variable_fonts) []lib.NormalizedCoordinate else void,
    ) GradientStopsIter {
        return .{
            .color_line = self.color_line,
            .palette = palette,
            .index = 0,
            .variation_data = self.variation_data,
            .coords = coords,
        };
    }
};

/// A [gradient extend](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyphlist-layerlist-and-cliplist).
pub const GradientExtend = enum {
    /// The `Pad` gradient extend mode.
    pad,
    /// The `Repeat` gradient extend mode.
    repeat,
    /// The `Reflect` gradient extend mode.
    reflect,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 1;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return switch (data[0]) {
                0 => .pad,
                1 => .repeat,
                2 => .reflect,
                else => error.ParseFail,
            };
        }
    };
};

const VariationData = struct {
    variation_store: ?ItemVariationStore,
    delta_map: ?DeltaSetIndexMap,

    // Inspired from `fontations`.
    fn read_deltas(
        self: VariationData,
        comptime N: usize,
        var_index_base: u32,
        coordinates: []const lib.NormalizedCoordinate,
    ) [N]f32 {
        const NO_VARIATION_DELTAS: u32 = 0xFFFFFFFF;
        var deltas: [N]f32 = @splat(0.0);

        if (coordinates.len == 0 or
            self.variation_store == null or
            var_index_base == NO_VARIATION_DELTAS) return deltas;

        const vs = self.variation_store orelse unreachable;

        for (&deltas, 0..) |*delta, i| {
            const delta_map = self.delta_map orelse continue;
            const douter, const dinner =
                delta_map.map(var_index_base + @as(u32, @truncate(i))) orelse continue;
            delta.* = vs.parse_delta(douter, dinner, coordinates) catch continue;
        }

        return deltas;
    }
};

// [ARS] very dubious
const ColorLine = union(enum) {
    var_color_line: if (cfg.variable_fonts) VarColorLine else noreturn,
    non_var_color_line: NonVarColorLine,
};

const VarColorLine = struct {
    extend: GradientExtend,
    colors: parser.LazyArray16(VarColorStopRaw),
    palettes: cpalTable,
    foreground_color: lib.RgbaColor,

    fn get(
        self: VarColorLine,
        palette: u16,
        index: u16,
        var_data: VariationData,
        coordinates: []const lib.NormalizedCoordinate,
    ) ?ColorStop {
        const info = self.colors.get(index) orelse return null;

        var color = if (info.palette_index == std.math.maxInt(u16))
            self.foreground_color
        else
            self.palettes.get(palette, info.palette_index) orelse return null;

        const deltas = var_data.read_deltas(2, info.var_index_base, coordinates);
        const stop_offset = info.stop_offset.apply_float_delta(deltas[0]);
        color = color.apply_alpha(info.alpha.apply_float_delta(deltas[1]));

        return .{ .stop_offset = stop_offset, .color = color };
    }
};

/// A [var color stop](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#color-references-colorstop-and-colorline).
const VarColorStopRaw = struct {
    stop_offset: parser.F2DOT14,
    palette_index: u16,
    alpha: parser.F2DOT14,
    var_index_base: u32,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 10;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

const NonVarColorLine = struct {
    extend: GradientExtend,
    colors: parser.LazyArray16(ColorStopRaw),
    palettes: cpalTable,
    foreground_color: lib.RgbaColor,

    fn get(
        self: NonVarColorLine,
        palette: u16,
        index: u16,
    ) ?ColorStop {
        const info = self.colors.get(index) orelse return null;

        var color = if (info.palette_index == std.math.maxInt(u16))
            self.foreground_color
        else
            self.palettes.get(palette, info.palette_index) orelse return null;

        color = color.apply_alpha(info.alpha.to_f32());
        return .{ .stop_offset = info.stop_offset.to_f32(), .color = color };
    }
};

/// A [color stop](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#color-references-colorstop-and-colorline).
const ColorStopRaw = struct {
    stop_offset: parser.F2DOT14,
    palette_index: u16,
    alpha: parser.F2DOT14,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 6;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// A [gradient extend](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyphlist-layerlist-and-cliplist).
pub const ColorStop = struct {
    /// The offset of the color stop.
    stop_offset: f32,
    /// The color of the color stop.
    color: lib.RgbaColor,
};

/// An iterator over stops of a gradient.
pub const GradientStopsIter = struct {
    color_line: ColorLine,
    palette: u16,
    index: u16,
    variation_data: if (cfg.variable_fonts) VariationData else void,
    coords: if (cfg.variable_fonts) []const lib.NormalizedCoordinate else void,

    pub fn next(
        self: *GradientStopsIter,
    ) ?ColorStop {
        const len = switch (self.color_line) {
            inline else => |cl| cl.colors.len(),
        };
        if (self.index == len) return null;

        defer self.index +|= 1;
        return switch (self.color_line) {
            .var_color_line => |vcl| vcl.get(self.palette, self.index, self.variation_data, self.coords),
            .non_var_color_line => |nvcl| nvcl.get(self.palette, self.index),
        };
    }

    /// collects and sorts ColorStops
    pub fn collect(
        iter: *GradientStopsIter,
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error![]ColorStop {
        const len = switch (iter.color_line) {
            inline else => |cl| cl.colors.len(),
        };
        var stops: std.ArrayList(ColorStop) = try .initCapacity(gpa, len);
        defer stops.deinit(gpa);

        while (iter.next()) |stop| stops.appendAssumeCapacity(stop);

        const less_than = struct {
            fn less_than(_: void, lhs: ColorStop, rhs: ColorStop) bool {
                return lhs.stop_offset < rhs.stop_offset;
            }
        }.less_than;

        std.mem.sortUnstable(ColorStop, stops.items, {}, less_than);
        return try stops.toOwnedSlice(gpa);
    }
};

/// A [ClipBox](https://learn.microsoft.com/en-us/typography/opentype/spec/colr#baseglyphlist-layerlist-and-cliplist).
pub const ClipBox = lib.RectF;

/// A [composite mode](https://learn.microsoft.com/en-us/typography/opentype/spec/colr#format-32-paintcomposite)
pub const CompositeMode = enum {
    /// The composite mode 'Clear'.
    clear,
    /// The composite mode 'Source'.
    source,
    /// The composite mode 'Destination'.
    destination,
    /// The composite mode 'SourceOver'.
    source_over,
    /// The composite mode 'DestinationOver'.
    destination_over,
    /// The composite mode 'SourceIn'.
    source_in,
    /// The composite mode 'DestinationIn'.
    destination_in,
    /// The composite mode 'SourceOut'.
    source_out,
    /// The composite mode 'DestinationOut'.
    destination_out,
    /// The composite mode 'SourceAtop'.
    source_atop,
    /// The composite mode 'DestinationAtop'.
    sestination_atop,
    /// The composite mode 'Xor'.
    xor,
    /// The composite mode 'Plus'.
    plus,
    /// The composite mode 'Screen'.
    screen,
    /// The composite mode 'Overlay'.
    overlay,
    /// The composite mode 'Darken'.
    sarken,
    /// The composite mode 'Lighten'.
    lighten,
    /// The composite mode 'ColorDodge'.
    color_dodge,
    /// The composite mode 'ColorBurn'.
    color_burn,
    /// The composite mode 'HardLight'.
    hard_light,
    /// The composite mode 'SoftLight'.
    soft_light,
    /// The composite mode 'Difference'.
    difference,
    /// The composite mode 'Exclusion'.
    exclusion,
    /// The composite mode 'Multiply'.
    multiply,
    /// The composite mode 'Hue'.
    hue,
    /// The composite mode 'Saturation'.
    saturation,
    /// The composite mode 'Color'.
    color,
    /// The composite mode 'Luminosity'.
    luminosity,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 1;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return switch (data[0]) {
                0 => .clear,
                1 => .source,
                2 => .destination,
                3 => .source_over,
                4 => .destination_over,
                5 => .source_in,
                6 => .destination_in,
                7 => .source_out,
                8 => .destination_out,
                9 => .source_atop,
                10 => .sestination_atop,
                11 => .xor,
                12 => .plus,
                13 => .screen,
                14 => .overlay,
                15 => .sarken,
                16 => .lighten,
                17 => .color_dodge,
                18 => .color_burn,
                19 => .hard_light,
                20 => .soft_light,
                21 => .difference,
                22 => .exclusion,
                23 => .multiply,
                24 => .hue,
                25 => .saturation,
                26 => .color,
                27 => .luminosity,
                else => error.ParseFail,
            };
        }
    };
};

pub const Error = error{PaintError};
