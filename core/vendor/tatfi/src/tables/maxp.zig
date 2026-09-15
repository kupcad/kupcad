//! A [Maximum Profile Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/maxp) implementation.

const parser = @import("../parser.zig");

const Table = @This();
/// The total number of glyphs in the face.
number_of_glyphs: u16, // nonzero,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);
    const version = try s.read(u32);
    if (!(version == 0x00005000 or version == 0x00010000))
        return error.ParseFail;

    const n = try s.read(u16);
    if (n == 0) return error.ParseFail;

    return .{ .number_of_glyphs = n };
}
