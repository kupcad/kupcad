//!
//! A [Kerning Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/kern) implementation.
//!
//! Supports both
//! [OpenType](https://docs.microsoft.com/en-us/typography/opentype/spec/kern)
//! and
//! [Apple Advanced Typography](https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6kern.html)
//! variants.
//!
//! Since there is no single correct way to process a kerning data,
//! we have to provide an access to kerning subtables, so a caller can implement
//! a kerning algorithm manually.
//! But we still try to keep the API as high-level as possible.

const std = @import("std");
const cfg = @import("config");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const aat = @import("../aat.zig");

const Table = @This();

/// A list of subtables.
subtables: Subtables,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    // The `kern` table has two variants: OpenType and Apple.
    // And they both have different headers.
    // There are no robust way to distinguish them, so we have to guess.
    //
    // The OpenType one has the first two bytes (UInt16) as a version set to 0.
    // While Apple one has the first four bytes (Fixed) set to 1.0
    // So the first two bytes in case of an OpenType format will be 0x0000
    // and 0x0001 in case of an Apple format.
    var s = parser.Stream.new(data);

    const version = try s.read(u16);

    const subtables: Subtables = if (version == 0) .{
        .is_aat = false,
        .count = try s.read(u16),
        .data = try s.tail(),
    } else e: {
        s.skip(u16); // Skip the second part of u32 version.
        // Note that AAT stores the number of tables as u32 and not as u16.
        break :e .{
            .is_aat = true,
            .count = try s.read(u32),
            .data = try s.tail(),
        };
    };

    return .{ .subtables = subtables };
}

/// A list of subtables.
///
/// The internal data layout is not designed for random access,
/// therefore we're not providing the `get()` method and only an iterator.
pub const Subtables = struct {
    /// Indicates an Apple Advanced Typography format.
    is_aat: bool,
    /// The total number of tables.
    count: u32,
    /// Actual data. Starts right after the `kern` header.
    data: []const u8,

    pub fn iterator(
        self: *const Subtables,
    ) Iterator {
        return .{
            .is_aat = self.is_aat,
            .number_of_tables = self.count,
            .stream = .new(self.data),
        };
    }

    pub const Iterator = struct {
        /// Indicates an Apple Advanced Typography format.
        is_aat: bool,
        /// The current table index,
        table_index: u32 = 0,
        /// The total number of tables.
        number_of_tables: u32,
        /// Actual data. Starts right after `kern` header.
        stream: parser.Stream,

        pub fn next(
            self: *Iterator,
        ) ?Subtable {
            if (self.table_index == self.number_of_tables) return null;
            if (self.stream.at_end()) return null;

            if (self.is_aat) {
                const HEADER_SIZE: u8 = 8;

                const table_len = self.stream.read(u32) catch return null;
                const coverage = self.stream.read(AATCoverage) catch return null;
                const format_id = self.stream.read(u8) catch return null;
                self.stream.skip(u16); // variation tuple index

                if (format_id > 3) return null; // Unknown format.

                // Subtract the header size.
                const data_len = std.math.sub(usize, table_len, HEADER_SIZE) catch return null;
                const data = self.stream.read_bytes(data_len) catch return null;

                const format: Format = switch (format_id) {
                    0 => .{ .format0 = Subtable0.parse(data) catch return null },
                    1 => .{ .format1 = if (cfg.apple_layout) aat.StateTable.parse(data) catch return null },
                    2 => .{ .format2 = Subtable2.parse(HEADER_SIZE, data) catch return null },
                    3 => .{ .format3 = Subtable3.parse(data) catch return null },
                    else => unreachable, // checked earlier
                };

                return .{
                    .horizontal = coverage.direction == .horizontal,
                    .variable = coverage.is_variable,
                    .has_cross_stream = coverage.is_cross_stream,
                    .has_state_machine = format_id == 1,
                    .format = format,
                };
            } else {
                const HEADER_SIZE: u8 = 6;

                self.stream.skip(u16); // version
                const table_len = self.stream.read(u16) catch return null;
                // In the OpenType variant, `format` comes first.
                const format_id = self.stream.read(u8) catch return null;
                const coverage = self.stream.read(OTCoverage) catch return null;

                if (format_id != 0 and format_id != 2) return null; // Unknown format.

                const data_len = if (self.number_of_tables == 1)
                    // An OpenType `kern` table with just one subtable is a special case.
                    // The `table_len` property is mainly required to jump to the next subtable,
                    // but if there is only one subtable, this property can be ignored.
                    // This is abused by some fonts, to get around the `u16` size limit.
                    (self.stream.tail() catch return null).len
                else
                    // Subtract the header size.
                    std.math.sub(usize, table_len, HEADER_SIZE) catch return null;

                const data = self.stream.read_bytes(data_len) catch return null;
                const format: Format = switch (format_id) {
                    0 => .{ .format0 = Subtable0.parse(data) catch return null },
                    2 => .{ .format2 = Subtable2.parse(HEADER_SIZE, data) catch return null },
                    else => unreachable, // checked earlier
                };
                return .{
                    .horizontal = coverage.direction == .horizontal,
                    .variable = false, // Only AAT supports it.
                    .has_cross_stream = coverage.has_cross_stream,
                    .has_state_machine = format_id == 1,
                    .format = format,
                };
            }
        }
    };
};

/// A kerning subtable.
pub const Subtable = struct {
    /// Indicates that subtable is for horizontal text.
    horizontal: bool,
    /// Indicates that subtable is variable.
    variable: bool,
    /// Indicates that subtable has a cross-stream values.
    has_cross_stream: bool,
    /// Indicates that subtable uses a state machine.
    ///
    /// In this case `glyphs_kerning()` will return `null`.
    has_state_machine: bool,
    /// Subtable format.
    format: Format,

    /// Returns kerning for a pair of glyphs.
    ///
    /// Returns `null` in case of state machine based subtable.
    pub fn glyphs_kerning(
        self: Subtable,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) ?i16 {
        return switch (self.format) {
            .format0 => |subtable| subtable.glyphs_kerning(left, right),
            .format2 => |subtable| subtable.glyphs_kerning(left, right),
            .format3 => |subtable| subtable.glyphs_kerning(left, right),
            else => null,
        };
    }
};

/// A kerning subtable format.
pub const Format = union(enum) {
    format0: Subtable0,
    format1: if (cfg.apple_layout) aat.StateTable else void,
    format2: Subtable2,
    format3: Subtable3,
};

/// A format 0 subtable.
///
/// Ordered List of Kerning Pairs.
pub const Subtable0 = struct {
    /// A list of kerning pairs.
    pairs: parser.LazyArray16(KerningPair),

    /// Parses a subtable from raw data.
    pub fn parse(
        data: []const u8,
    ) parser.Error!Subtable0 {
        var s = parser.Stream.new(data);
        const number_of_pairs = try s.read(u16);
        s.advance(6); // search_range (u16) + entry_selector (u16) + range_shift (u16)
        const pairs = try s.read_array(KerningPair, number_of_pairs);
        return .{ .pairs = pairs };
    }

    /// Returns kerning for a pair of glyphs.
    pub fn glyphs_kerning(
        self: Subtable0,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) ?i16 {
        const func = struct {
            fn func(v: KerningPair, rhs: u32) std.math.Order {
                const lhs = v.pair;
                return std.math.order(lhs, rhs);
            }
        }.func;

        const needle = @as(u32, left[0]) << 16 | @as(u32, right[0]);
        _, const ret = self.pairs.binary_search_by(needle, func) catch return null;
        return ret.value;
    }
};

/// A kerning pair.
pub const KerningPair = struct {
    /// Glyphs pair.
    ///
    /// In the kern table spec, a kerning pair is stored as two u16,
    /// but we are using one u32, so we can binary search it directly.
    pair: u32,
    /// Kerning value.
    value: i16,

    /// Returns left glyph ID.
    pub inline fn left(self: KerningPair) lib.GlyphId {
        return .{@truncate(self.pair >> 16)};
    }

    /// Returns right glyph ID.
    pub inline fn right(self: KerningPair) lib.GlyphId {
        return .{@truncate(self.pair)};
    }

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 6;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// A format 2 subtable.
///
/// Simple n x m Array of Kerning Values.
pub const Subtable2 = struct {
    // [RazrFalcon] TODO: parse actual structure
    data: []const u8,
    header_len: u8,

    /// Parses a subtable from raw data.
    pub fn parse(
        header_len: u8,
        data: []const u8,
    ) parser.Error!Subtable2 {
        return .{ .header_len = header_len, .data = data };
    }

    /// Returns kerning for a pair of glyphs.
    pub fn glyphs_kerning(
        self: Subtable2,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) ?i16 {
        return self.glyphs_kerning_inner(left, right) catch null;
    }

    inline fn glyphs_kerning_inner(
        self: Subtable2,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) parser.Error!i16 {
        var s = parser.Stream.new(self.data);
        s.skip(u16); // row_width

        // Offsets are from beginning of the subtable and not from the `data` start,
        // so we have to subtract the header.
        const header_len: usize = self.header_len;
        const left_hand_table_offset = lhto: {
            const lhs = try s.read(parser.Offset16);
            break :lhto try std.math.sub(usize, lhs[0], header_len);
        };
        const right_hand_table_offset = rhto: {
            const lhs = try s.read(parser.Offset16);
            break :rhto try std.math.sub(usize, lhs[0], header_len);
        };
        const array_offset = ao: {
            const lhs = try s.read(parser.Offset16);
            break :ao try std.math.sub(usize, lhs[0], header_len);
        };

        // 'The array can be indexed by completing the left-hand and right-hand class mappings,
        // adding the class values to the address of the subtable,
        // and fetching the kerning value to which the new address points.'

        const left_class = get_format2_class(left[0], left_hand_table_offset, self.data) catch 0;
        const right_class = get_format2_class(right[0], right_hand_table_offset, self.data) catch 0;

        // 'Values within the left-hand offset table should not be less than the kerning array offset.'
        if (left_class < array_offset) return error.ParseFail;

        // Classes are already premultiplied, so we only need to sum them.
        const index: usize = @as(usize, left_class) + right_class;
        const value_offset = try std.math.sub(usize, index, header_len);
        return try s.read_at(i16, value_offset);
    }
};

/// A format 3 subtable.
///
/// Simple n x m Array of Kerning Indices.
pub const Subtable3 = struct {
    // [RazrFalcon] TODO: parse actual structure
    data: []const u8,

    /// Parses a subtable from raw data.
    pub fn parse(
        data: []const u8,
    ) parser.Error!Subtable3 {
        return .{ .data = data };
    }

    /// Returns kerning for a pair of glyphs.
    pub fn glyphs_kerning(
        self: Subtable3,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) ?i16 {
        return self.glyphs_kerning_inner(left, right) catch null;
    }

    inline fn glyphs_kerning_inner(
        self: Subtable3,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) parser.Error!i16 {
        var s = parser.Stream.new(self.data);
        const glyph_count = try s.read(u16);
        const kerning_values_count = try s.read(u8);
        const left_hand_classes_count = try s.read(u8);
        const right_hand_classes_count = try s.read(u8);
        s.skip(u8); // reserved
        const indices_count = @as(u16, left_hand_classes_count) * right_hand_classes_count;

        const kerning_values = try s.read_array(i16, @as(u16, kerning_values_count));
        const left_hand_classes = try s.read_array(u8, glyph_count);
        const right_hand_classes = try s.read_array(u8, glyph_count);
        const indices = try s.read_array(u8, indices_count);

        const left_class = left_hand_classes.get(left[0]) orelse return error.ParseFail;
        const right_class = right_hand_classes.get(right[0]) orelse return error.ParseFail;

        if (left_class > left_hand_classes_count or
            right_class > right_hand_classes_count) return error.ParseFail;

        const index_index = @as(u16, left_class) * @as(u16, right_hand_classes_count) + @as(u16, right_class);
        const index = indices.get(index_index) orelse return error.ParseFail;

        return kerning_values.get(index) orelse return error.ParseFail;
    }
};

const AATCoverage = packed struct(u8) {
    _0: u5,
    is_variable: bool,
    is_cross_stream: bool,
    direction: enum(u1) { horizontal = 0, vertical = 1 },
};

const OTCoverage = packed struct(u8) {
    direction: enum(u1) { vertical = 0, horizontal = 1 },
    _0: u1,
    has_cross_stream: bool,
    _1: u5,
};

pub fn get_format2_class(
    glyph_id: u16,
    offset: usize,
    data: []const u8,
) parser.Error!u16 {
    var s = try parser.Stream.new_at(data, offset);
    const first_glyph = try s.read(u16);
    const index = try std.math.sub(u16, glyph_id, first_glyph);

    const number_of_classes = try s.read(u16);
    const classes = try s.read_array(u16, number_of_classes);
    return classes.get(index) orelse error.ParseFail;
}
