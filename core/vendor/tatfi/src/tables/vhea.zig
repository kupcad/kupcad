//! A [Vertical Header Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/vhea) implementation.

const parser = @import("../parser.zig");

const Table = @This();

/// Face ascender.
ascender: i16,
/// Face descender.
descender: i16,
/// Face line gap.
line_gap: i16,
/// Number of metrics in the `vmtx` table.
number_of_metrics: u16,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    // Do not check the exact length, because some fonts include
    // padding in table's length in table records, which is incorrect.
    if (data.len < 36) return error.ParseFail;

    var s = parser.Stream.new(data);
    s.skip(u32); // version
    const ascender = try s.read(i16);
    const descender = try s.read(i16);
    const line_gap = try s.read(i16);
    s.advance(24);
    const number_of_metrics = try s.read(u16);

    return .{
        .ascender = ascender,
        .descender = descender,
        .line_gap = line_gap,
        .number_of_metrics = number_of_metrics,
    };
}
