//! A collection of [Apple Advanced Typography](
//! https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6AATIntro.html)
//! related types.

const std = @import("std");
const lib = @import("lib.zig");
const parser = @import("parser.zig");
const utils = @import("utils.zig");

/// Predefined states.
pub const predefined_state = struct {
    pub const START_OF_TEXT: u16 = 0;
};

/// Predefined classes.
///
/// Search for _Class Code_ in [Apple Advanced Typography Font Tables](
/// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6Tables.html).
pub const predefined_class = struct {
    pub const END_OF_TEXT: u8 = 0;
    pub const OUT_OF_BOUNDS: u8 = 1;
    pub const DELETED_GLYPH: u8 = 2;
};

/// A [lookup table](
/// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6Tables.html).
///
/// u32 values in Format10 tables will be truncated to u16.
/// u64 values in Format10 tables are not supported.
pub const Lookup = struct {
    data: LookupInner,

    /// Parses a lookup table from raw data.
    ///
    /// `number_of_glyphs` is from the `maxp` table.
    pub fn parse(
        number_of_glyphs: u16,
        data: []const u8,
    ) parser.Error!Lookup {
        return .{
            .data = try .parse(number_of_glyphs, data),
        };
    }

    /// Returns a value associated with the specified glyph.
    pub fn value(
        self: Lookup,
        glyph_id: lib.GlyphId,
    ) ?u16 {
        return self.data.value(glyph_id);
    }
};

const LookupInner = union(enum) {
    format1: parser.LazyArray16(u16),
    format2: BinarySearchTable(LookupSegment),
    format4: struct { BinarySearchTable(LookupSegment), []const u8 },
    format6: BinarySearchTable(LookupSingle),
    format8: struct { first_glyph: u16, values: parser.LazyArray16(u16) },
    format10: struct {
        value_size: u16,
        first_glyph: u16,
        glyph_count: u16,
        data: []const u8,
    },

    fn parse(
        number_of_glyphs: u16,
        data: []const u8,
    ) parser.Error!LookupInner {
        var s = parser.Stream.new(data);
        const format = try s.read(u16);

        switch (format) {
            0 => {
                const values = try s.read_array(u16, number_of_glyphs);
                return .{ .format1 = values };
            },
            2 => {
                const bsearch: BinarySearchTable(LookupSegment) = try .parse(try s.tail());
                return .{ .format2 = bsearch };
            },
            4 => {
                const bsearch: BinarySearchTable(LookupSegment) = try .parse(try s.tail());
                return .{ .format4 = .{ bsearch, data } };
            },
            6 => {
                const bsearch: BinarySearchTable(LookupSingle) = try .parse(try s.tail());
                return .{ .format6 = bsearch };
            },
            8 => {
                const first_glyph = try s.read(u16);
                const glyph_count = try s.read(u16);
                const values = try s.read_array(u16, glyph_count);
                return .{ .format8 = .{
                    .first_glyph = first_glyph,
                    .values = values,
                } };
            },
            10 => {
                const value_size = try s.read(u16);
                const first_glyph = try s.read(u16);
                const glyph_count = try s.read(u16);
                return .{ .format10 = .{
                    .value_size = value_size,
                    .first_glyph = first_glyph,
                    .glyph_count = glyph_count,
                    .data = try s.tail(),
                } };
            },
            else => return error.ParseFail,
        }
    }

    fn value(
        self: LookupInner,
        glyph_id: lib.GlyphId,
    ) ?u16 {
        switch (self) {
            .format1 => |values| return values.get(glyph_id[0]),
            inline .format2, .format6 => |bsearch| {
                const v = bsearch.get(glyph_id) orelse return null;
                return v.value;
            },
            .format4 => |f| {
                const bsearch, const data = f;

                // In format 4, LookupSegment contains an offset to a list of u16 values.
                // One value for each glyph in the LookupSegment range.
                const segment = bsearch.get(glyph_id) orelse return null;
                const index = std.math.sub(u16, glyph_id[0], segment.first_glyph) catch return null;
                const offset = @as(usize, segment.value) + parser.size_of(u16) * @as(usize, index);

                var s = parser.Stream.new_at(data, offset) catch return null;
                return s.read(u16) catch null;
            },
            .format8 => |f| {
                const first_glyph = f.first_glyph;
                const values = f.values;

                const index = std.math.sub(u16, glyph_id[0], first_glyph) catch return null;
                return values.get(index);
            },
            .format10 => |f| {
                const value_size = f.value_size;
                const first_glyph = f.first_glyph;
                const glyph_count = f.glyph_count;
                const data = f.data;

                const index = std.math.sub(u16, glyph_id[0], first_glyph) catch return null;
                var s = parser.Stream.new(data);
                switch (value_size) {
                    1 => {
                        const array = s.read_array(u8, glyph_count) catch return null;
                        return array.get(index) orelse null;
                    },
                    2 => {
                        const array = s.read_array(u16, glyph_count) catch return null;
                        return array.get(index);
                    },
                    4 => {
                        // [RazrFalcon] TODO: we should return u32 here, but this is not supported yet
                        const array = s.read_array(u32, glyph_count) catch return null;
                        const ret = array.get(index) orelse return null;
                        return @truncate(ret);
                    },
                    else => return null,
                }
            },
        }
    }
};

/// A binary searching table as defined at
/// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6Tables.html
fn BinarySearchTable(T: type) type {
    return struct {
        values: parser.LazyArray16(T),
        len: u16, // NonZeroU16, // values length excluding termination segment

        const Self = @This();

        fn parse(
            data: []const u8,
        ) parser.Error!Self {
            var s = parser.Stream.new(data);
            const segment_size = try s.read(u16);
            const number_of_segments = try s.read(u16);
            s.advance(6); // search_range + entry_selector + range_shift

            if (segment_size != T.FromData.SIZE) return error.ParseFail;
            if (number_of_segments == 0) return error.ParseFail;

            const values = try s.read_array(T, number_of_segments);

            // 'The number of termination values that need to be included is table-specific.
            // The value that indicates binary search termination is 0xFFFF.'
            const last_value = values.last() orelse return error.ParseFail;
            const len = if (T.is_termination(last_value))
                try std.math.sub(u16, number_of_segments, 1)
            else
                number_of_segments;
            if (len == 0) return error.ParseFail;

            return .{
                .len = len,
                .values = values,
            };
        }

        fn get(
            self: Self,
            key: lib.GlyphId,
        ) ?T {
            var min: isize = 0;
            var max: isize = self.len - 1;
            while (min <= max) {
                const mid = @divFloor(min + max, 2);
                const v = self.values.get(
                    std.math.cast(u16, mid) orelse return null,
                ) orelse return null;
                switch (v.contains(key)) {
                    .lt => max = mid - 1,
                    .gt => min = mid + 1,
                    .eq => return v,
                }
            }

            return null;
        }
    };
}

pub const LookupSegment = struct {
    last_glyph: u16,
    first_glyph: u16,
    value: u16,

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

    // for trait BinarySearchValue:FromData
    fn is_termination(
        self: Self,
    ) bool {
        return self.last_glyph == 0xFFFF and self.first_glyph == 0xFFFF;
    }

    fn contains(
        self: Self,
        id: lib.GlyphId,
    ) std.math.Order {
        return if (id[0] < self.first_glyph)
            .lt
        else if (id[0] <= self.last_glyph)
            .eq
        else
            .gt;
    }
};

pub const LookupSingle = struct {
    glyph: u16,
    value: u16,

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

    // for trait BinarySearchValue:FromData
    fn is_termination(
        self: Self,
    ) bool {
        return self.glyph == 0xFFFF;
    }

    fn contains(
        self: Self,
        id: lib.GlyphId,
    ) std.math.Order {
        return std.math.order(id[0], self.glyph);
    }
};

/// A [State Table](
/// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6Tables.html).
///
/// Also called `STHeader`.
///
/// Currently used by `kern` table.
pub const StateTable = struct {
    number_of_classes: u16,
    first_glyph: lib.GlyphId,
    class_table: []const u8,
    state_array_offset: u16,
    state_array: []const u8,
    entry_table: []const u8,
    actions: []const u8,

    pub fn parse(
        data: []const u8,
    ) parser.Error!StateTable {
        var s = parser.Stream.new(data);

        const number_of_classes = try s.read(u16);
        // Note that in format1 subtable, offsets are not from the subtable start,
        // but from subtable start + `header_size`.
        // So there is not need to subtract the `header_size`.
        const class_table_offset: usize = (try s.read(parser.Offset16))[0];
        const state_array_offset: usize = (try s.read(parser.Offset16))[0];
        const entry_table_offset: usize = (try s.read(parser.Offset16))[0];
        // Ignore `values_offset` since we don't use it.

        // Parse class subtable.
        s.offset = class_table_offset;
        const first_glyph = try s.read(lib.GlyphId);
        const number_of_glyphs = try s.read(u16);
        // The class table contains u8, so it's easier to use just a slice
        // instead of a LazyArray.
        const class_table = try s.read_bytes(number_of_glyphs);

        return .{
            .number_of_classes = number_of_classes,
            .first_glyph = first_glyph,
            .class_table = class_table,
            .state_array_offset = @truncate(state_array_offset),
            // We don't know the actual data size and it's kinda expensive to calculate.
            // So we are simply storing all the data past the offset.
            // Despite the fact that they may overlap.
            .state_array = try utils.slice(data, state_array_offset),
            .entry_table = try utils.slice(data, entry_table_offset),
            // `ValueOffset` defines an offset from the start of the subtable data.
            // We do not check that the provided offset is actually after `values_offset`.
            .actions = data,
        };
    }

    /// Returns a glyph class.
    pub fn class(
        self: StateTable,
        glyph_id: lib.GlyphId,
    ) ?u8 {
        if (glyph_id[0] == 0xFFFF)
            return predefined_class.DELETED_GLYPH;

        const idx = std.math.sub(u16, glyph_id[0], self.first_glyph[0]) catch return null;
        if (idx >= self.class_table.len) return null;
        return self.class_table[idx];
    }

    /// Returns a class entry.
    pub fn entry(
        self: StateTable,
        state: u16,
        class_needle: u8,
    ) ?StateEntry {
        var predef_class = class_needle;
        if (predef_class >= self.number_of_classes)
            predef_class = predefined_class.OUT_OF_BOUNDS;

        const entry_idx = i: {
            const idx = @as(usize, state) * @as(usize, self.number_of_classes) + @as(usize, predef_class);
            if (idx >= self.state_array.len) return null;
            break :i self.state_array[idx];
        };

        var s = parser.Stream.new_at(self.entry_table, entry_idx * @sizeOf(StateEntry)) catch return null;
        return s.read(StateEntry) catch null;
    }

    /// Returns kerning at offset.
    pub fn kerning(
        self: StateTable,
        offset: ValueOffset,
    ) ?i16 {
        var s = parser.Stream.new_at(self.actions, @intFromEnum(offset)) catch return null;
        return s.read(i16) catch null;
    }

    /// Produces a new state.
    pub fn new_state(
        self: StateTable,
        state: u16,
    ) u16 {
        const n = @divFloor(
            (@as(i32, state) - @as(i32, self.state_array_offset)),
            @as(i32, self.number_of_classes),
        );

        return std.math.cast(u16, n) orelse 0;
    }
};

/// An [Extended State Table](
/// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6Tables.html).
///
/// Also called `STXHeader`.
///
/// Currently used by `kerx` and `morx` tables.
pub fn ExtendedStateTable(T: type) type {
    return struct {
        number_of_classes: u32,
        lookup: Lookup,
        state_array: []const u8,
        entry_table: []const u8,

        const Self = @This();

        /// Parses an Extended State Table from a stream.
        ///
        /// `number_of_glyphs` is from the `maxp` table.
        pub fn parse(
            number_of_glyphs: u16,
            s: *parser.Stream,
        ) parser.Error!Self {
            const data = try s.tail();

            const number_of_classes = try s.read(u32);
            // Note that offsets are not from the subtable start,
            // but from subtable start + `header_size`.
            // So there is not need to subtract the `header_size`.
            const lookup_table_offset = (try s.read(parser.Offset32))[0];
            const state_array_offset = (try s.read(parser.Offset32))[0];
            const entry_table_offset = (try s.read(parser.Offset32))[0];

            return .{
                .number_of_classes = number_of_classes,
                .lookup = try .parse(number_of_glyphs, try utils.slice(data, lookup_table_offset)),
                // We don't know the actual data size and it's kinda expensive to calculate.
                // So we are simply storing all the data past the offset.
                // Despite the fact that they may overlap.
                .state_array = try utils.slice(data, state_array_offset),
                .entry_table = try utils.slice(data, entry_table_offset),
            };
        }

        /// Returns a glyph class.
        pub fn class(
            self: Self,
            glyph_id: lib.GlyphId,
        ) ?u16 {
            return if (glyph_id[0] == 0xFFFF)
                predefined_class.DELETED_GLYPH
            else
                self.lookup.value(glyph_id);
        }

        /// Returns a class entry.
        pub fn entry(
            self: Self,
            state: u16,
            class_needle: u16,
        ) ?GenericStateEntry(T) {
            var predef_class = class_needle;
            if (predef_class >= self.number_of_classes)
                predef_class = predefined_class.OUT_OF_BOUNDS;

            const state_idx = @as(usize, state) * @as(usize, self.number_of_classes) + @as(usize, predef_class);

            const entry_idx = i: {
                var s = parser.Stream.new_at(self.state_array, state_idx * parser.size_of(u16)) catch return null;
                break :i s.read(u16) catch return null;
            };
            var s = parser.Stream.new_at(self.entry_table, entry_idx * parser.size_of(GenericStateEntry(T))) catch return null;
            return s.read(GenericStateEntry(T)) catch null;
        }
    };
}

pub const StateEntry = GenericStateEntry(void);

/// A State Table entry.
///
/// Used by legacy and extended tables.
pub fn GenericStateEntry(T: type) type {
    return struct {
        /// A new state.
        new_state: u16,
        /// Entry flags.
        flags: u16,
        /// Additional data.
        ///
        /// Use `void` if no data expected.
        extra: T,

        const Self = @This();

        pub const FromData = struct {
            // [ARS] impl of FromData trait
            pub const SIZE: usize = 4 + parser.size_of(T);

            pub fn parse(
                data: *const [SIZE]u8,
            ) parser.Error!Self {
                return try parser.parse_struct_from_data(Self, data);
            }
        };

        // [ARS] TODO: change into a packed struct somehow.

        /// Checks that entry has an offset.
        pub fn has_offset(self: Self) bool {
            return self.flags & 0x3FFF != 0;
        }

        /// Returns a value offset.
        ///
        /// Used by kern::format1 subtable.
        pub fn value_offset(self: Self) ValueOffset {
            return @enumFromInt(self.flags & 0x3FFF);
        }

        /// If set, reset the kerning data (clear the stack).
        pub fn has_reset(self: Self) bool {
            return self.flags & 0x2000 != 0;
        }

        /// If set, advance to the next glyph before going to the new state.
        pub fn has_advance(self: Self) bool {
            return self.flags & 0x4000 == 0;
        }

        /// If set, push this glyph on the kerning stack.
        pub fn has_push(self: Self) bool {
            return self.flags & 0x8000 != 0;
        }

        /// If set, remember this glyph as the marked glyph.
        ///
        /// Used by kerx::format4 subtable.
        ///
        /// Yes, the same as `has_push`.
        pub fn has_mark(self: Self) bool {
            return self.flags & 0x8000 != 0;
        }
    };
}

/// A type-safe wrapper for a kerning value offset.
pub const ValueOffset = enum(u16) {
    _,

    /// Returns the next offset.
    ///
    /// After reaching u16::MAX will start from 0.
    pub fn next(self: ValueOffset) ValueOffset {
        const ret: u16 = @intFromEnum(self) +% 2; // size of u16.
        return @enumFromInt(ret);
    }
};
