const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const cmap = ttf.tables.cmap;

test "format0 maps_not_all_256_codepoints" {
    var data = d: {
        const data = try convert(&.{
            .{ .unt16 = 0 }, // format
            .{ .unt16 = 262 }, // subtable size
            .{ .unt16 = 0 }, // language ID
        });

        break :d std.ArrayList(u8).fromOwnedSlice(data);
    };
    defer data.deinit(t.allocator);

    // Map (only) codepoint 0x40 to 100.
    try data.appendNTimes(t.allocator, 0, 256);
    data.items[6 + 0x40] = 100;

    const subtable = try cmap.Subtable0.parse(data.items);

    try t.expectEqual(null, subtable.glyph_index(0));
    try t.expectEqual(ttf.GlyphId{100}, subtable.glyph_index(0x40));
    try t.expectEqual(null, subtable.glyph_index(100));

    var vec: std.ArrayList(u21) = .empty;
    defer vec.deinit(t.allocator);

    subtable.codepoints(&vec, push_cp_to_vec);
    try t.expectEqualSlices(u21, &.{0x40}, vec.items);
}

const U16_SIZE: usize = @sizeOf(u16);

test "format2 collect_codepoints" {
    var data = d: {
        const data = try convert(&.{
            .{ .unt16 = 2 }, // format
            .{ .unt16 = 534 }, // subtable size
            .{ .unt16 = 0 }, // language ID
        });

        break :d std.ArrayList(u8).fromOwnedSlice(data);
    };
    defer data.deinit(t.allocator);

    // Make only high byte 0x28 multi-byte.
    try data.appendNTimes(t.allocator, 0, 256 * U16_SIZE);
    data.items[6 + 0x28 * U16_SIZE + 1] = 0x08;

    const extend = try convert(&.{
        // First sub header (for single byte mapping)
        .{ .unt16 = 254 }, // first code
        .{ .unt16 = 2 }, // entry count
        .{ .unt16 = 0 }, // id delta: uninteresting
        .{ .unt16 = 0 }, // id range offset: uninteresting
        // Second sub header (for high byte 0x28)
        .{ .unt16 = 16 }, // first code: (0x28 << 8) + 0x10 = 10256
        .{ .unt16 = 3 }, // entry count
        .{ .unt16 = 0 }, // id delta: uninteresting
        .{ .unt16 = 0 }, // id range offset: uninteresting
    });
    defer t.allocator.free(extend);
    try data.appendSlice(t.allocator, extend);

    // Now only glyph ID's would follow. Not interesting for codepoints.

    const subtable = try cmap.Subtable2.parse(data.items);

    var vec: std.ArrayList(u21) = .empty;
    defer vec.deinit(t.allocator);

    subtable.codepoints(&vec, push_cp_to_vec);
    try t.expectEqualSlices(u21, &.{ 10256, 10257, 10258, 254, 255 }, vec.items);
}

test "format2 codepoint_at_range_end" {
    var data = d: {
        const data = try convert(&.{
            .{ .unt16 = 2 }, // format
            .{ .unt16 = 532 }, // subtable size
            .{ .unt16 = 0 }, // language ID
        });

        break :d std.ArrayList(u8).fromOwnedSlice(data);
    };
    defer data.deinit(t.allocator);

    // Only single bytes.
    try data.appendNTimes(t.allocator, 0, 256 * U16_SIZE);
    const extend = try convert(&.{
        // First sub header (for single byte mapping)
        .{ .unt16 = 40 }, // first code
        .{ .unt16 = 2 }, // entry count
        .{ .unt16 = 0 }, // id delta
        .{ .unt16 = 2 }, // id range offset
        // Glyph index
        .{ .unt16 = 100 }, // glyph ID [0]
        .{ .unt16 = 1000 }, // glyph ID [1]
        .{ .unt16 = 10000 }, // glyph ID [2] (unused)
    });
    defer t.allocator.free(extend);
    try data.appendSlice(t.allocator, extend);

    const subtable = try cmap.Subtable2.parse(data.items);
    try t.expectEqual(null, subtable.glyph_index(39));
    try t.expectEqual(ttf.GlyphId{100}, subtable.glyph_index(40));
    try t.expectEqual(ttf.GlyphId{1000}, subtable.glyph_index(41));
    try t.expectEqual(null, subtable.glyph_index(42));
}

test "format4 single_glyph" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 32 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(ttf.GlyphId{1}, subtable.glyph_index(0x41));
    try t.expectEqual(null, subtable.glyph_index(0x42));
}

test "format4 continuous_range" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 32 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 73 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(null, subtable.glyph_index(0x40));
    try t.expectEqual(ttf.GlyphId{1}, subtable.glyph_index(0x41));
    try t.expectEqual(ttf.GlyphId{2}, subtable.glyph_index(0x42));
    try t.expectEqual(ttf.GlyphId{3}, subtable.glyph_index(0x43));
    try t.expectEqual(ttf.GlyphId{4}, subtable.glyph_index(0x44));
    try t.expectEqual(ttf.GlyphId{5}, subtable.glyph_index(0x45));
    try t.expectEqual(ttf.GlyphId{6}, subtable.glyph_index(0x46));
    try t.expectEqual(ttf.GlyphId{7}, subtable.glyph_index(0x47));
    try t.expectEqual(ttf.GlyphId{8}, subtable.glyph_index(0x48));
    try t.expectEqual(ttf.GlyphId{9}, subtable.glyph_index(0x49));
    try t.expectEqual(null, subtable.glyph_index(0x4A));
}

test "format4 multiple_ranges" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 48 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 8 }, // 2 x segCount
        .{ .unt16 = 4 }, // search range
        .{ .unt16 = 1 }, // entry selector
        .{ .unt16 = 4 }, // range shift
        // End character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 69 }, // char code [1]
        .{ .unt16 = 73 }, // char code [2]
        .{ .unt16 = 65535 }, // char code [3]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 67 }, // char code [1]
        .{ .unt16 = 71 }, // char code [2]
        .{ .unt16 = 65535 }, // char code [3]
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = -65 }, // delta [1]
        .{ .int16 = -66 }, // delta [2]
        .{ .int16 = 1 }, // delta [3]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
        .{ .unt16 = 0 }, // offset [2]
        .{ .unt16 = 0 }, // offset [3]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(null, subtable.glyph_index(0x40));
    try t.expectEqual(ttf.GlyphId{1}, subtable.glyph_index(0x41));
    try t.expectEqual(null, subtable.glyph_index(0x42));
    try t.expectEqual(ttf.GlyphId{2}, subtable.glyph_index(0x43));
    try t.expectEqual(ttf.GlyphId{3}, subtable.glyph_index(0x44));
    try t.expectEqual(ttf.GlyphId{4}, subtable.glyph_index(0x45));
    try t.expectEqual(null, subtable.glyph_index(0x46));
    try t.expectEqual(ttf.GlyphId{5}, subtable.glyph_index(0x47));
    try t.expectEqual(ttf.GlyphId{6}, subtable.glyph_index(0x48));
    try t.expectEqual(ttf.GlyphId{7}, subtable.glyph_index(0x49));
    try t.expectEqual(null, subtable.glyph_index(0x4A));
}

test "format4 unordered_ids" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 42 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 69 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = 0 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 4 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
        // Glyph index array
        .{ .unt16 = 1 }, // glyph ID [0]
        .{ .unt16 = 10 }, // glyph ID [1]
        .{ .unt16 = 100 }, // glyph ID [2]
        .{ .unt16 = 1000 }, // glyph ID [3]
        .{ .unt16 = 10000 }, // glyph ID [4]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(null, subtable.glyph_index(0x40));
    try t.expectEqual(ttf.GlyphId{1}, subtable.glyph_index(0x41));
    try t.expectEqual(ttf.GlyphId{10}, subtable.glyph_index(0x42));
    try t.expectEqual(ttf.GlyphId{100}, subtable.glyph_index(0x43));
    try t.expectEqual(ttf.GlyphId{1000}, subtable.glyph_index(0x44));
    try t.expectEqual(ttf.GlyphId{10000}, subtable.glyph_index(0x45));
    try t.expectEqual(null, subtable.glyph_index(0x46));
}

test "format4 unordered_chars_and_ids" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 64 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 12 }, // 2 x segCount
        .{ .unt16 = 8 }, // search range
        .{ .unt16 = 2 }, // entry selector
        .{ .unt16 = 4 }, // range shift
        // End character codes
        .{ .unt16 = 80 }, // char code [0]
        .{ .unt16 = 256 }, // char code [1]
        .{ .unt16 = 336 }, // char code [2]
        .{ .unt16 = 512 }, // char code [3]
        .{ .unt16 = 592 }, // char code [4]
        .{ .unt16 = 65535 }, // char code [5]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 80 }, // char code [0]
        .{ .unt16 = 256 }, // char code [1]
        .{ .unt16 = 336 }, // char code [2]
        .{ .unt16 = 512 }, // char code [3]
        .{ .unt16 = 592 }, // char code [4]
        .{ .unt16 = 65535 }, // char code [5]
        // Deltas
        .{ .int16 = -79 }, // delta [0]
        .{ .int16 = -246 }, // delta [1]
        .{ .int16 = -236 }, // delta [2]
        .{ .int16 = 488 }, // delta [3]
        .{ .int16 = 9408 }, // delta [4]
        .{ .int16 = 1 }, // delta [5]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
        .{ .unt16 = 0 }, // offset [2]
        .{ .unt16 = 0 }, // offset [3]
        .{ .unt16 = 0 }, // offset [4]
        .{ .unt16 = 0 }, // offset [5]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(null, subtable.glyph_index(0x40));
    try t.expectEqual(ttf.GlyphId{1}, subtable.glyph_index(0x50));
    try t.expectEqual(ttf.GlyphId{10}, subtable.glyph_index(0x100));
    try t.expectEqual(ttf.GlyphId{100}, subtable.glyph_index(0x150));
    try t.expectEqual(ttf.GlyphId{1000}, subtable.glyph_index(0x200));
    try t.expectEqual(ttf.GlyphId{10000}, subtable.glyph_index(0x250));
    try t.expectEqual(null, subtable.glyph_index(0x300));
}

test "format4 no_end_codes" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 28 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 73 }, // char code [0]
        // 0xFF, 0xFF, // char code [1] <-- removed
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        // 0xFF, 0xFF, // char code [1] <-- removed
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, cmap.Subtable4.parse(data));
}

test "format4 invalid_segment_count" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 32 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 1 }, // 2 x segCount <-- must be more than 1
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, cmap.Subtable4.parse(data));
}

test "format4 only_end_segments" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 32 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 2 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    // Should not loop forever.
    try t.expectEqual(null, subtable.glyph_index(0x41));
}

test "format4 invalid_length" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 16 }, // subtable size <-- the size should be 32, but we don't check it anyway
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(ttf.GlyphId{1}, subtable.glyph_index(0x41));
    try t.expectEqual(null, subtable.glyph_index(0x42));
}

test "format4 codepoint_out_of_range" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 32 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = -64 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 0 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    // Format 4 support only u16 codepoints, so we have to bail immediately otherwise.
    try t.expectEqual(null, subtable.glyph_index(0x1FFFF));
}

test "format4 zero" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 42 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 69 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = 0 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 4 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
        // Glyph index array
        .{ .unt16 = 0 }, // glyph ID [0] <-- indicates missing glyph
        .{ .unt16 = 10 }, // glyph ID [1]
        .{ .unt16 = 100 }, // glyph ID [2]
        .{ .unt16 = 1000 }, // glyph ID [3]
        .{ .unt16 = 10000 }, // glyph ID [4]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(null, subtable.glyph_index(0x41));
}

test "format4 invalid_offset" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 42 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 69 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 65 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        // Deltas
        .{ .int16 = 0 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 4 }, // offset [0]
        .{ .unt16 = 65535 }, // offset [1]
        // Glyph index array
        .{ .unt16 = 1 }, // glyph ID [0]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);
    try t.expectEqual(null, subtable.glyph_index(65535));
}

test "format4 collect_codepoints" {
    const data = try convert(&.{
        .{ .unt16 = 4 }, // format
        .{ .unt16 = 24 }, // subtable size
        .{ .unt16 = 0 }, // language ID
        .{ .unt16 = 4 }, // 2 x segCount
        .{ .unt16 = 2 }, // search range
        .{ .unt16 = 0 }, // entry selector
        .{ .unt16 = 2 }, // range shift
        // End character codes
        .{ .unt16 = 34 }, // char code [0]
        .{ .unt16 = 65535 }, // char code [1]
        .{ .unt16 = 0 }, // reserved
        // Start character codes
        .{ .unt16 = 27 }, // char code [0]
        .{ .unt16 = 65533 }, // char code [1]
        // Deltas
        .{ .int16 = 0 }, // delta [0]
        .{ .int16 = 1 }, // delta [1]
        // Offsets into Glyph index array
        .{ .unt16 = 4 }, // offset [0]
        .{ .unt16 = 0 }, // offset [1]
        // Glyph index array
        .{ .unt16 = 0 }, // glyph ID [0]
        .{ .unt16 = 10 }, // glyph ID [1]
    });
    defer t.allocator.free(data);

    const subtable = try cmap.Subtable4.parse(data);

    var vec: std.ArrayList(u21) = .empty;
    defer vec.deinit(t.allocator);

    subtable.codepoints(&vec, push_cp_to_vec);
    try t.expectEqualSlices(u21, &.{
        27, 28, 29, 30, 31, 32, 33, 34, 65533, 65534, 65535,
    }, vec.items);
}

// Helpers

fn push_cp_to_vec(cp: u21, v: *std.ArrayList(u21)) void {
    v.append(t.allocator, cp) catch unreachable;
}
