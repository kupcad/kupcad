//! A [format 6](https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-6-trimmed-table-mapping)
//! subtable.

const std = @import("std");
const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");

const Subtable = @This();

/// First character code of subrange.
first_code_point: u16,
/// Array of glyph indexes for character codes in the range.
glyphs: parser.LazyArray16(lib.GlyphId),

/// Parses a subtable from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Subtable {
    var s = parser.Stream.new(data);
    s.skip(u16); // format
    s.skip(u16); // length
    s.skip(u16); // language
    const first_code_point = try s.read(u16);
    const count = try s.read(u16);
    const glyphs = try s.read_array(lib.GlyphId, count);
    return .{
        .first_code_point = first_code_point,
        .glyphs = glyphs,
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
    const code_point_16 = std.math.cast(u16, code_point) orelse return null;
    const idx = std.math.sub(u16, code_point_16, self.first_code_point) catch return null;
    return self.glyphs.get(idx);
}

/// Calls `f` for each codepoint defined in this table.
pub fn codepoints(
    self: Subtable,
    ctx: anytype,
    F: fn (u21, @TypeOf(ctx)) void,
) void {
    for (0..self.glyphs.len()) |i| {
        const code_point = std.math.add(u16, self.first_code_point, @truncate(i)) catch continue;
        F(code_point, ctx);
    }
}
