const std = @import("std");
const testing = std.testing;
const LineIndex = @import("line_index.zig").LineIndex;

test "LineIndex: accurately calculates line numbers from offsets" {
    // 0123 4567 8
    // foo\nbar\n
    const source = "foo\nbar\n";
    var index = try LineIndex.init(testing.allocator, source);
    defer testing.allocator.free(index.line_starts);

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
    defer testing.allocator.free(index.line_starts);

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
    defer testing.allocator.free(index.line_starts);

    try testing.expectEqual(@as(usize, 1), index.line_starts.len);
    try testing.expectEqual(@as(u32, 0), index.getLine(0));
    try testing.expectEqual(@as(u32, 0), index.getUtf8Column(0));
    try testing.expectEqual(@as(u32, 0), index.getUtf16Column(0));
}
