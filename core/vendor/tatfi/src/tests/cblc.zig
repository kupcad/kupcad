const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const Unit = @import("main.zig").Unit;
const cblc = ttf.tables.cblc;

/// A CBLC table of one size, whose index subtable array of one subtable, for every glyph, is
/// at 56 and `index_subtable` from 64.
fn one_index_subtable(additional_offset: u32, index_subtable: []const Unit) ![]u8 {
    var units: std.ArrayList(Unit) = .empty;
    defer units.deinit(t.allocator);
    try units.appendSlice(t.allocator, &.{
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
        .{ .unt32 = additional_offset }, // additional offset to the index subtable
    });
    try units.appendSlice(t.allocator, index_subtable);
    return convert(units.items);
}

test "an index subtable past a u32" {
    // [KupCAD] The index subtable array's offset plus its subtable's offset overflowed the
    // u32s they were added in.
    const data = try one_index_subtable(0xFFFFFFFF, &.{});
    defer t.allocator.free(data);

    try t.expectEqual(null, cblc.parse(data).get(.{1}, 16));
}

test "a bitmap past a 32-bit usize" {
    // [KupCAD] The image data's offset plus the glyph's, two u32s, overflowed a 32-bit usize
    // (wasm32).
    const data = try one_index_subtable(8, &.{
        // Index subtable, at 64: format 1
        .{ .unt16 = 1 }, // index format
        .{ .unt16 = 17 }, // image format: small metrics, PNG
        .{ .unt32 = 0xFFFFFF00 }, // image data offset
        .{ .unt32 = 0 }, // glyph 0's offset
        .{ .unt32 = 0x200 }, // glyph 1's offset
    });
    defer t.allocator.free(data);

    // Past the image data, which is empty
    try t.expectEqual(null, ttf.tables.cbdt.parse(cblc.parse(data), &.{}).get(.{1}, 16));
}
