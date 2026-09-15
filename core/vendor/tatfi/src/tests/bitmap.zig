const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const Unit = @import("main.zig").Unit;
const convert = @import("main.zig").convert;

// NOTE: Bitmap.otb is an incomplete example font that was created specifically for this test.
// It is under the same license as this library, although it is copied from ttf_parser.
const FONT_DATA = @embedFile("fonts/bitmap.otb");

test "bitmap_font" {
    const face = try ttf.Face.parse(FONT_DATA, 0);
    try t.expectEqual(800, face.units_per_em());
    try t.expectEqual(500, face.glyph_hor_advance(t.allocator, face.glyph_index('a').?));
    const W: u8 = 0;
    const B: u8 = 255;
    try t.expectEqualDeep(
        ttf.RasterGlyphImage{
            .x = 0,
            .y = 0,
            .width = 4,
            .height = 4,
            .pixels_per_em = 8,
            .format = .bitmap_gray_8,
            .data = &.{
                W, B, B, B,
                B, W, W, B,
                B, W, W, B,
                W, B, B, B,
            },
        },
        face.glyph_raster_image(face.glyph_index('a').?, 1),
    );
    try t.expectEqualDeep(
        ttf.RasterGlyphImage{
            .x = 0,
            .y = 0,
            .width = 4,
            .height = 6,
            .pixels_per_em = 8,
            .format = .bitmap_gray_8,
            .data = &.{
                W, W, W, B,
                W, W, W, B,
                W, B, B, B,
                B, W, W, B,
                B, W, W, B,
                W, B, B, B,
            },
        },
        face.glyph_raster_image(face.glyph_index('d').?, 1),
    );
    try t.expectEqualDeep(
        ttf.RasterGlyphImage{
            .x = 1,
            .y = 4,
            .width = 3,
            .height = 2,
            .pixels_per_em = 8,
            .format = .bitmap_gray_8,
            .data = &.{
                B, W, B,
                B, W, B,
            },
        },
        face.glyph_raster_image(face.glyph_index('\"').?, 1),
    );
}
