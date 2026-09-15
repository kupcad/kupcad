const std = @import("std");
const ggg = @import("../ggg.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const ctx = @import("context.zig");

/// A [Chained Contextual Lookup Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#chseqctxt1).
pub const ChainedContextLookup = union(enum) {
    /// Simple glyph contexts.
    format1: struct { coverage: ggg.Coverage, sets: ChainedSequenceRuleSets },
    /// Class-based glyph contexts.
    format2: struct {
        coverage: ggg.Coverage,
        backtrack_classes: ggg.ClassDefinition,
        input_classes: ggg.ClassDefinition,
        lookahead_classes: ggg.ClassDefinition,
        sets: ChainedSequenceRuleSets,
    },
    /// Coverage-based glyph contexts.
    format3: struct {
        coverage: ggg.Coverage,
        backtrack_coverages: parser.LazyOffsetArray16(ggg.Coverage),
        input_coverages: parser.LazyOffsetArray16(ggg.Coverage),
        lookahead_coverages: parser.LazyOffsetArray16(ggg.Coverage),
        lookups: parser.LazyArray16(ctx.SequenceLookupRecord),
    },

    pub fn parse(
        data: []const u8,
    ) parser.Error!ChainedContextLookup {
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

                const backtrack_classes: ggg.ClassDefinition = p: {
                    const offset = try s.read_optional(parser.Offset16) orelse break :p .empty;
                    break :p try .parse(try utils.slice(data, offset[0]));
                };
                const input_classes: ggg.ClassDefinition = p: {
                    const offset = try s.read_optional(parser.Offset16) orelse break :p .empty;
                    break :p try .parse(try utils.slice(data, offset[0]));
                };
                const lookahead_classes: ggg.ClassDefinition = p: {
                    const offset = try s.read_optional(parser.Offset16) orelse break :p .empty;
                    break :p try .parse(try utils.slice(data, offset[0]));
                };

                const count = try s.read(u16);
                const offsets = try s.read_array(?parser.Offset16, count);

                return .{ .format2 = .{
                    .coverage = coverage_var,
                    .backtrack_classes = backtrack_classes,
                    .input_classes = input_classes,
                    .lookahead_classes = lookahead_classes,
                    .sets = .new(data, offsets),
                } };
            },
            3 => {
                const backtrack_count = try s.read(u16);
                const backtrack_coverages = try s.read_array(?parser.Offset16, backtrack_count);

                const input_count = try s.read(u16);
                const coverage_var = c: {
                    const offset = try s.read(parser.Offset16);
                    break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                };
                const input_coverages = try s.read_array(?parser.Offset16, input_count -| 1);

                const lookahead_count = try s.read(u16);
                const lookahead_coverages = try s.read_array(?parser.Offset16, lookahead_count);

                const lookup_count = try s.read(u16);
                const lookups = try s.read_array(ctx.SequenceLookupRecord, lookup_count);

                return .{ .format3 = .{
                    .coverage = coverage_var,
                    .backtrack_coverages = .new(data, backtrack_coverages),
                    .input_coverages = .new(data, input_coverages),
                    .lookahead_coverages = .new(data, lookahead_coverages),
                    .lookups = lookups,
                } };
            },
            else => return error.ParseFail,
        }
    }

    /// Returns the subtable coverage.
    pub fn coverage(
        self: ChainedContextLookup,
    ) ggg.Coverage {
        switch (self) {
            inline else => |f| return f.coverage,
        }
    }
};

/// A list of `ChainedSequenceRule` sets.
pub const ChainedSequenceRuleSets = parser.LazyOffsetArray16(ChainedSequenceRuleSet);

/// A set of `ChainedSequenceRule`.
pub const ChainedSequenceRuleSet = parser.LazyOffsetArray16(ChainedSequenceRule);

/// A [Chained Sequence Rule](https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#chained-sequence-context-format-1-simple-glyph-contexts).
pub const ChainedSequenceRule = struct {
    /// Contains either glyph IDs or glyph Classes.
    backtrack: parser.LazyArray16(u16),
    input: parser.LazyArray16(u16),
    /// Contains either glyph IDs or glyph Classes.
    lookahead: parser.LazyArray16(u16),
    lookups: parser.LazyArray16(ctx.SequenceLookupRecord),

    pub fn parse(
        data: []const u8,
    ) parser.Error!ChainedSequenceRule {
        var s = parser.Stream.new(data);
        const backtrack_count = try s.read(u16);
        const backtrack = try s.read_array(u16, backtrack_count);
        const input_count = try s.read(u16);
        const input = try s.read_array(u16, try std.math.sub(u16, input_count, 1));
        const lookahead_count = try s.read(u16);
        const lookahead = try s.read_array(u16, lookahead_count);
        const lookup_count = try s.read(u16);
        const lookups = try s.read_array(ctx.SequenceLookupRecord, lookup_count);
        return .{
            .backtrack = backtrack,
            .input = input,
            .lookahead = lookahead,
            .lookups = lookups,
        };
    }
};
