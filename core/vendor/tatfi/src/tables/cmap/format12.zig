//! A [format 12](https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-12-segmented-coverage)
//! subtable.

const std = @import("std");
const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");

const Subtable = @This();

groups: parser.LazyArray32(SequentialMapGroup),

/// Parses a subtable from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Subtable {
    var s = parser.Stream.new(data);
    s.skip(u16); // format
    s.skip(u16); // reserved
    s.skip(u32); // length
    s.skip(u32); // language
    const count = try s.read(u32);
    const groups = try s.read_array(SequentialMapGroup, count);
    return .{ .groups = groups };
}

/// Returns a glyph index for a code point.
///
/// Returns `null` when `code_point` is larger than `u16`.
pub fn glyph_index(
    self: Subtable,
    code_point: u21,
) ?lib.GlyphId {
    _, const group = self.groups.binary_search_by(
        code_point,
        SequentialMapGroup.compare,
    ) catch return null;

    const id = id: {
        const s1 = std.math.add(u32, group.start_glyph_id, code_point) catch return null;
        const s2 = std.math.sub(u32, s1, group.start_char_code) catch return null;
        break :id std.math.cast(u16, s2) orelse return null;
    };
    return .{id};
}

/// Calls `f` for each codepoint defined in this table.
pub fn codepoints(
    self: Subtable,
    ctx: anytype,
    F: fn (u21, @TypeOf(ctx)) void,
) void {
    var iter = self.groups.iterator();
    while (iter.next()) |group| {
        var code_point: u21 = @truncate(group.start_char_code);
        while (code_point <= group.end_char_code) : (code_point += 1)
            F(code_point, ctx);
    }
}

pub const SequentialMapGroup = struct {
    start_char_code: u32,
    end_char_code: u32,
    start_glyph_id: u32,

    fn compare(range: SequentialMapGroup, code_point: u21) std.math.Order {
        if (range.start_char_code > code_point)
            return .gt
        else if (range.end_char_code < code_point)
            return .lt
        else
            return .eq;
    }

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 12;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};
