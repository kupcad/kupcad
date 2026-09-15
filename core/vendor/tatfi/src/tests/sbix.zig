const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const Table = ttf.tables.sbix;

test "single_glyph" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // version
        .{ .unt16 = 0 }, // flags
        .{ .unt32 = 1 }, // number of strikes
        .{ .unt32 = 12 }, // strike offset [0]
        // Strike [0]
        .{ .unt16 = 20 }, // pixels_per_em
        .{ .unt16 = 72 }, // ppi
        .{ .unt32 = 12 }, // glyph data offset [0]
        .{ .unt32 = 44 }, // glyph data offset [1]
        // Glyph Data [0]
        .{ .unt16 = 1 }, // x
        .{ .unt16 = 2 }, // y
        .{ .raw = "png " }, // type tag
        // PNG data, just the part we need
        .{ .raw = &.{ 0x89, 0x50, 0x4E, 0x47 } },
        .{ .raw = &.{ 0x0D, 0x0A, 0x1A, 0x0A } },
        .{ .raw = &.{ 0x00, 0x00, 0x00, 0x0D } },
        .{ .raw = &.{ 0x49, 0x48, 0x44, 0x52 } },
        .{ .unt32 = 20 }, // width
        .{ .unt32 = 30 }, // height
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, data);
    try t.expectEqual(1, table.strikes.len());

    const strike = table.strikes.get(0).?;
    try t.expectEqual(20, strike.pixels_per_em);
    try t.expectEqual(72, strike.ppi);
    try t.expectEqual(1, strike.len());

    const glyph_data = strike.get(.{0}).?;
    try t.expectEqual(1, glyph_data.x);
    try t.expectEqual(2, glyph_data.y);
    try t.expectEqual(20, glyph_data.width);
    try t.expectEqual(30, glyph_data.height);
    try t.expectEqual(20, glyph_data.pixels_per_em);
    try t.expectEqual(.png, glyph_data.format);
    try t.expectEqual(24, glyph_data.data.len);
}

test "duplicate_glyph" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // version
        .{ .unt16 = 0 }, // flags
        .{ .unt32 = 1 }, // number of strikes
        .{ .unt32 = 12 }, // strike offset [0]
        // Strike [0]
        .{ .unt16 = 20 }, // pixels_per_em
        .{ .unt16 = 72 }, // ppi
        .{ .unt32 = 16 }, // glyph data offset [0]
        .{ .unt32 = 48 }, // glyph data offset [1]
        .{ .unt32 = 58 }, // glyph data offset [2]
        // Glyph Data [0]
        .{ .unt16 = 1 }, // x
        .{ .unt16 = 2 }, // y
        .{ .raw = "png " }, // type tag
        // PNG data, just the part we need
        .{ .raw = &.{ 0x89, 0x50, 0x4E, 0x47 } },
        .{ .raw = &.{ 0x0D, 0x0A, 0x1A, 0x0A } },
        .{ .raw = &.{ 0x00, 0x00, 0x00, 0x0D } },
        .{ .raw = &.{ 0x49, 0x48, 0x44, 0x52 } },
        .{ .unt32 = 20 }, // width
        .{ .unt32 = 30 }, // height
        // Glyph Data [1]
        .{ .unt16 = 3 }, // x
        .{ .unt16 = 4 }, // y
        .{ .raw = "dupe" }, // type tag
        .{ .unt16 = 0 }, // glyph id
    });
    defer t.allocator.free(data);

    const table = try Table.parse(2, data);
    try t.expectEqual(1, table.strikes.len());

    const strike = table.strikes.get(0).?;
    try t.expectEqual(20, strike.pixels_per_em);
    try t.expectEqual(72, strike.ppi);
    try t.expectEqual(2, strike.len());

    const glyph_data = strike.get(.{1}).?;
    try t.expectEqual(1, glyph_data.x);
    try t.expectEqual(2, glyph_data.y);
    try t.expectEqual(20, glyph_data.width);
    try t.expectEqual(30, glyph_data.height);
    try t.expectEqual(20, glyph_data.pixels_per_em);
    try t.expectEqual(.png, glyph_data.format);
    try t.expectEqual(24, glyph_data.data.len);
}

test "recursive" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // version
        .{ .unt16 = 0 }, // flags
        .{ .unt32 = 1 }, // number of strikes
        .{ .unt32 = 12 }, // strike offset [0]
        // Strike [0]
        .{ .unt16 = 20 }, // pixels_per_em
        .{ .unt16 = 72 }, // ppi
        .{ .unt32 = 16 }, // glyph data offset [0]
        .{ .unt32 = 26 }, // glyph data offset [1]
        .{ .unt32 = 36 }, // glyph data offset [2]
        // Glyph Data [0]
        .{ .unt16 = 1 }, // x
        .{ .unt16 = 2 }, // y
        .{ .raw = "dupe" }, // type tag
        .{ .unt16 = 0 }, // glyph id
        // Glyph Data [1]
        .{ .unt16 = 1 }, // x
        .{ .unt16 = 2 }, // y
        .{ .raw = "dupe" }, // type tag
        .{ .unt16 = 0 }, // glyph id
    });
    defer t.allocator.free(data);

    const table = try Table.parse(2, data);
    const strike = table.strikes.get(0).?;
    try t.expectEqual(null, strike.get(.{0}));
    try t.expectEqual(null, strike.get(.{1}));
}
