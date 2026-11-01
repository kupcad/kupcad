const std = @import("std");
const testing = std.testing;
const LineIndex = @import("line_index.zig").LineIndex;

test "LineIndex: accurately calculates line numbers from offsets" {
    // 0123 4567 8
    // foo\nbar\n
    const source = "foo\nbar\n";
    var index = try LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);

    // Verify line starts
    try testing.expectEqual(@as(usize, 3), index.line_starts.len);
    try testing.expectEqual(@as(u32, 0), index.line_starts[0]);
    try testing.expectEqual(@as(u32, 4), index.line_starts[1]); // 'b'
    try testing.expectEqual(@as(u32, 8), index.line_starts[2]); // after second '\n'

    // Verify getLine binary search
    try testing.expectEqual(@as(u32, 0), index.getLine(0)); // 'f'
    try testing.expectEqual(@as(u32, 0), index.getLine(3)); // '\n'
    try testing.expectEqual(@as(u32, 1), index.getLine(4)); // 'b'
    try testing.expectEqual(@as(u32, 1), index.getLine(7)); // '\n'
    try testing.expectEqual(@as(u32, 2), index.getLine(8)); // EOF
}

test "LineIndex: correctly maps UTF-8 and UTF-16 columns for LSP" {
    // The rocket emoji '🚀' takes 4 bytes in UTF-8, but 2 code units in UTF-16 (Surrogate Pair)
    // Byte indices:
    // a (0)
    //   (1)
    // 🚀 (2, 3, 4, 5)
    //   (6)
    // b (7)
    const source = "a 🚀 b\n";
    var index = try LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);

    // Target the 'b' character
    const target_offset: u32 = 7;

    try testing.expectEqual(@as(u32, 0), index.getLine(target_offset));

    // UTF-8 Column should match the raw byte difference exactly
    try testing.expectEqual(@as(u32, 7), index.getUtf8Column(target_offset));

    // UTF-16 Column should treat the 4-byte emoji as 2 code units
    // 'a'(1) + ' '(1) + '🚀'(2) + ' '(1) = 5
    try testing.expectEqual(@as(u32, 5), index.getUtf16Column(target_offset));
}

test "LineIndex: safely handles empty strings" {
    const source = "";
    var index = try LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), index.line_starts.len);
    try testing.expectEqual(@as(u32, 0), index.getLine(0));
    try testing.expectEqual(@as(u32, 0), index.getUtf8Column(0));
    try testing.expectEqual(@as(u32, 0), index.getUtf16Column(0));
}

test "LineIndex: humanPosition is the 1-based line and UTF-8 column compilers print" {
    const source = "a = 1\nμ = 2\n";
    const index = try LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);
    const first = index.humanPosition(0);
    try testing.expectEqual(@as(u32, 1), first.line);
    try testing.expectEqual(@as(u32, 1), first.column);
    // "μ" is two bytes: the `=` after it is byte column 4 of line 2.
    const eq = index.humanPosition(@intCast(std.mem.findScalarLast(u8, source, '=').?));
    try testing.expectEqual(@as(u32, 2), eq.line);
    try testing.expectEqual(@as(u32, 4), eq.column);
}

test "LineIndex: offsetOf is humanPosition's way back, a column held to its line" {
    const source = "x = 1\ncube(2) # é\n";
    const index = try LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);
    for ([_]u32{ 0, 4, 6, 10, 15 }) |offset| {
        const at = index.humanPosition(offset);
        try testing.expectEqual(@as(?u32, offset), index.offsetOf(at.line, at.column));
    }
    // Past its line's end, its last character; past the last line, nothing
    try testing.expectEqual(@as(?u32, 5), index.offsetOf(1, 40));
    try testing.expectEqual(@as(?u32, null), index.offsetOf(4, 1));
    try testing.expectEqual(@as(?u32, null), index.offsetOf(0, 1));
}

test "LineIndex: a byte order mark is no part of line 1, which an editor shows without it" {
    // `cube(-1)` was flagged at 1:9 for the `-` at 1:6, the caret three places past it
    const source = "\xEF\xBB\xBFcube(-1)\nx = 1\n";
    const index = try LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);
    const minus: u32 = @intCast(std.mem.findScalar(u8, source, '-').?);
    try testing.expectEqual(@as(u32, 1), index.humanPosition(minus).line);
    try testing.expectEqual(@as(u32, 6), index.humanPosition(minus).column);
    try testing.expectEqual(@as(u32, 5), index.getUtf16Column(minus));
    try testing.expectEqualStrings("cube(-1)", index.lineText(source, 0));
    try testing.expectEqual(@as(?u32, minus), index.offsetOf(1, 6));
    // The mark's own bytes are at the line's start, not before it
    try testing.expectEqual(@as(u32, 1), index.humanPosition(0).column);
    try testing.expectEqual(@as(u32, 0), index.getUtf16Column(1));
    // Line 2 as it was
    try testing.expectEqual(@as(u32, 2), index.humanPosition(minus + 5).line);
}
