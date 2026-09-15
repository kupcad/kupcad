//! Common data types used by GDEF/GPOS/GSUB tables.
//!
//! <https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2>

// A heavily modified port of https://github.com/harfbuzz/rustybuzz implementation
// originally written by https://github.com/laurmaedje

// internal reëxports
const layout_table = @import("ggg/layout_table.zig");
pub const Feature = layout_table.Feature;
pub const LayoutTable = layout_table.LayoutTable;
pub const ScriptIndex = layout_table.ScriptIndex;
pub const LanguageIndex = layout_table.LanguageIndex;
pub const FeatureIndex = layout_table.FeatureIndex;
pub const LookupIndex = layout_table.LookupIndex;
pub const VariationIndex = layout_table.VariationIndex;

// end of internal reëxports

const std = @import("std");
const lib = @import("lib.zig");
const parser = @import("parser.zig");

pub const SequenceRule = @import("ggg/context.zig").SequenceRule;
pub const ChainedSequenceRule = @import("ggg/chained_context.zig").ChainedSequenceRule;
pub const ContextLookup = @import("ggg/context.zig").ContextLookup;
pub const ChainedContextLookup = @import("ggg/chained_context.zig").ChainedContextLookup;

pub const Lookup = @import("ggg/lookup.zig").Lookup;
pub const LookupKind = @import("ggg/lookup.zig").LookupSubtable;
pub const LookupFlags = @import("ggg/lookup.zig").LookupFlags;
pub const parse_extension_lookup = @import("ggg/lookup.zig").parse_extension_lookup;

/// A [Class Definition Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#class-definition-table).
pub const ClassDefinition = union(enum) {
    format1: struct { start: lib.GlyphId, classes: parser.LazyArray16(Class) },
    format2: struct { records: parser.LazyArray16(RangeRecord) },
    empty,

    pub fn parse(
        data: []const u8,
    ) parser.Error!ClassDefinition {
        var s = parser.Stream.new(data);
        const v = try s.read(u16);

        switch (v) {
            1 => {
                const start = try s.read(lib.GlyphId);
                const count = try s.read(u16);
                const classes = try s.read_array(Class, count);
                return .{ .format1 = .{
                    .start = start,
                    .classes = classes,
                } };
            },
            2 => {
                const count = try s.read(u16);
                const records = try s.read_array(RangeRecord, count);
                return .{ .format2 = .{ .records = records } };
            },
            else => return error.ParseFail,
        }
    }

    /// Returns the glyph class of the glyph (zero if it is not defined).
    pub fn get(
        self: ClassDefinition,
        glyph: lib.GlyphId,
    ) Class {
        switch (self) {
            .format1 => |f| {
                const index = std.math.sub(u16, glyph[0], f.start[0]) catch return 0;
                return f.classes.get(index) orelse 0;
            },
            .format2 => |f| {
                const record = RangeRecord.range(f.records, glyph) orelse return 0;
                const offset = glyph[0] - record.start[0];
                return std.math.add(u16, record.value, offset) catch 0;
            },
            .empty => return 0,
        }
    }
};

/// A value of [Class Definition Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#class-definition-table).
pub const Class = u16;

/// A record that describes a range of glyph IDs.
pub const RangeRecord = struct {
    /// First glyph ID in the range
    start: lib.GlyphId,
    /// Last glyph ID in the range
    end: lib.GlyphId,
    /// Coverage Index of first glyph ID in range.
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

    /// Returns a `RangeRecord` for a glyph.
    pub fn range(
        self: parser.LazyArray16(RangeRecord),
        glyph: lib.GlyphId,
    ) ?RangeRecord {
        const func = struct {
            fn func(
                record: RangeRecord,
                rhs: lib.GlyphId,
            ) std.math.Order {
                return if (rhs[0] < record.start[0])
                    .gt
                else if (rhs[0] <= record.end[0])
                    .eq
                else
                    .lt;
            }
        }.func;
        _, const ret = self.binary_search_by(glyph, func) catch return null;
        return ret;
    }
};

/// A [Coverage Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#coverage-table).
pub const Coverage = union(enum) {
    /// Array of glyph IDs. Sorted.
    format1: parser.LazyArray16(lib.GlyphId),

    /// Array of glyph ranges. Ordered by `RangeRecord.start`.
    format2: parser.LazyArray16(RangeRecord),

    pub fn parse(
        data: []const u8,
    ) parser.Error!Coverage {
        var s = parser.Stream.new(data);
        switch (try s.read(u16)) {
            1 => {
                const count = try s.read(u16);
                const glyphs = try s.read_array(lib.GlyphId, count);
                return .{ .format1 = glyphs };
            },
            2 => {
                const count = try s.read(u16);
                const records = try s.read_array(RangeRecord, count);
                return .{ .format2 = records };
            },
            else => return error.ParseFail,
        }
    }

    /// Checks that glyph is present.
    pub fn contains(
        self: Coverage,
        glyph: lib.GlyphId,
    ) bool {
        return self.get(glyph) != null;
    }

    /// Returns the coverage index of the glyph or `null` if it is not covered.
    pub fn get(
        self: Coverage,
        glyph: lib.GlyphId,
    ) ?u16 {
        switch (self) {
            .format1 => |glyphs| {
                const func = struct {
                    fn func(lhs: lib.GlyphId, rhs: lib.GlyphId) std.math.Order {
                        return std.math.order(lhs[0], rhs[0]);
                    }
                }.func;

                const p, _ = glyphs.binary_search_by(glyph, func) catch return null;
                return p;
            },
            .format2 => |records| {
                const record = RangeRecord.range(records, glyph) orelse return null;
                const offset = glyph[0] - record.start[0];
                return std.math.add(u16, record.value, offset) catch null;
            },
        }
    }
};
