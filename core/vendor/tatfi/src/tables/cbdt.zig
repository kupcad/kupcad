//! A [Color Bitmap Data Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/cbdt) implementation.
//!
//! EBDT and bdat also share the same structure, so this is re-used for them.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const cblcTable = @import("cblc.zig");

const Table = @This();

locations: cblcTable,
data: []const u8,

/// Parses a table from raw data.
pub fn parse(
    locations: cblcTable,
    data: []const u8,
) Table {
    return .{
        .data = data,
        .locations = locations,
    };
}

/// Returns a raster image for the glyph.
pub fn get(
    self: *const Table,
    glyph_id: lib.GlyphId,
    pixels_per_em: u16,
) ?lib.RasterGlyphImage {
    return self.get_inner(glyph_id, pixels_per_em) catch null;
}

fn get_inner(
    self: *const Table,
    glyph_id: lib.GlyphId,
    pixels_per_em: u16,
) parser.Error!lib.RasterGlyphImage {
    const location = self.locations.get(glyph_id, pixels_per_em) orelse return error.ParseFail;
    var s = try parser.Stream.new_at(self.data, location.offset);
    const metrics: cblcTable.Location.Metrics = switch (location.format.metrics) {
        .small => s: {
            const height = try s.read(u8);
            const width = try s.read(u8);
            const bearing_x = try s.read(i8);
            const bearing_y = try s.read(i8);
            s.skip(u8); // advance
            break :s .{
                .x = bearing_x,
                .y = bearing_y,
                .width = width,
                .height = height,
            };
        },
        .big => b: {
            const height = try s.read(u8);
            const width = try s.read(u8);
            const hor_bearing_x = try s.read(i8);
            const hor_bearing_y = try s.read(i8);
            s.skip(u8); // hor_advance
            s.skip(i8); // ver_bearing_x
            s.skip(i8); // ver_bearing_y
            s.skip(u8); // ver_advance
            break :b .{
                .x = hor_bearing_x,
                .y = hor_bearing_y,
                .width = width,
                .height = height,
            };
        },
        .shared => location.metrics,
    };

    switch (location.format.data) {
        .byte_aligned => |bit_depth| {
            const row_len = std.math.divCeil(
                u32,
                (@as(u32, metrics.width) * @as(u32, bit_depth)),
                8,
            ) catch return error.ParseFail;
            const data_len = row_len * @as(u32, metrics.height);
            const data = try s.read_bytes(data_len);
            return .{
                .x = @as(i16, metrics.x),
                // `y` in CBDT is a bottom bound, not top one.
                .y = @as(i16, metrics.y) - @as(i16, metrics.height),
                .width = metrics.width,
                .height = metrics.height,
                .pixels_per_em = location.ppem,
                .format = switch (bit_depth) {
                    1 => .bitmap_mono,
                    2 => .bitmap_gray_2,
                    4 => .bitmap_gray_4,
                    8 => .bitmap_gray_8,
                    32 => .bitmap_premul_bgra_32,
                    else => return error.ParseFail,
                },
                .data = data,
            };
        },
        .bit_aligned => |bit_depth| {
            const data_len = len: {
                const w: usize = metrics.width;
                const h: usize = metrics.height;
                const d: usize = bit_depth;
                break :len std.math.divCeil(usize, w * h * d, 8) catch return error.ParseFail;
            };
            const data = try s.read_bytes(data_len);
            return .{
                .x = @as(i16, metrics.x),
                // `y` in CBDT is a bottom bound, not top one.
                .y = @as(i16, metrics.y) - @as(i16, metrics.height),
                .width = metrics.width,
                .height = metrics.height,
                .pixels_per_em = location.ppem,
                .format = switch (bit_depth) {
                    1 => .bitmap_mono_packed,
                    2 => .bitmap_gray_2_packed,
                    4 => .bitmap_gray_4_packed,
                    8 => .bitmap_gray_8,
                    32 => .bitmap_premul_bgra_32,
                    else => return error.ParseFail,
                },
                .data = data,
            };
        },
        .png => {
            const data_len = try s.read(u32);
            const data = try s.read_bytes(data_len);
            return .{
                .x = metrics.x,
                // `y` in CBDT is a bottom bound, not top one.
                .y = @as(i16, metrics.y) - @as(i16, metrics.height),
                .width = metrics.width,
                .height = metrics.height,
                .pixels_per_em = location.ppem,
                .format = .png,
                .data = data,
            };
        },
    }
}
