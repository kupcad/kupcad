const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const Table = ttf.tables.maxp;

test "version_05" {
    const data = try convert(&.{
        .{ .fixed = 0.3125 }, // version
        .{ .unt16 = 1 }, // number of glyphs
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    try t.expectEqual(1, table.number_of_glyphs);
}

test "version_1_full" {
    const data = try convert(&.{
        .{ .fixed = 1.0 }, // version
        .{ .unt16 = 1 }, // number of glyphs
        .{ .unt16 = 0 }, // maximum points in a non-composite glyph
        .{ .unt16 = 0 }, // maximum contours in a non-composite glyph
        .{ .unt16 = 0 }, // maximum points in a composite glyph
        .{ .unt16 = 0 }, // maximum contours in a composite glyph
        .{ .unt16 = 0 }, // maximum zones
        .{ .unt16 = 0 }, // maximum twilight points
        .{ .unt16 = 0 }, // number of Storage Area locations
        .{ .unt16 = 0 }, // number of FDEFs
        .{ .unt16 = 0 }, // number of IDEFs
        .{ .unt16 = 0 }, // maximum stack depth
        .{ .unt16 = 0 }, // maximum byte count for glyph instructions
        .{ .unt16 = 0 }, // maximum number of components
        .{ .unt16 = 0 }, // maximum levels of recursion
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    try t.expectEqual(1, table.number_of_glyphs);
}

test "version_1_trimmed" {
    // We don't really care about the data after the number of glyphs.
    const data = try convert(&.{
        .{ .fixed = 1.0 }, // version
        .{ .unt16 = 1 }, // number of glyphs
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    try t.expectEqual(1, table.number_of_glyphs);
}

test "unknown_version" {
    const data = try convert(&.{
        .{ .fixed = 0.0 }, // version
        .{ .unt16 = 1 }, // number of glyphs
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Table.parse(data));
}

test "zero_glyphs" {
    const data = try convert(&.{
        .{ .fixed = 0.3125 }, // version
        .{ .unt16 = 0 }, // number of glyphs
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Table.parse(data));
}

// TODO: what to do when the number of glyphs is 0xFFFF?
//       we're actually checking this in loca
