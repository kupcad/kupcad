//! A [Horizontal/Vertical Metrics Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/hmtx) implementation.
//!
//! `hmtx` and `vmtx` tables has the same structure, so we're reusing the same struct for both.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");

const Table = @This();

/// A list of metrics indexed by glyph ID.
metrics: parser.LazyArray16(Metrics),
/// Side bearings for glyph IDs greater than or equal to the number of `metrics` values.
bearings: parser.LazyArray16(i16),
/// Sum of long metrics + bearings.
number_of_metrics: u16,

/// Parses a table from raw data.
///
/// - `number_of_metrics` is from the `hhea`/`vhea` table.
/// - `number_of_glyphs` is from the `maxp` table.
pub fn parse(
    number_of_metrics_immutable: u16,
    number_of_glyphs: u16, // nonzero
    data: []const u8,
) parser.Error!Table {
    var number_of_metrics = number_of_metrics_immutable;
    if (number_of_metrics == 0 or
        number_of_glyphs == 0) return error.ParseFail;

    var s = parser.Stream.new(data);
    const metrics = try s.read_array(Metrics, number_of_metrics);

    // 'If the number_of_metrics is less than the total number of glyphs,
    // then that array is followed by an array for the left side bearing values
    // of the remaining glyphs.'
    const bearings_count = std.math.sub(u16, number_of_glyphs, number_of_metrics);

    const bearings: parser.LazyArray16(i16) = if (bearings_count) |count| b: {
        number_of_metrics += count;
        // Some malformed fonts can skip "left side bearing values"
        // even when they are expected.
        // Therefore if we weren't able to parser them, simply fallback to an empty array.
        // No need to mark the whole table as malformed.
        break :b s.read_array(i16, count) catch .{};
    } else |_| .{};

    return .{
        .metrics = metrics,
        .bearings = bearings,
        .number_of_metrics = number_of_metrics,
    };
}

/// Returns advance for a glyph.
pub fn advance(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?u16 {
    if (glyph_id[0] >= self.number_of_metrics) return null;

    if (self.metrics.get(glyph_id[0])) |metrics|
        return metrics.advance
    else {
        // 'As an optimization, the number of records can be less than the number of glyphs,
        // in which case the advance value of the last record applies
        // to all remaining glyph IDs.'
        const last = self.metrics.last() orelse return null;
        return last.advance;
    }
}

/// Returns side bearing for a glyph.
pub fn side_bearing(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?i16 {
    if (self.metrics.get(glyph_id[0])) |metrics|
        return metrics.side_bearing
    else {
        // 'If the number_of_metrics is less than the total number of glyphs,
        // then that array is followed by an array for the side bearing values
        // of the remaining glyphs.'

        const idx = std.math.sub(u16, glyph_id[0], self.metrics.len()) catch return null;
        return self.bearings.get(idx);
    }
}

/// Horizontal/Vertical Metrics.
pub const Metrics = struct {
    /// Width/Height advance for `hmtx`/`vmtx`.
    advance: u16,
    /// Left/Top side bearing for `hmtx`/`vmtx`.
    side_bearing: i16,

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
