//! A [format 14](https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-14-unicode-variation-sequences)
//! subtable.

const std = @import("std");
const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");
const utils = @import("../../utils.zig");

const Subtable = @This();

records: parser.LazyArray32(VariationSelectorRecord),
// The whole subtable data.
data: []const u8,

/// Parses a subtable from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Subtable {
    var s = parser.Stream.new(data);
    s.skip(u16); // format
    s.skip(u32); // length
    const count = try s.read(u32);
    const records = try s.read_array(VariationSelectorRecord, count);
    return .{
        .records = records,
        .data = data,
    };
}

/// Returns a glyph index for a code point.
///
/// Returns `null` when `code_point` is larger than `u16`.
pub fn glyph_index(
    self: Subtable,
    code_point: u21,
    variation: u32,
) ?GlyphVariationResult {
    _, const record = self.records.binary_search_by(
        variation,
        VariationSelectorRecord.compare,
    ) catch return null;

    if (record.default_uvs_offset) |offset_wrapper| {
        const offset = offset_wrapper[0];
        const data = utils.slice(self.data, offset) catch return null;
        var s = parser.Stream.new(data);
        const count = s.read(u32) catch return null;
        const ranges = s.read_array(UnicodeRangeRecord, count) catch return null;

        var iter = ranges.iterator();
        while (iter.next()) |range|
            if (range.contains(code_point))
                return .use_default;
    }

    if (record.non_default_uvs_offset) |offset_wrapper| {
        const offset = offset_wrapper[0];
        const data = utils.slice(self.data, offset) catch return null;
        var s = parser.Stream.new(data);
        const count = s.read(u32) catch return null;
        const uvs_mappings = s.read_array(UVSMappingRecord, count) catch return null;

        _, const mapping = uvs_mappings.binary_search_by(
            code_point,
            UVSMappingRecord.compare,
        ) catch return null;

        return .{ .found = mapping.glyph_id };
    }

    return null;
}

const VariationSelectorRecord = struct {
    var_selector: u24,
    default_uvs_offset: ?parser.Offset32,
    non_default_uvs_offset: ?parser.Offset32,

    fn compare(
        self: VariationSelectorRecord,
        variation: u32,
    ) std.math.Order {
        return std.math.order(self.var_selector, variation);
    }

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 11;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// A result of a variation glyph mapping.
pub const GlyphVariationResult = union(enum) {
    /// Glyph was found in the variation encoding table.
    found: lib.GlyphId,
    /// Glyph should be looked in other, non-variation tables.
    ///
    /// Basically, you should use `Encoding.glyph_index` or `Face.glyph_index`
    /// in this case.
    use_default,
};

const UnicodeRangeRecord = struct {
    start_unicode_value: u24,
    additional_count: u8,

    fn contains(
        self: UnicodeRangeRecord,
        c: u32, // [ARs] maybe should be u21?
    ) bool {
        // Never overflows, since `start_unicode_value` is actually u24.
        const end: u32 = @as(u32, self.start_unicode_value) + self.additional_count;
        return c >= self.start_unicode_value and c <= end;
    }

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 4;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

const UVSMappingRecord = struct {
    unicode_value: u24,
    glyph_id: lib.GlyphId,

    fn compare(
        self: UVSMappingRecord,
        code_point: u21,
    ) std.math.Order {
        return std.math.order(self.unicode_value, code_point);
    }

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 5;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};
