const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;

const convert = @import("main.zig").convert;

const Lookup = ttf.apple_layout.Lookup;

test "format0 single" {
    const data = try convert(&.{
        .{ .unt16 = 0 }, // format
        .{ .unt16 = 10 }, // value
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(10, table.value(.{0}));
    try t.expectEqual(null, table.value(.{1}));
}

test "format0 not enough glyphs" {
    const data = try convert(&.{
        .{ .unt16 = 0 }, // format
        .{ .unt16 = 10 }, // value
    });
    defer t.allocator.free(data);

    const table = Lookup.parse(2, data);
    try t.expectError(error.ParseFail, table);
}

test "format0 too many glyphs" {
    const data = try convert(&.{
        .{ .unt16 = 0 }, // format
        .{ .unt16 = 10 }, // value
        .{ .unt16 = 11 }, // value <-- will be ignored
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(10, table.value(.{0}));
    try t.expectEqual(null, table.value(.{1}));
}

test "format2 single" {
    const data = try convert(&.{
        .{ .unt16 = 2 }, // format
        // Binary Search Table
        .{ .unt16 = 6 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 118 }, // last glyph
        .{ .unt16 = 118 }, // first glyph
        .{ .unt16 = 10 }, // value
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(10, table.value(.{118}));
    try t.expectEqual(null, table.value(.{1}));
}

test "format2 range" {
    const data = try convert(&.{
        .{ .unt16 = 2 }, // format
        // Binary Search Table
        .{ .unt16 = 6 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 7 }, // last glyph
        .{ .unt16 = 5 }, // first glyph
        .{ .unt16 = 18 }, // offset
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(null, table.value(.{4}));
    try t.expectEqual(18, table.value(.{5}));
    try t.expectEqual(18, table.value(.{6}));
    try t.expectEqual(18, table.value(.{7}));
    try t.expectEqual(null, table.value(.{8}));
}

test "format4 single" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        // Binary Search Table
        .{ .unt16 = 6 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 118 }, // last glyph
        .{ .unt16 = 118 }, // first glyph
        .{ .unt16 = 18 }, // offset
        // Values [0]
        .{ .unt16 = 10 }, // value [0]
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(10, table.value(.{118}));
    try t.expectEqual(null, table.value(.{1}));
}

test "format4 range" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        // Binary Search Table
        .{ .unt16 = 6 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 7 }, // last glyph
        .{ .unt16 = 5 }, // first glyph
        .{ .unt16 = 18 }, // offset
        // Values [0]
        .{ .unt16 = 10 }, // value [0]
        .{ .unt16 = 11 }, // value [1]
        .{ .unt16 = 12 }, // value [2]
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(null, table.value(.{4}));
    try t.expectEqual(10, table.value(.{5}));
    try t.expectEqual(11, table.value(.{6}));
    try t.expectEqual(12, table.value(.{7}));
    try t.expectEqual(null, table.value(.{8}));
}

test "format6 single" {
    const data = try convert(&.{
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0 }, // glyph
        .{ .unt16 = 10 }, // value
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(10, table.value(.{0}));
    try t.expectEqual(null, table.value(.{1}));
}

test "format6 multiple" {
    const data = try convert(&.{
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 3 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0 }, // glyph
        .{ .unt16 = 10 }, // value
        // Segment [1]
        .{ .unt16 = 5 }, // glyph
        .{ .unt16 = 20 }, // value
        // Segment [2]
        .{ .unt16 = 10 }, // glyph
        .{ .unt16 = 30 }, // value
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(10, table.value(.{0}));
    try t.expectEqual(20, table.value(.{5}));
    try t.expectEqual(30, table.value(.{10}));
    try t.expectEqual(null, table.value(.{1}));
}

// Tests below are indirectly testing BinarySearchTable.

test "format6 no_segments" {
    const data = try convert(&.{
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 0 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Lookup.parse(1, data));
}

test "format6 ignore_termination" {
    const data = try convert(&.{
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 2 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0 }, // glyph
        .{ .unt16 = 10 }, // value
        // Segment [1]
        .{ .unt16 = 0xFFFF }, // glyph
        .{ .unt16 = 0xFFFF }, // value
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(null, table.value(.{0xFFFF}));
}

test "format6 only_termination" {
    const data = try convert(&.{
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 4 }, // segment size
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0xFFFF }, // glyph
        .{ .unt16 = 0xFFFF }, // value
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Lookup.parse(1, data));
}

test "format6 invalid_segment_size" {
    const data = try convert(&.{
        .{ .unt16 = 6 }, // format
        // Binary Search Table
        .{ .unt16 = 8 }, // segment size <-- must be 4
        .{ .unt16 = 1 }, // number of segments
        .{ .unt16 = 0 }, // search range: we don't use it
        .{ .unt16 = 0 }, // entry selector: we don't use it
        .{ .unt16 = 0 }, // range shift: we don't use it
        // Segment [0]
        .{ .unt16 = 0 }, // glyph
        .{ .unt16 = 10 }, // value
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Lookup.parse(1, data));
}

test "format8 single" {
    const data = try convert(&.{
        .{ .unt16 = 8 }, // format
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 1 }, // glyphs count
        .{ .unt16 = 2 }, // value [0]
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(2, table.value(.{0}));
    try t.expectEqual(null, table.value(.{1}));
}

test "format8 non_zero_first" {
    const data = try convert(&.{
        .{ .unt16 = 8 }, // format
        .{ .unt16 = 5 }, // first glyph
        .{ .unt16 = 1 }, // glyphs count
        .{ .unt16 = 2 }, // value [0]
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(2, table.value(.{5}));
    try t.expectEqual(null, table.value(.{1}));
    try t.expectEqual(null, table.value(.{6}));
}

test "format10 single" {
    const data = try convert(&.{
        .{ .unt16 = 10 }, // format
        .{ .unt16 = 1 }, // value size: u8
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 1 }, // glyphs count
        .{ .unt8 = 2 }, // value [0]
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(2, table.value(.{0}));
    try t.expectEqual(null, table.value(.{1}));
}

test "format10 invalid_value_size" {
    const data = try convert(&.{
        .{ .unt16 = 10 }, // format
        .{ .unt16 = 50 }, // value size <-- invalid
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 1 }, // glyphs count
        .{ .unt8 = 2 }, // value [0]
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(null, table.value(.{0}));
}

test "format10 unsupported_value_size" {
    const data = try convert(&.{
        .{ .unt16 = 10 }, // format
        .{ .unt16 = 8 }, // value size <-- we do not support u64
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 1 }, // glyphs count
        .{ .raw = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 } }, // value [0]
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(null, table.value(.{0}));
}

test "format10 u32_value_size" {
    const data = try convert(&.{
        .{ .unt16 = 10 }, // format
        .{ .unt16 = 4 }, // value size
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 1 }, // glyphs count
        .{ .unt32 = 0xFFFF + 10 }, // value [0] <-- will be truncated
    });
    defer t.allocator.free(data);

    const table: Lookup = try .parse(1, data);
    try t.expectEqual(9, table.value(.{0}));
}

/// A format 1 state table of four classes whose state 0 goes to entry `entry` for every
/// glyph of class 1, glyph 0.
fn state_table(number_of_classes: u16, entry: u8) ![]u8 {
    return convert(&.{
        .{ .unt16 = number_of_classes }, // number of classes
        .{ .unt16 = 8 }, // class table offset
        .{ .unt16 = 13 }, // state array offset
        .{ .unt16 = 14 }, // entry table offset
        // Class table
        .{ .unt16 = 0 }, // first glyph
        .{ .unt16 = 1 }, // number of glyphs
        .{ .unt8 = 1 }, // glyph 0's class
        // State array
        .{ .unt8 = entry }, // state 0, class 0
        // Entry table
        .{ .unt32 = 0 }, // entry 0
    });
}

test "state table entry 64" {
    // [KupCAD] The entry's offset overflowed the u8 index times the entry's size.
    const data = try state_table(4, 64);
    defer t.allocator.free(data);

    const table = try ttf.apple_layout.StateTable.parse(data);
    try t.expectEqual(null, table.entry(0, 0));
}

test "state table of no classes" {
    // [KupCAD] A new state divided by the number of classes, zero.
    const data = try state_table(0, 0);
    defer t.allocator.free(data);

    const table = try ttf.apple_layout.StateTable.parse(data);
    try t.expectEqual(0, table.new_state(20));
}
