//! A [format 4](https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-4-segment-mapping-to-delta-values)
//! subtable.

const std = @import("std");
const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");

const Subtable = @This();

start_codes: parser.LazyArray16(u16),
end_codes: parser.LazyArray16(u16),
id_deltas: parser.LazyArray16(i16),
id_range_offsets: parser.LazyArray16(u16),
id_range_offset_pos: usize,
// The whole subtable data.
data: []const u8,

/// Parses a subtable from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Subtable {
    var s = parser.Stream.new(data);
    s.advance(6); // format + length + language
    const seg_count_x2 = try s.read(u16);
    if (seg_count_x2 < 2) return error.ParseFail;

    const seg_count = seg_count_x2 / 2;
    s.advance(6); // searchRange + entrySelector + rangeShift

    const end_codes = try s.read_array(u16, seg_count);
    s.skip(u16); // reservedPad
    const start_codes = try s.read_array(u16, seg_count);
    const id_deltas = try s.read_array(i16, seg_count);
    const id_range_offset_pos = s.offset;
    const id_range_offsets = try s.read_array(u16, seg_count);

    return .{
        .start_codes = start_codes,
        .end_codes = end_codes,
        .id_deltas = id_deltas,
        .id_range_offsets = id_range_offsets,
        .id_range_offset_pos = id_range_offset_pos,
        .data = data,
    };
}

/// Returns a glyph index for a code point.
pub fn glyph_index(
    self: Subtable,
    code_point: u21,
) ?lib.GlyphId {
    // This subtable supports code points only in a u16 range.
    const code_point_16 = std.math.cast(u16, code_point) orelse
        return null;

    // A custom binary search.
    var start: u16 = 0;
    var end = self.start_codes.len();

    while (end > start) {
        const index = (start + end) / 2;
        const end_value = self.end_codes.get(index) orelse return null;

        if (end_value < code_point_16) {
            start = index + 1;
            continue;
        }

        const start_value = self.start_codes.get(index) orelse return null;
        if (start_value > code_point_16) {
            end = index;
            continue;
        }

        const id_range_offset = self.id_range_offsets.get(index) orelse return null;
        const id_delta = self.id_deltas.get(index) orelse return null;

        if (id_range_offset == 0)
            return .{code_point_16 +% @as(u16, @bitCast(id_delta))}
        else if (id_range_offset == 0xFFFF)
            // Some malformed fonts have 0xFFFF as the last offset,
            // which is invalid and should be ignored.
            return null;

        const delta = d: {
            const delta = (@as(u32, code_point_16) - @as(u32, start_value)) * 2;
            break :d std.math.cast(u16, delta) orelse return null;
        };

        const id_range_offset_pos: u16 = @truncate(self.id_range_offset_pos + @as(usize, index) * 2);
        const pos = p: {
            const pos = id_range_offset_pos +% delta;
            break :p pos +% id_range_offset;
        };

        var s = parser.Stream.new(self.data);
        const glyph_array_value = s.read_at(i16, pos) catch return null;

        // 0 indicates missing glyph.
        if (glyph_array_value == 0) return null;

        const glyph_id = glyph_array_value +% id_delta;
        return .{
            std.math.cast(u16, glyph_id) orelse return null,
        };
    }

    return null;
}

/// Calls `F` for each codepoint defined in this table.
pub fn codepoints(
    self: Subtable,
    ctx: anytype,
    F: fn (u21, @TypeOf(ctx)) void,
) void {
    var start_iter = self.start_codes.iterator();
    var end_iter = self.end_codes.iterator();

    while (true) {
        const start = start_iter.next() orelse break;
        const end: usize = end_iter.next() orelse break;

        // OxFFFF value is special and indicates codes end.
        if (start == end and start == 0xFFFF) break;

        for (start..end + 1) |code_point|
            F(@truncate(code_point), ctx);
    }
}
