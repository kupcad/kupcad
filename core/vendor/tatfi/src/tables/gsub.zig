//! A [Glyph Substitution Table](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub)
//! implementation.

// A heavily modified port of https://github.com/harfbuzz/rustybuzz implementation
// originally written by https://github.com/laurmaedje

const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const ggg = @import("../ggg.zig");

/// A glyph substitution
/// [lookup subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#table-organization)
/// enumeration.
pub const SubstitutionSubtable = union(enum) {
    single: SingleSubstitution,
    multiple: MultipleSubstitution,
    alternate: AlternateSubstitution,
    ligature: LigatureSubstitution,
    context: ggg.ContextLookup,
    chain_context: ggg.ChainedContextLookup,
    reverse_chain_single: ReverseChainSingleSubstitution,

    pub fn parse(
        data: []const u8,
        kind: u16,
    ) parser.Error!SubstitutionSubtable {
        return switch (kind) {
            1 => .{ .single = try .parse(data) },
            2 => .{ .multiple = try .parse(data) },
            3 => .{ .alternate = try .parse(data) },
            4 => .{ .ligature = try .parse(data) },
            5 => .{ .context = try .parse(data) },
            6 => .{ .chain_context = try .parse(data) },
            7 => try ggg.parse_extension_lookup(SubstitutionSubtable, data),
            8 => .{ .reverse_chain_single = try .parse(data) },
            else => error.ParseFail,
        };
    }

    /// Returns the subtable coverage.
    pub fn coverage(
        self: SubstitutionSubtable,
    ) ggg.Coverage {
        return switch (self) {
            inline .single, .context, .chain_context => |t| t.coverage(),
            inline .multiple, .alternate, .ligature, .reverse_chain_single => |t| t.coverage,
        };
    }

    /// Checks that the current subtable is *Reverse Chaining Contextual Single*.
    pub fn is_reverse(
        self: SubstitutionSubtable,
    ) bool {
        return self == .reverse_chain_single;
    }
};

/// A [Single Substitution Subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#SS).
pub const SingleSubstitution = union(enum) {
    format1: struct { coverage: ggg.Coverage, delta: i16 },
    format2: struct { coverage: ggg.Coverage, substitutes: parser.LazyArray16(lib.GlyphId) },

    fn parse(
        data: []const u8,
    ) parser.Error!SingleSubstitution {
        var s = parser.Stream.new(data);
        switch (try s.read(u16)) {
            1 => {
                const offset = try s.read(parser.Offset16);
                const coverage_var = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                const delta = try s.read(i16);
                return .{ .format1 = .{
                    .coverage = coverage_var,
                    .delta = delta,
                } };
            },
            2 => {
                const offset = try s.read(parser.Offset16);
                const coverage_var = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                const count = try s.read(u16);
                const substitutes = try s.read_array(lib.GlyphId, count);
                return .{ .format2 = .{
                    .coverage = coverage_var,
                    .substitutes = substitutes,
                } };
            },
            else => return error.ParseFail,
        }
    }

    /// Returns the subtable coverage.
    pub fn coverage(self: SingleSubstitution) ggg.Coverage {
        switch (self) {
            inline else => |f| return f.coverage,
        }
    }
};

/// A [Multiple Substitution Subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#MS).
pub const MultipleSubstitution = struct {
    coverage: ggg.Coverage,
    sequences: SequenceList,

    fn parse(
        data: []const u8,
    ) parser.Error!MultipleSubstitution {
        var s = parser.Stream.new(data);
        if (try s.read(u16) != 1) return error.ParseFail;

        const offset = try s.read(parser.Offset16);
        const coverage_var = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        const count = try s.read(u16);
        const offsets = try s.read_array(?parser.Offset16, count);
        return .{ .coverage = coverage_var, .sequences = .new(data, offsets) };
    }

    /// A list of `Sequence` tables.
    pub const SequenceList = parser.LazyOffsetArray16(Sequence);

    /// A sequence of glyphs for
    /// [Multiple Substitution Subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#MS).
    pub const Sequence = struct {
        /// A list of substitute glyphs.
        substitutes: parser.LazyArray16(lib.GlyphId),

        pub fn parse(
            data: []const u8,
        ) parser.Error!Sequence {
            var s = parser.Stream.new(data);
            const count = try s.read(u16);
            const substitutes = try s.read_array(lib.GlyphId, count);
            return .{ .substitutes = substitutes };
        }
    };
};

/// A [Alternate Substitution Subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#AS).
pub const AlternateSubstitution = struct {
    coverage: ggg.Coverage,
    alternate_sets: AlternateSets,

    fn parse(
        data: []const u8,
    ) parser.Error!AlternateSubstitution {
        var s = parser.Stream.new(data);
        if (try s.read(u16) != 1) return error.ParseFail;

        const offset = try s.read(parser.Offset16);
        const coverage_var = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        const count = try s.read(u16);
        const offsets = try s.read_array(?parser.Offset16, count);
        return .{ .coverage = coverage_var, .alternate_sets = .new(data, offsets) };
    }

    /// A set of `AlternateSet`.
    pub const AlternateSets = parser.LazyOffsetArray16(AlternateSet);

    /// A list of glyphs for
    /// [Alternate Substitution Subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#AS).
    pub const AlternateSet = struct {
        /// Array of alternate glyph IDs, in arbitrary order.
        alternates: parser.LazyArray16(lib.GlyphId),

        pub fn parse(
            data: []const u8,
        ) parser.Error!AlternateSet {
            var s = parser.Stream.new(data);
            const count = try s.read(u16);
            const alternates = try s.read_array(lib.GlyphId, count);
            return .{ .alternates = alternates };
        }
    };
};

/// A [Ligature Substitution Subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#LS).
pub const LigatureSubstitution = struct {
    coverage: ggg.Coverage,
    ligature_sets: LigatureSets,

    fn parse(
        data: []const u8,
    ) parser.Error!LigatureSubstitution {
        var s = parser.Stream.new(data);
        if (try s.read(u16) != 1) return error.ParseFail;

        const offset = try s.read(parser.Offset16);
        const coverage_var = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        const count = try s.read(u16);
        const offsets = try s.read_array(?parser.Offset16, count);
        return .{ .coverage = coverage_var, .ligature_sets = .new(data, offsets) };
    }

    /// A list of `Ligature` sets.
    pub const LigatureSets = parser.LazyOffsetArray16(LigatureSet);

    /// A `Ligature` set.
    pub const LigatureSet = parser.LazyOffsetArray16(Ligature);

    /// Glyph components for one ligature.
    pub const Ligature = struct {
        /// Ligature to substitute.
        glyph: lib.GlyphId,
        /// Glyph components for one ligature.
        components: parser.LazyArray16(lib.GlyphId),

        pub fn parse(
            data: []const u8,
        ) parser.Error!Ligature {
            var s = parser.Stream.new(data);
            const glyph = try s.read(lib.GlyphId);
            const count = try s.read(u16);
            if (count == 0) return error.ParseFail;

            const components = try s.read_array(lib.GlyphId, count - 1);
            return .{
                .glyph = glyph,
                .components = components,
            };
        }
    };
};

/// A [Reverse Chaining Contextual Single Substitution Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gsub#RCCS).
pub const ReverseChainSingleSubstitution = struct {
    coverage: ggg.Coverage,
    backtrack_coverages: parser.LazyOffsetArray16(ggg.Coverage),
    lookahead_coverages: parser.LazyOffsetArray16(ggg.Coverage),
    substitutes: parser.LazyArray16(lib.GlyphId),

    fn parse(
        data: []const u8,
    ) parser.Error!ReverseChainSingleSubstitution {
        var s = parser.Stream.new(data);
        if (try s.read(u16) != 1) return error.ParseFail;

        const coverage = c: {
            const offset = try s.read(parser.Offset16);
            break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        };

        const backtrack_count = try s.read(u16);
        const backtrack_coverages = try s.read_array(?parser.Offset16, backtrack_count);
        const lookahead_count = try s.read(u16);
        const lookahead_coverages = try s.read_array(?parser.Offset16, lookahead_count);
        const substitute_count = try s.read(u16);
        const substitutes = try s.read_array(lib.GlyphId, substitute_count);

        return .{
            .coverage = coverage,
            .backtrack_coverages = .new(data, backtrack_coverages),
            .lookahead_coverages = .new(data, lookahead_coverages),
            .substitutes = substitutes,
        };
    }
};
