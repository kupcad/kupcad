const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const cblc = ttf.tables.cblc;

test "an index subtable past a u32" {
    // [KupCAD] The index subtable array's offset plus its subtable's offset overflowed the
    // u32s they were added in.
    const data = try convert(&.{
        .{ .unt32 = 0x00030000 }, // version
        .{ .unt32 = 1 }, // number of sizes
        // Bitmap size 0
        .{ .unt32 = 56 }, // index subtable array offset
        .{ .unt32 = 0 }, // index tables size
        .{ .unt32 = 1 }, // number of index subtables
        .{ .raw = &@as([28]u8, @splat(0)) }, // color ref, horizontal and vertical metrics
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 0xFFFF }, // last glyph
        .{ .unt8 = 16 }, // ppem x
        .{ .unt8 = 16 }, // ppem y
        .{ .unt8 = 32 }, // bit depth
        .{ .unt8 = 0 }, // flags
        // Index subtable array, at 56
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 0xFFFF }, // last glyph
        .{ .unt32 = 0xFFFFFFFF }, // additional offset to the index subtable
    });
    defer t.allocator.free(data);

    try t.expectEqual(null, cblc.parse(data).get(.{1}, 16));
}
