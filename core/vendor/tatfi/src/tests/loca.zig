const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const loca = ttf.tables.loca;

test "65535 glyphs" {
    // [KupCAD] The number of offsets, one more than the glyphs, was counted in the u16 of
    // maxp's number of glyphs: 65535 glyphs, as many as a font can have, overflowed it.
    const table = try loca.Table.parse(std.math.maxInt(u16), .short, &.{ 0, 0, 0, 2 });
    try t.expectEqual(.{ 0, 4 }, table.glyph_range(.{0}));
    try t.expectEqual(null, table.glyph_range(.{1}));
}
