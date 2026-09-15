//! A [Vertical Origin Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/vorg) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");

const Table = @This();

/// Default origin.
default_y: i16,
/// A list of metrics for each glyph.
///
/// Ordered by `glyph_id`.
metrics: parser.LazyArray16(VerticalOriginMetrics),

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u32);
    if (version != 0x00010000) return error.ParseFail;

    const default_y = try s.read(i16);
    const count = try s.read(u16);
    const metrics = try s.read_array(VerticalOriginMetrics, count);

    return .{
        .default_y = default_y,
        .metrics = metrics,
    };
}

/// Returns glyph's Y origin.
pub fn glyph_y_origin(
    self: *const Table,
    glyph_id: lib.GlyphId,
) i16 {
    const func = struct {
        fn func(m: VerticalOriginMetrics, gi: lib.GlyphId) std.math.Order {
            return std.math.order(m.glyph_id[0], gi[0]);
        }
    }.func;

    _, const vom = self.metrics.binary_search_by(glyph_id, func) catch return self.default_y;
    return vom.y;
}

/// Vertical origin metrics for the
/// [Vertical Origin Table](https://docs.microsoft.com/en-us/typography/opentype/spec/vorg).
pub const VerticalOriginMetrics = struct {
    /// Glyph ID.
    glyph_id: lib.GlyphId,
    /// Y coordinate, in the font's design coordinate system, of the vertical origin.
    y: i16,

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
