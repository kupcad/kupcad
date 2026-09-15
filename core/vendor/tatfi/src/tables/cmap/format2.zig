//! A [format 2](https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-2-high-byte-mapping-through-table)
//! subtable.
// This table has a pretty complex parsing algorithm.
// A detailed explanation can be found here:
// https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-2-high-byte-mapping-through-table
// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6cmap.html
// https://github.com/fonttools/fonttools/blob/a360252709a3d65f899915db0a5bd753007fdbb7/Lib/fontTools/ttLib/tables/_c_m_a_p.py#L360

const std = @import("std");
const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");

const Subtable = @This();

sub_header_keys: parser.LazyArray16(u16),
sub_headers_offset: usize,
sub_headers: parser.LazyArray16(SubHeaderRecord),
// The whole subtable data.
data: []const u8,

/// Parses a subtable from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Subtable {
    var s = parser.Stream.new(data);
    s.skip(u16); // format
    s.skip(u16); // length
    s.skip(u16); // language
    const sub_header_keys = try s.read_array(u16, @as(u16, 256));
    // The maximum index in a sub_header_keys is a sub_headers count.
    const sub_headers_count = c: {
        var iter = sub_header_keys.iterator();
        var max: ?u16 = null;
        while (iter.next()) |n| {
            max = @max(max orelse 0, n / 8);
        }
        break :c (max orelse return error.ParseFail) + 1;
    };

    // Remember sub_headers offset before reading. Will be used later.
    const sub_headers_offset = s.offset;
    const sub_headers = try s.read_array(SubHeaderRecord, sub_headers_count);

    return .{
        .sub_header_keys = sub_header_keys,
        .sub_headers_offset = sub_headers_offset,
        .sub_headers = sub_headers,
        .data = data,
    };
}

/// Returns a glyph index for a code point.
///
/// Returns `null` when `code_point` is larger than `u16`.
pub fn glyph_index(
    self: Subtable,
    code_point: u21,
) ?lib.GlyphId {
    // This subtable supports code points only in a u16 range.
    const code_point_16 = std.math.cast(u16, code_point) orelse
        return null;

    const high_byte = code_point_16 >> 8;
    const low_byte = code_point_16 & 0x00FF;

    const i: u16 = if (code_point_16 > 0xFF)
        // 'SubHeader 0 is special: it is used for single-byte character codes.'
        0
    else
        // 'Array that maps high bytes to subHeaders: value is subHeader index × 8.'
        (self.sub_header_keys.get(high_byte) orelse return null) / 8;

    const sub_header = self.sub_headers.get(i) orelse return null;

    const first_code = sub_header.first_code;
    const range_end = std.math.add(u16, first_code, sub_header.entry_count) catch
        return null;
    if (low_byte < first_code or low_byte >= range_end)
        return null;

    // SubHeaderRecord.id_range_offset points to SubHeaderRecord.first_code
    // in the glyphIndexArray. So we have to advance to our code point.
    const index_offset = io: {
        const s: usize = std.math.sub(u16, low_byte, first_code) catch
            return null;
        break :io s * @sizeOf(u16);
    };

    // 'The value of the idRangeOffset is the number of bytes
    // past the actual location of the idRangeOffset'.
    const offset: usize = self.sub_headers_offset
        // Advance to required subheader.
    + SubHeaderRecord.FromData.SIZE * (@as(usize, i) + 1)
        // Move back to idRangeOffset start.
    - @sizeOf(u16)
        // Use defined offset.
    + sub_header.id_range_offset
        // Advance to required index in the glyphIndexArray.
    + index_offset;

    var s = parser.Stream.new(self.data);
    const glyph = s.read_at(u16, offset) catch return null;
    if (glyph == 0) return null;

    const v = @rem((@as(i32, glyph) + @as(i32, sub_header.id_delta)), 1 << 16);
    return .{std.math.cast(u16, v) orelse return null};
}

/// Calls `f` for each codepoint defined in this table.
pub fn codepoints(
    self: Subtable,
    ctx: anytype,
    F: fn (u21, @TypeOf(ctx)) void,
) void {
    for (0..256) |first_byte_usize| {
        const first_byte: u16 = @truncate(first_byte_usize);
        const i = i: {
            const i = self.sub_header_keys.get(first_byte) orelse return;
            break :i i / 8;
        };
        const sub_header = self.sub_headers.get(i) orelse return;
        const first_code = sub_header.first_code;

        if (i == 0) {
            // This is a single byte code.
            const range_end = std.math.add(u16, first_code, sub_header.entry_count) catch return;
            if (first_byte >= first_code and first_byte < range_end)
                F(first_byte, ctx);
        } else {
            // This is a two byte code.
            const base = std.math.add(u16, first_code, first_byte << 8) catch return;
            for (0..sub_header.entry_count) |k| {
                const code_point = std.math.add(u16, base, @truncate(k)) catch return;
                F(code_point, ctx);
            }
        }
    }
}

const SubHeaderRecord = struct {
    first_code: u16,
    entry_count: u16,
    id_delta: i16,
    id_range_offset: u16,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 8;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};
