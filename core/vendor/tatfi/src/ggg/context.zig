const std = @import("std");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const ggg = @import("../ggg.zig");
const lt = @import("layout_table.zig");

/// A [Contextual Lookup Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#seqctxt1).
pub const ContextLookup = union(enum) {
    /// Simple glyph contexts.
    format1: struct { coverage: ggg.Coverage, sets: SequenceRuleSets },
    /// Class-based glyph contexts.
    format2: struct { coverage: ggg.Coverage, classes: ggg.ClassDefinition, sets: SequenceRuleSets },
    /// Coverage-based glyph contexts.
    format3: struct {
        coverage: ggg.Coverage,
        coverages: parser.LazyOffsetArray16(ggg.Coverage),
        lookups: parser.LazyArray16(SequenceLookupRecord),
    },

    pub fn parse(
        data: []const u8,
    ) parser.Error!ContextLookup {
        var s = parser.Stream.new(data);
        switch (try s.read(u16)) {
            1 => {
                const coverage_var = c: {
                    const offset = try s.read(parser.Offset16);
                    break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                };

                const count = try s.read(u16);
                const offsets = try s.read_array(?parser.Offset16, count);
                return .{ .format1 = .{
                    .coverage = coverage_var,
                    .sets = .new(data, offsets),
                } };
            },
            2 => {
                const coverage_var = c: {
                    const offset = try s.read(parser.Offset16);
                    break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                };
                const classes = c: {
                    const offset = try s.read(parser.Offset16);
                    break :c try ggg.ClassDefinition.parse(try utils.slice(data, offset[0]));
                };

                const count = try s.read(u16);
                const offsets = try s.read_array(?parser.Offset16, count);
                return .{ .format2 = .{
                    .coverage = coverage_var,
                    .classes = classes,
                    .sets = .new(data, offsets),
                } };
            },
            3 => {
                const input_count = try s.read(u16);
                const lookup_count = try s.read(u16);
                const coverage_var = c: {
                    const offset = try s.read(parser.Offset16);
                    break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                };
                const coverage_count = try std.math.sub(u16, input_count, 1);
                const coverages = try s.read_array(?parser.Offset16, coverage_count);
                const lookups = try s.read_array(SequenceLookupRecord, lookup_count);
                return .{ .format3 = .{
                    .coverage = coverage_var,
                    .coverages = .new(data, coverages),
                    .lookups = lookups,
                } };
            },
            else => return error.ParseFail,
        }
    }

    /// Returns the subtable coverage.
    pub fn coverage(
        self: ContextLookup,
    ) ggg.Coverage {
        switch (self) {
            inline else => |f| return f.coverage,
        }
    }
};

/// A list of `SequenceRuleSet`s.
pub const SequenceRuleSets = parser.LazyOffsetArray16(SequenceRuleSet);

/// A set of `SequenceRule`s.
pub const SequenceRuleSet = parser.LazyOffsetArray16(SequenceRule);

/// A sequence rule.
pub const SequenceRule = struct {
    input: parser.LazyArray16(u16),
    lookups: parser.LazyArray16(SequenceLookupRecord),

    pub fn parse(
        data: []const u8,
    ) parser.Error!SequenceRule {
        var s = parser.Stream.new(data);
        const input_count = try s.read(u16);
        const lookup_count = try s.read(u16);

        const input = try s.read_array(u16, try std.math.sub(u16, input_count, 1));
        const lookups = try s.read_array(SequenceLookupRecord, lookup_count);

        return .{
            .input = input,
            .lookups = lookups,
        };
    }
};

/// A sequence rule record.
pub const SequenceLookupRecord = struct {
    sequence_index: u16,
    lookup_list_index: lt.LookupIndex,

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
