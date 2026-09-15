//! A [Font Header Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/head) implementation.

const std = @import("std");
const parser = @import("../parser.zig");

const lib = @import("../lib.zig");

const Table = @This();

/// Units per EM.
///
/// Guarantee to be in a 16..=16384 range.
units_per_em: u16,
/// A bounding box that large enough to enclose any glyph from the face.
global_bbox: lib.Rect,
/// An index format used by the [Index to Location Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/loca).
index_to_location_format: IndexToLocationFormat,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    // Do not check the exact length, because some fonts include
    // padding in table's length in table records, which is incorrect.
    if (data.len < 54)
        return error.ParseFail;

    var s = parser.Stream.new(data);
    s.skip(u32); // version
    s.skip(parser.Fixed); // font revision
    s.skip(u32); // checksum adjustment
    s.skip(u32); // magic number
    s.skip(u16); // flags
    const units_per_em = try s.read(u16);
    if (units_per_em < 16 or units_per_em > 16348) return error.ParseFail;

    s.skip(u64); // created time
    s.skip(u64); // modified time
    const x_min = try s.read(i16);
    const y_min = try s.read(i16);
    const x_max = try s.read(i16);
    const y_max = try s.read(i16);
    s.skip(u16); // mac style
    s.skip(u16); // lowest PPEM
    s.skip(i16); // font direction hint
    const index_to_location_format: IndexToLocationFormat =
        switch (try s.read(u16)) {
            0 => .short,
            1 => .long,
            else => return error.ParseFail,
        };

    return .{
        .units_per_em = units_per_em,
        .global_bbox = .{
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
        },
        .index_to_location_format = index_to_location_format,
    };
}

/// An index format used by the [Index to Location Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/loca).
pub const IndexToLocationFormat = enum { short, long };
