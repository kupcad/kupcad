const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;

const Table = ttf.tables.ankr;
const convert = @import("main.zig").convert;

test "empty" {
    const data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 0 }, // reserved
        .{ .unt32 = 0 }, // offset to lookup table
        .{ .unt32 = 0 }, // offset to glyphs data
    });
    defer t.allocator.free(data);

    _ = Table.parse(1, data) catch {};
}

test "single" {
    const data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 0 }, // reserved
        .{ .unt32 = 12 }, // offset to lookup table
        .{ .unt32 = 12 + 16 }, // offset to glyphs data
        // Lookup Table
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0 }, // glyph
        .{ .unt16 = 0 }, // offset
        // Glyphs Data
        .{ .unt32 = 1 }, // number of points
        // Point [0]
        .{ .int16 = -5 }, // x
        .{ .int16 = 11 }, // y
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, data);
    const points = table.points(.{0}).?;
    try t.expectEqual(Table.Point{ .x = -5, .y = 11 }, points.get(0).?);
}

test "two_points" {
    const data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 0 }, // reserved
        .{ .unt32 = 12 }, // offset to lookup table
        .{ .unt32 = 12 + 16 }, // offset to glyphs data
        // Lookup Table
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0 }, // glyph
        .{ .unt16 = 0 }, // offset
        // Glyphs Data
        // Glyph Data [0]
        .{ .unt32 = 2 }, // number of points
        // Point [0]
        .{ .int16 = -5 }, // x
        .{ .int16 = 11 }, // y
        // Point [1]
        .{ .int16 = 10 }, // x
        .{ .int16 = -40 }, // y
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, data);
    const points = table.points(.{0}).?;
    try t.expectEqual(Table.Point{ .x = -5, .y = 11 }, points.get(0).?);
    try t.expectEqual(Table.Point{ .x = 10, .y = -40 }, points.get(1).?);
}

test "two_glyphs" {
    const data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 0 }, // reserved
        .{ .unt32 = 12 }, // offset to lookup table
        .{ .unt32 = 12 + 20 }, // offset to glyphs data
        // Lookup Table
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 2 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0 }, // glyph
        .{ .unt16 = 0 }, // offset
        // Segment [1]
        .{ .unt16 = 1 }, // glyph
        .{ .unt16 = 8 }, // offset
        // Glyphs Data
        // Glyph Data [0]
        .{ .unt32 = 1 }, // number of points
        // Point [0]
        .{ .int16 = -5 }, // x
        .{ .int16 = 11 }, // y
        // Glyph Data [1]
        .{ .unt32 = 1 }, // number of points
        // Point [0]
        .{ .int16 = 40 }, // x
        .{ .int16 = 10 }, // y
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, data);
    {
        const points = table.points(.{0}).?;
        try t.expectEqual(Table.Point{ .x = -5, .y = 11 }, points.get(0).?);
    }
    {
        const points = table.points(.{1}).?;
        try t.expectEqual(Table.Point{ .x = 40, .y = 10 }, points.get(0).?);
    }
}
