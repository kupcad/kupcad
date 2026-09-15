const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const Table = ttf.tables.hmtx;

test "simple_case" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // advance width [0]
        .{ .int16 = 2 }, // side bearing [0]
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, 1, data);
    try t.expectEqual(1, table.advance(.{0}));
    try t.expectEqual(2, table.side_bearing(.{0}));
}

test "empty" {
    try t.expectError(error.ParseFail, Table.parse(1, 1, &.{}));
}

test "zero_metrics" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // advance width [0]
        .{ .int16 = 2 }, // side bearing [0]
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Table.parse(0, 1, data));
}

test "smaller_than_glyphs_count" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // advance width [0]
        .{ .int16 = 2 }, // side bearing [0]
        .{ .int16 = 3 }, // side bearing [1]
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, 2, data);
    try t.expectEqual(1, table.advance(.{0}));
    try t.expectEqual(2, table.side_bearing(.{0}));
    try t.expectEqual(1, table.advance(.{1}));
    try t.expectEqual(3, table.side_bearing(.{1}));
}

test "no_additional_side_bearings" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // advance width [0]
        .{ .int16 = 2 }, // side bearing [0]

        // A single side bearing should be present here.
        // We should simply ignore it and not return null during Table parsing.
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, 2, data);
    try t.expectEqual(1, table.advance(.{0}));
    try t.expectEqual(2, table.side_bearing(.{0}));
}

test "less_metrics_than_glyphs" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // advance width [0]
        .{ .int16 = 2 }, // side bearing [0]
        .{ .unt16 = 3 }, // advance width [1]
        .{ .int16 = 4 }, // side bearing [1]
        .{ .int16 = 5 }, // side bearing [2]
    });
    defer t.allocator.free(data);

    const table = try Table.parse(2, 1, data);
    try t.expectEqual(2, table.side_bearing(.{0}));
    try t.expectEqual(4, table.side_bearing(.{1}));
    try t.expectEqual(null, table.side_bearing(.{2}));
}

test "glyph_out_of_bounds_0" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // advance width [0]
        .{ .int16 = 2 }, // side bearing [0]
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, 1, data);
    try t.expectEqual(1, table.advance(.{0}));
    try t.expectEqual(2, table.side_bearing(.{0}));
    try t.expectEqual(null, table.advance(.{1}));
    try t.expectEqual(null, table.side_bearing(.{1}));
}

test "glyph_out_of_bounds_1" {
    const data = try convert(&.{
        .{ .unt16 = 1 }, // advance width [0]
        .{ .int16 = 2 }, // side bearing [0]
        .{ .int16 = 3 }, // side bearing [1]
    });
    defer t.allocator.free(data);

    const table = try Table.parse(1, 2, data);
    try t.expectEqual(1, table.advance(.{1}));
    try t.expectEqual(3, table.side_bearing(.{1}));
    try t.expectEqual(null, table.advance(.{2}));
    try t.expectEqual(null, table.side_bearing(.{2}));
}
