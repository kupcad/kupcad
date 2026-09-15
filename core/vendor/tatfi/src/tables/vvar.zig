//! A [Vertical Metrics Variations Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/hvar) implementation.

const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");

const DeltaSetIndexMap = @import("../delta_set.zig");
const ItemVariationStore = @import("../var_store.zig");

const Table = @This();

data: []const u8,
variation_store: ItemVariationStore,
advance_height_mapping_offset: ?parser.Offset32,
tsb_mapping_offset: ?parser.Offset32,
bsb_mapping_offset: ?parser.Offset32,
vorg_mapping_offset: ?parser.Offset32,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u32);
    if (version != 0x00010000) return error.ParseFail;

    const variation_store_offset = try s.read(parser.Offset32);
    var var_store_s: parser.Stream = try .new_at(data, variation_store_offset[0]);
    const variation_store: ItemVariationStore = try .parse(&var_store_s);

    return .{
        .data = data,
        .variation_store = variation_store,
        .advance_height_mapping_offset = try s.read_optional(parser.Offset32),
        .tsb_mapping_offset = try s.read_optional(parser.Offset32),
        .bsb_mapping_offset = try s.read_optional(parser.Offset32),
        .vorg_mapping_offset = try s.read_optional(parser.Offset32),
    };
}

/// Returns the advance width offset for a glyph.
pub fn advance_offset(
    self: *const Table,
    glyph_id: lib.GlyphId,
    coordinates: []const lib.NormalizedCoordinate,
) ?f32 {
    const outer_idx, const inner_idx =
        if (self.advance_height_mapping_offset) |offset| o: {
            const data = utils.slice(self.data, offset[0]) catch return null;

            break :o DeltaSetIndexMap.new(data).map(glyph_id[0]) orelse return null;
        } else
        // 'If there is no delta-set index mapping table for advance widths,
        // then glyph IDs implicitly provide the indices:
        // for a given glyph ID, the delta-set outer-level index is zero,
        // and the glyph ID is the delta-set inner-level index.'
        .{ 0, glyph_id[0] };

    return self.variation_store.parse_delta(outer_idx, inner_idx, coordinates) catch null;
}

/// Returns the top side bearing offset for a glyph.
pub fn top_side_bearing_offset(
    self: *const Table,
    glyph_id: lib.GlyphId,
    coordinates: []const lib.NormalizedCoordinate,
) ?f32 {
    const offset = self.tsb_mapping_offset orelse return null;
    const set_data = utils.slice(self.data, offset[0]) catch return null;
    return self.side_bearing_offset(glyph_id, coordinates, set_data);
}

/// Returns the bottom side bearing offset for a glyph.
pub fn bottom_side_bearing_offset(
    self: *const Table,
    glyph_id: lib.GlyphId,
    coordinates: []const lib.NormalizedCoordinate,
) ?f32 {
    const offset = self.bsb_mapping_offset orelse return null;
    const set_data = utils.slice(self.data, offset[0]) catch return null;
    return self.side_bearing_offset(glyph_id, coordinates, set_data);
}

/// Returns the vertical origin offset for a glyph.
pub fn vertical_origin_offset(
    self: *const Table,
    glyph_id: lib.GlyphId,
    coordinates: []const lib.NormalizedCoordinate,
) ?f32 {
    const offset = self.vorg_mapping_offset orelse return null;
    const set_data = utils.slice(self.data, offset[0]) catch return null;
    return self.side_bearing_offset(glyph_id, coordinates, set_data);
}

fn side_bearing_offset(
    self: *const Table,
    glyph_id: lib.GlyphId,
    coordinates: []const lib.NormalizedCoordinate,
    set_data: []const u8,
) ?f32 {
    const outer_idx, const inner_idx =
        DeltaSetIndexMap.new(set_data).map(glyph_id[0]) orelse return null;
    return self.variation_store.parse_delta(outer_idx, inner_idx, coordinates) catch null;
}
