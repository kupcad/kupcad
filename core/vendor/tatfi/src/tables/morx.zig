//! An [Extended Glyph Metamorphosis Table](
//! https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6morx.html) implementation.
//!
//! Subtable Glyph Coverage used by morx v3 is not supported.

// [RazrFalcon]
// Note: We do not have tests for this table because it has a very complicated structure.
// Specifically, the State Machine Tables. I have no idea how to generate them.
// And all fonts that use this table are mainly Apple one, so we cannot use them for legal reasons.
//
// On the other hand, this table is tested indirectly by https://github.com/harfbuzz/rustybuzz
// And it has like 170 tests. Which is pretty good.
// Therefore after applying any changes to this table,
// you have to check that all rustybuzz tests are still passing.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const aat = @import("../aat.zig");

const Table = @This();

/// A list of metamorphosis chains.
chains: Chains,

/// Parses a table from raw data.
///
/// `number_of_glyphs` is from the `maxp` table.
pub fn parse(
    number_of_glyphs: u16,
    data: []const u8,
) parser.Error!Table {
    return .{ .chains = try .parse(number_of_glyphs, data) };
}

/// A list of metamorphosis chains.
///
/// The internal data layout is not designed for random access,
/// therefore we're not providing the `get()` method and only an iterator.
pub const Chains = struct {
    data: []const u8,
    count: u32,
    number_of_glyphs: u16, // nonzero

    fn parse(
        number_of_glyphs: u16,
        data: []const u8,
    ) parser.Error!Chains {
        var s = parser.Stream.new(data);

        s.skip(u16); // version
        s.skip(u16); // reserved
        const count = try s.read(u32);

        return .{
            .count = count,
            .data = try s.tail(),
            .number_of_glyphs = number_of_glyphs,
        };
    }

    pub fn iterator(
        self: Chains,
    ) Iterator {
        return .{
            .count = self.count,
            .stream = .new(self.data),
            .number_of_glyphs = self.number_of_glyphs,
        };
    }

    pub const Iterator = struct {
        index: u32 = 0,
        count: u32,
        stream: parser.Stream,
        number_of_glyphs: u16,

        pub fn next(
            self: *Iterator,
        ) ?Chain {
            if (self.index == self.count) return null;
            if (self.stream.at_end()) return null;
            return self.next_inner() catch null;
        }

        fn next_inner(
            self: *Iterator,
        ) parser.Error!Chain {
            const default_flags = try self.stream.read(u32);
            const len = try self.stream.read(u32);
            const features_count = try self.stream.read(u32);
            const subtables_count = try self.stream.read(u32);

            const features = try self.stream.read_array(Feature, features_count);

            const HEADER_LEN: usize = 16;

            const subtable_len = l: {
                const l = try std.math.sub(usize, len, HEADER_LEN);
                break :l try std.math.sub(usize, l, parser.size_of(Feature) * features_count);
            };
            const subtables_data = try self.stream.read_bytes(subtable_len);

            return .{
                .default_flags = default_flags,
                .features = features,
                .subtables = .{
                    .data = subtables_data,
                    .count = subtables_count,
                    .number_of_glyphs = self.number_of_glyphs,
                },
            };
        }
    };
};

pub const Chain = struct {
    /// Default chain features.
    default_flags: u32,
    /// A list of chain features.
    features: parser.LazyArray32(Feature),
    /// A list of chain subtables.
    subtables: Subtables,
};

/// The feature table is used to compute the sub-feature flags
/// for a list of requested features and settings.
pub const Feature = struct {
    /// The type of feature.
    kind: u16,
    /// The feature's setting (aka selector).
    setting: u16,
    /// Flags for the settings that this feature and setting enables.
    enable_flags: u32,
    /// Complement of flags for the settings that this feature and setting disable.
    disable_flags: u32,

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

/// A list of subtables in a metamorphosis chain.
///
/// The internal data layout is not designed for random access,
/// therefore we're not providing the `get()` method and only an iterator.
pub const Subtables = struct {
    count: u32,
    data: []const u8,
    number_of_glyphs: u16,

    pub fn iterator(
        self: Subtables,
    ) Iterator {
        return .{
            .count = self.count,
            .stream = .new(self.data),
            .number_of_glyphs = self.number_of_glyphs,
        };
    }

    /// An iterator over a metamorphosis chain subtables.
    pub const Iterator = struct {
        index: u32 = 0,
        count: u32,
        stream: parser.Stream,
        number_of_glyphs: u16,

        pub fn next(
            self: *Iterator,
        ) ?Subtable {
            if (self.index == self.count) return null;
            if (self.stream.at_end()) return null;
            return self.next_impl() catch null;
        }

        fn next_impl(
            self: *Iterator,
        ) parser.Error!Subtable {
            const len = try self.stream.read(u32);
            const coverage = try self.stream.read(Subtable.Coverage);
            self.stream.skip(u16); // reserved
            const kind_code = try self.stream.read(u8);
            const feature_flags = try self.stream.read(u32);

            const HEADER_LEN: usize = 12;
            const subtable_len = try std.math.sub(usize, len, HEADER_LEN);
            const subtables_data = try self.stream.read_bytes(subtable_len);

            const kind: Subtable.Kind = switch (kind_code) {
                0 => s: {
                    var s = parser.Stream.new(subtables_data);
                    break :s .{ .rearrangement = try .parse(
                        self.number_of_glyphs,
                        &s,
                    ) };
                },
                1 => .{ .contextual = try .parse(
                    self.number_of_glyphs,
                    subtables_data,
                ) },
                2 => .{ .ligature = try .parse(
                    self.number_of_glyphs,
                    subtables_data,
                ) },
                // 3 - reserved
                4 => .{ .non_contextual = try .parse(
                    self.number_of_glyphs,
                    subtables_data,
                ) },
                5 => .{ .insertion = try .parse(
                    self.number_of_glyphs,
                    subtables_data,
                ) },
                else => return error.ParseFail,
            };

            return .{
                .kind = kind,
                .coverage = coverage,
                .feature_flags = feature_flags,
            };
        }
    };
};

/// A subtable in a metamorphosis chain.
pub const Subtable = struct {
    /// A subtable kind.
    kind: Kind,
    /// A subtable coverage.
    coverage: Coverage,
    /// Subtable feature flags.
    feature_flags: u32,

    pub const Coverage = packed struct(u8) {
        _0: u4 = 0,
        /// If true, this subtable will process glyphs in logical order
        /// (or reverse logical order if `is_vertical` is also true).
        is_logical: bool,
        /// If true, this subtable will be applied to both horizontal and vertical text
        /// (`is_vertical` should be ignored).
        is_all_directions: bool,
        /// If true, this subtable will process glyphs in descending order.
        is_backwards: bool,
        /// If true, this subtable will only be applied to vertical text.
        is_vertical: bool,
    };

    /// A subtable kind.
    pub const Kind = union(enum) {
        rearrangement: aat.ExtendedStateTable(void),
        contextual: ContextualSubtable,
        ligature: LigatureSubtable,
        non_contextual: aat.Lookup,
        insertion: InsertionSubtable,

        /// A contextual subtable.
        pub const ContextualSubtable = struct {
            /// The contextual glyph substitution state table.
            state: aat.ExtendedStateTable(ContextualEntryData),
            offsets_data: []const u8,
            offsets: parser.LazyArray32(parser.Offset32),
            number_of_glyphs: u16,

            /// A contextual subtable state table trailing data.
            pub const ContextualEntryData = struct {
                /// A mark index.
                mark_index: u16,
                /// A current index.
                current_index: u16,

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

            fn parse(
                number_of_glyphs: u16,
                data: []const u8,
            ) parser.Error!ContextualSubtable {
                var s = parser.Stream.new(data);

                const state: aat.ExtendedStateTable(ContextualEntryData) = try .parse(number_of_glyphs, &s);

                // While the spec clearly states that this is an
                // 'offset from the beginning of the state subtable',
                // it's actually not. Subtable header should not be included.
                const offset = (try s.read(parser.Offset32))[0];

                // The offsets list is unsized.
                const offsets_data = try utils.slice(data, offset);
                const offsets = parser.LazyArray32(parser.Offset32).new(offsets_data);

                return .{
                    .state = state,
                    .offsets_data = offsets_data,
                    .offsets = offsets,
                    .number_of_glyphs = number_of_glyphs,
                };
            }

            /// Returns a `aat.Lookup` at index.
            pub fn lookup(
                self: ContextualSubtable,
                index: u32,
            ) ?aat.Lookup {
                const offset = self.offsets.get(index) orelse return null;
                const lookup_data = utils.slice(self.offsets_data, offset[0]) catch return null;
                return aat.Lookup.parse(self.number_of_glyphs, lookup_data) catch null;
            }
        };

        /// A ligature subtable.
        pub const LigatureSubtable = struct {
            /// A state table.
            state: aat.ExtendedStateTable(u16),
            /// Ligature actions.
            ligature_actions: parser.LazyArray32(u32),
            /// Ligature components.
            components: parser.LazyArray32(u16),
            /// Ligatures.
            ligatures: parser.LazyArray32(lib.GlyphId),

            fn parse(
                number_of_glyphs: u16,
                data: []const u8,
            ) parser.Error!LigatureSubtable {
                var s = parser.Stream.new(data);

                const state: aat.ExtendedStateTable(u16) = try .parse(number_of_glyphs, &s);

                // Offset are from `ExtendedStateTable`/`data`, not from subtable start.
                const ligature_action_offset = (try s.read(parser.Offset32))[0];
                const component_offset = (try s.read(parser.Offset32))[0];
                const ligature_offset = (try s.read(parser.Offset32))[0];

                // All three arrays are unsized, so we're simply reading/mapping all the data past offset.
                const ligature_actions = parser.LazyArray32(u32).new(try utils.slice(data, ligature_action_offset));
                const components = parser.LazyArray32(u16).new(try utils.slice(data, component_offset));
                const ligatures = parser.LazyArray32(lib.GlyphId).new(try utils.slice(data, ligature_offset));

                return .{
                    .state = state,
                    .ligature_actions = ligature_actions,
                    .components = components,
                    .ligatures = ligatures,
                };
            }
        };

        /// An insertion subtable.
        pub const InsertionSubtable = struct {
            /// A state table.
            state: aat.ExtendedStateTable(InsertionEntryData),
            /// Insertion glyphs.
            glyphs: parser.LazyArray32(lib.GlyphId),

            /// A contextual subtable state table trailing data.
            pub const InsertionEntryData = struct {
                /// A current insert index.
                current_insert_index: u16,
                /// A marked insert index.
                marked_insert_index: u16,

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

            fn parse(
                number_of_glyphs: u16,
                data: []const u8,
            ) parser.Error!InsertionSubtable {
                var s = parser.Stream.new(data);
                const state: aat.ExtendedStateTable(InsertionEntryData) = try .parse(number_of_glyphs, &s);
                const offset = (try s.read(parser.Offset32))[0];

                // TODO: unsized array?
                // The list is unsized.
                const glyphs = parser.LazyArray32(lib.GlyphId).new(try utils.slice(data, offset));

                return .{
                    .state = state,
                    .glyphs = glyphs,
                };
            }
        };
    };
};
