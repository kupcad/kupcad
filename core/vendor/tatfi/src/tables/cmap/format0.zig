//! A [format 0](https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-0-byte-encoding-table)
//! subtable.

const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");

const Subtable = @This();

/// Just a list of 256 8bit glyph IDs.
glyph_ids: []const u8,

/// Parses a subtable from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Subtable {
    var s = parser.Stream.new(data);

    s.skip(u16); // format
    s.skip(u16); // length
    s.skip(u16); // language

    const glyph_ids = try s.read_bytes(256);
    return .{ .glyph_ids = glyph_ids };
}

/// Returns a glyph index for a code point.
pub fn glyph_index(
    self: Subtable,
    code_point: u21,
) ?lib.GlyphId {
    if (code_point >= self.glyph_ids.len) return null;
    const glyph_id = self.glyph_ids[code_point];

    // Make sure that the glyph is not zero, the array always has 256 ids,
    // but some codepoints may be mapped to zero.
    if (glyph_id != 0) return .{glyph_id} else return null;
}

/// Calls `F` for each codepoint defined in this table.
pub fn codepoints(
    self: Subtable,
    ctx: anytype,
    F: fn (u21, @TypeOf(ctx)) void,
) void {
    // In contrast to every other format, here we take a look at the glyph
    // id and check whether it is zero because otherwise this method would
    // always simply call `f` for `0..256` which would be kind of pointless
    // (this array always has length 256 even when the face has fewer glyphs).
    for (0.., self.glyph_ids) |i, glyph_id|
        if (glyph_id != 0)
            F(@truncate(i), ctx);
}
