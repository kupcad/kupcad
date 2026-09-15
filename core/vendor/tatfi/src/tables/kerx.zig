//! An [Extended Kerning Table](
//! https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6kerx.html) implementation.

// [RazrFalcon]
// TODO: find a way to test this table
// This table is basically untested because it uses Apple's State Tables
// and I have no idea how to generate them.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const aat = @import("../aat.zig");

const kern = lib.tables.kern;

const HEADER_SIZE: usize = 12;

const Table = @This();

/// A list of subtables.
subtables: Subtables,

/// Parses a table from raw data.
///
/// `number_of_glyphs` is from the `maxp` table.
pub fn parse(
    number_of_glyphs: u16,
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);
    s.skip(u16); // version
    s.skip(u16); // padding
    const number_of_tables = try s.read(u32);

    return .{
        .subtables = .{
            .number_of_glyphs = number_of_glyphs,
            .number_of_tables = number_of_tables,
            .data = try s.tail(),
        },
    };
}

/// A list of extended kerning subtables.
///
/// The internal data layout is not designed for random access,
/// therefore we're not providing the `get()` method and only an iterator.
pub const Subtables = struct {
    /// The number of glyphs from the `maxp` table.
    number_of_glyphs: u16, // nonzero
    /// The total number of tables.
    number_of_tables: u32,
    /// Actual data. Starts right after the `kerx` header.
    data: []const u8,

    pub fn iterator(
        self: Subtables,
    ) Iterator {
        return .{
            .number_of_glyphs = self.number_of_glyphs,
            .number_of_tables = self.number_of_tables,
            .stream = .new(self.data),
        };
    }

    pub const Iterator = struct {
        /// The number of glyphs from the `maxp` table.
        number_of_glyphs: u16, // nonzero
        /// The current table index.
        table_index: u32 = 0,
        /// The total number of tables.
        number_of_tables: u32,
        /// Actual data. Starts right after the `kerx` header.
        stream: parser.Stream,

        pub fn next(
            self: *Iterator,
        ) ?Subtable {
            if (self.table_index == self.number_of_tables) return null;
            if (self.stream.at_end()) return null;

            return self.next_impl() catch return null;
        }

        fn next_impl(
            self: *Iterator,
        ) parser.Error!Subtable {
            const s = &self.stream;

            const table_len = try s.read(u32);
            const coverage = try s.read(Coverage);
            s.skip(u16); // unused
            const raw_format = try s.read(u8);
            const tuple_count = try s.read(u32);

            // Subtract the header size.
            const data_len = try std.math.sub(usize, table_len, HEADER_SIZE);
            const data = try s.read_bytes(data_len);

            const format: Format = switch (raw_format) {
                0 => .{ .format0 = try .parse(data) },
                1 => .{ .format1 = try .parse(self.number_of_glyphs, data) },
                2 => .{ .format2 = .{ .data = data } },
                4 => .{ .format4 = try .parse(self.number_of_glyphs, data) },
                6 => .{ .format6 = .parse(self.number_of_glyphs, data) },

                // Unknown format.
                else => return error.ParseFail,
            };

            self.table_index += 1;

            return .{
                .horizontal = coverage.direction == .horizontal,
                .variable = coverage.is_variable,
                .has_cross_stream = coverage.has_cross_stream,
                .has_state_machine = raw_format == 1 or raw_format == 4,
                .tuple_count = tuple_count,
                .format = format,
            };
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
    /// In this case `glyphs_kerning()` will return `None`.
    has_state_machine: bool,
    /// The tuple count.
    ///
    /// This value is only used with variation fonts and should be 0 for all other fonts.
    tuple_count: u32,
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
        switch (self.format) {
            .format1, .format4 => return null,
            inline else => |subtable| return subtable.glyphs_kerning(left, right),
        }
    }
};

const Coverage = packed struct(u8) {
    _0: u5 = 0,
    is_variable: bool,
    has_cross_stream: bool,
    direction: enum(u1) { horizontal = 0, vertical = 1 },
};

pub const Format = union(enum) {
    format0: Subtable0,
    format1: Subtable1,
    format2: Subtable2,
    format4: Subtable4,
    format6: Subtable6,
};

/// A format 0 subtable.
///
/// Ordered List of Kerning Pairs.
///
/// The same as in `kern`, but uses `LazyArray32` instead of `LazyArray16`.
pub const Subtable0 = struct {
    /// A list of kerning pairs.
    pairs: parser.LazyArray32(kern.KerningPair),

    /// Parses a subtable from raw data.
    fn parse(
        data: []const u8,
    ) parser.Error!Subtable0 {
        var s = parser.Stream.new(data);
        const number_of_pairs = try s.read(u32);
        s.advance(12); // search_range (u32) + entry_selector (u32) + range_shift (u32)
        const pairs = try s.read_array(kern.KerningPair, number_of_pairs);
        return .{ .pairs = pairs };
    }

    /// Returns kerning for a pair of glyphs.
    pub fn glyphs_kerning(
        self: Subtable0,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) ?i16 {
        const func = struct {
            fn func(v: kern.KerningPair, n: u32) std.math.Order {
                return std.math.order(v.pair, n);
            }
        }.func;

        const needle = @as(u32, left[0]) << 16 | @as(u32, right[0]);
        // self.pairs.binary_search_by(|v| v.pair.cmp(&needle)).map(|(_, v)| v.value)
        _, const ret = self.pairs.binary_search_by(needle, func) catch return null;
        return ret.value;
    }
};

/// A state machine entry.
pub const EntryData = struct {
    /// An action index.
    u16,
};

/// A format 1 subtable.
///
/// State Table for Contextual Kerning.
pub const Subtable1 = struct {
    /// A state table.
    state_table: aat.ExtendedStateTable(EntryData),
    actions_data: []const u8,

    fn parse(
        number_of_glyphs: u16,
        data: []const u8,
    ) parser.Error!Subtable1 {
        var s = parser.Stream.new(data);
        const state_table: aat.ExtendedStateTable(EntryData) = try .parse(number_of_glyphs, &s);

        // Actions offset is right after the state table.
        const actions_offset = try s.read(parser.Offset32);
        // Actions offset is from the start of the state table and not from the start of subtable.
        // And since we don't know the length of the actions data,
        // simply store all the data after the offset.
        const actions_data = try utils.slice(data, actions_offset[0]);

        return .{
            .state_table = state_table,
            .actions_data = actions_data,
        };
    }

    /// Returns kerning at action index.
    pub fn glyphs_kerning(
        self: Subtable1,
        action_index: u16,
    ) ?i16 {
        var s = parser.Stream.new(self.actions_data);
        return s.read_at(i16, action_index * parser.size_of(i16)) catch null;
    }
};

/// A format 2 subtable.
///
/// Simple n x m Array of Kerning Values.
///
/// The same as in `kern`, but uses 32bit offsets instead of 16bit one.
pub const Subtable2 = struct {
    data: []const u8, // [RazrFalcon] TODO: parse actual structure

    /// Returns kerning for a pair of glyphs.
    pub fn glyphs_kerning(
        self: Subtable2,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) ?i16 {
        return self.glyphs_kerning_inner(left, right) catch null;
    }

    pub fn glyphs_kerning_inner(
        self: Subtable2,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) parser.Error!i16 {
        var s = parser.Stream.new(self.data);
        s.skip(u32); // row_width

        // Offsets are from beginning of the subtable and not from the `data` start,
        // so we have to subtract the header.
        const left_hand_table_offset = try std.math.sub(usize, (try s.read(parser.Offset32))[0], HEADER_SIZE);
        const right_hand_table_offset = try std.math.sub(usize, (try s.read(parser.Offset32))[0], HEADER_SIZE);
        const array_offset = try std.math.sub(usize, (try s.read(parser.Offset32))[0], HEADER_SIZE);

        // 'The array can be indexed by completing the left-hand and right-hand class mappings,
        // adding the class values to the address of the subtable,
        // and fetching the kerning value to which the new address points.'

        const left_class = try kern.get_format2_class(left[0], left_hand_table_offset, self.data);
        const right_class = try kern.get_format2_class(right[0], right_hand_table_offset, self.data);

        // 'Values within the left-hand offset table should not be less than the kerning array offset.'
        if (left_class < array_offset) return error.ParseFail;

        // Classes are already premultiplied, so we only need to sum them.
        const index = @as(usize, left_class) + @as(usize, right_class);
        const value_offset = try std.math.sub(usize, index, HEADER_SIZE);

        return try s.read_at(i16, value_offset);
    }
};

/// A format 4 subtable.
///
/// State Table for Control Point/Anchor Point Positioning.
///
/// Note: I [RazrFalcon] wasn't able to find any fonts that actually use
/// `ControlPointActions` and/or `ControlPointCoordinateActions`,
/// therefore only `AnchorPointActions` is supported.
pub const Subtable4 = struct {
    /// A state table.
    state_table: aat.ExtendedStateTable(EntryData),
    /// Anchor points.
    anchor_points: AnchorPoints,

    /// A container of Anchor Points used by `Subtable4`.
    pub const AnchorPoints = struct {
        data: []const u8,

        /// Returns a mark and current anchor points at action index.
        pub fn get(
            self: AnchorPoints,
            action_index: u16,
        ) ?struct { u16, u16 } {
            // Each action contains two 16-bit fields, so we must
            // double the action_index to get the correct offset here.
            const offset = action_index * parser.size_of(u16) * 2;
            var s = parser.Stream.new_at(self.data, offset) catch return null;
            return .{
                s.read(u16) catch return null,
                s.read(u16) catch return null,
            };
        }
    };

    fn parse(
        number_of_glyphs: u16,
        data: []const u8,
    ) parser.Error!Subtable4 {
        var s = parser.Stream.new(data);
        const state_table: aat.ExtendedStateTable(EntryData) = try .parse(number_of_glyphs, &s);

        const flags = try s.read(packed struct(u32) {
            points_offset: u24, // 0x00FFFFFF
            _0: u6 = 0,
            action_type: u2, // 0xC0000000 >> 30
        });

        // We support only Anchor Point Actions.
        if (flags.action_type != 1) return error.ParseFail;

        return .{
            .state_table = state_table,
            .anchor_points = .{ .data = try utils.slice(data, flags.points_offset) },
        };
    }
};

/// A format 6 subtable.
///
/// Simple Index-based n x m Array of Kerning Values.
pub const Subtable6 = struct {
    data: []const u8,
    number_of_glyphs: u16,

    // TODO: parse actual structure
    fn parse(
        number_of_glyphs: u16,
        data: []const u8,
    ) Subtable6 {
        return .{ .number_of_glyphs = number_of_glyphs, .data = data };
    }

    /// Returns kerning for a pair of glyphs.
    pub fn glyphs_kerning(
        self: Subtable6,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) ?i16 {
        return self.glyphs_kerning_inner(left, right) catch null;
    }

    fn glyphs_kerning_inner(
        self: Subtable6,
        left: lib.GlyphId,
        right: lib.GlyphId,
    ) parser.Error!i16 {
        var s = parser.Stream.new(self.data);
        const has_long_values = (try s.read(packed struct(u32) {
            has_long_values: bool, // 0x00000001
            _0: u31,
        })).has_long_values;

        s.skip(u16); // row_count
        s.skip(u16); // col_count

        const row_index_table_offset = try std.math.sub(usize, (try s.read(parser.Offset32))[0], HEADER_SIZE);
        const column_index_table_offset = try std.math.sub(usize, (try s.read(parser.Offset32))[0], HEADER_SIZE);
        const kerning_array_offset = try std.math.sub(usize, (try s.read(parser.Offset32))[0], HEADER_SIZE);
        const kerning_vector_offset = try std.math.sub(usize, (try s.read(parser.Offset32))[0], HEADER_SIZE);

        const row_index_table_data = try utils.slice(self.data, row_index_table_offset);
        const column_index_table_data = try utils.slice(self.data, column_index_table_offset);
        const kerning_array_data = try utils.slice(self.data, kerning_array_offset);
        const kerning_vector_data = try utils.slice(self.data, kerning_vector_offset);

        if (has_long_values) {
            const l: u32 = l: {
                const p = try aat.Lookup.parse(self.number_of_glyphs, row_index_table_data);
                break :l p.value(left) orelse 0;
            };
            const r: u32 = l: {
                const p = try aat.Lookup.parse(self.number_of_glyphs, column_index_table_data);
                break :l p.value(right) orelse 0;
            };

            const array_offset = try std.math.mul(usize, parser.size_of(i32), @as(usize, l) + r);

            var kerning_array_stream = parser.Stream.new(kerning_array_data);
            const vector_offset = try kerning_array_stream.read_at(u32, array_offset);

            var kerning_vector_stream = parser.Stream.new(kerning_vector_data);
            return try kerning_vector_stream.read_at(i16, vector_offset);
        } else {
            const l: u16 = l: {
                const p = try aat.Lookup.parse(self.number_of_glyphs, row_index_table_data);
                break :l p.value(left) orelse 0;
            };
            const r: u16 = l: {
                const p = try aat.Lookup.parse(self.number_of_glyphs, column_index_table_data);
                break :l p.value(right) orelse 0;
            };

            const array_offset = try std.math.mul(usize, parser.size_of(i16), @as(usize, l) + r);

            var kerning_array_stream = parser.Stream.new(kerning_array_data);
            const vector_offset = try kerning_array_stream.read_at(u16, array_offset);

            var kerning_vector_stream = parser.Stream.new(kerning_vector_data);
            return try kerning_vector_stream.read_at(i16, vector_offset);
        }
    }
};
