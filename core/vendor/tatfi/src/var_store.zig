//! Implementation of Item Variation Store
//!
//! <https://docs.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#item-variation-store>

const std = @import("std");
const lib = @import("lib.zig");
const parser = @import("parser.zig");

const ItemVariationStore = @This();

data: []const u8 = &.{},
data_offsets: parser.LazyArray16(u32) = .{},
regions: VariationRegionList = .{},

pub fn parse(
    s: *parser.Stream,
) parser.Error!ItemVariationStore {
    const data = try s.tail();

    var regions_s: parser.Stream = .{
        .data = s.data,
        .offset = s.offset,
    };
    const format = try s.read(u16);
    if (format != 1) return error.ParseFail;

    const region_list_offset = try s.read(u32);
    const count = try s.read(u16);
    const offsets = try s.read_array(u32, count);

    const regions: VariationRegionList = r: {
        regions_s.advance(region_list_offset);
        // [RazrFalcon] TODO: should be the same as in `fvar`
        const axis_count = try regions_s.read(u16);
        const regions_count = try regions_s.read(u16);
        const total = try std.math.mul(u16, regions_count, axis_count);

        break :r .{
            .axis_count = axis_count,
            .regions = try regions_s.read_array(RegionAxisCoordinatesRecord, total),
        };
    };

    return .{
        .data = data,
        .data_offsets = offsets,
        .regions = regions,
    };
}

pub fn parse_delta(
    self: ItemVariationStore,
    outer_index: u16,
    inner_index: u16,
    coordinates: []const lib.NormalizedCoordinate,
) parser.Error!f32 {
    const offset = self.data_offsets.get(outer_index) orelse return error.ParseFail;

    var s = try parser.Stream.new_at(self.data, offset);
    const item_count = try s.read(u16);
    const word_delta_count_raw = try s.read(u16);
    const region_index_count = try s.read(u16);
    const region_indices_array = try s.read_array(u16, region_index_count);

    if (inner_index >= item_count) return error.ParseFail;

    const has_long_words = (word_delta_count_raw & 0x8000) != 0;
    const word_delta_count = word_delta_count_raw & 0x7FFF;

    // From the spec: The length of the data for each row, in bytes, is
    // regionIndexCount + (wordDeltaCount & WORD_DELTA_COUNT_MASK)
    // if the LONG_WORDS flag is not set, or 2 x that amount if the flag is set.
    var delta_set_len = word_delta_count + region_index_count;
    if (has_long_words) delta_set_len *= 2;

    const advnacement = try std.math.mul(usize, inner_index, delta_set_len);
    s.advance(advnacement);

    var delta: f32 = 0.0;
    var i: u16 = 0;
    while (i < word_delta_count) {
        const idx = region_indices_array.get(i) orelse return error.ParseFail;
        const num: f32 = if (has_long_words)
            // TODO: use f64?
            @floatFromInt(try s.read(i32))
        else
            @floatFromInt(try s.read(i16));

        delta += num * self.regions.evaluate_region(idx, coordinates);
        i += 1;
    }

    while (i < region_index_count) {
        const idx = region_indices_array.get(i) orelse return error.ParseFail;
        const num: f32 = if (has_long_words)
            @floatFromInt(try s.read(i16))
        else
            @floatFromInt(try s.read(i8));

        delta += num * self.regions.evaluate_region(idx, coordinates);
        i += 1;
    }

    return delta;
}

pub const VariationRegionList = struct {
    axis_count: u16 = 0,
    regions: parser.LazyArray16(RegionAxisCoordinatesRecord) = .{},

    pub fn evaluate_region(
        self: VariationRegionList,
        index: u16,
        coordinates: []const lib.NormalizedCoordinate,
    ) f32 {
        var v: f32 = 1.0;

        for (coordinates, 0..) |coord, i| {
            const true_index: u16 = index * self.axis_count + @as(u16, @truncate(i));
            const region = self.regions.get(true_index) orelse return 0.0;

            const factor = region.evaluate_axis(coord.inner);
            if (factor == 0.0) return 0.0;

            v *= factor;
        }

        return v;
    }
};

const RegionAxisCoordinatesRecord = struct {
    start_coord: i16,
    peak_coord: i16,
    end_coord: i16,

    pub fn evaluate_axis(
        self: RegionAxisCoordinatesRecord,
        coord: i16,
    ) f32 {
        const start = self.start_coord;
        const peak = self.peak_coord;
        const end = self.end_coord;

        if (start > peak or peak > end)
            return 1.0;

        if (start < 0 and end > 0 and peak != 0)
            return 1.0;

        if (peak == 0 or coord == peak)
            return 1.0;

        if (coord <= start or end <= coord)
            return 0.0;

        if (coord < peak) {
            const top: f32 = @floatFromInt(coord - start);
            const bot: f32 = @floatFromInt(peak - start);
            return top / bot;
        } else {
            const top: f32 = @floatFromInt(end - coord);
            const bot: f32 = @floatFromInt(end - peak);
            return top / bot;
        }
    }

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
};

pub fn region_indices(
    self: ItemVariationStore,
    index: u16,
) ?parser.LazyArray16(u16) {
    // Offsets in bytes from the start of the item variation store
    // to each item variation data subtable.
    const offset = self.data_offsets.get(index) orelse return null;
    var s = parser.Stream.new_at(self.data, offset) catch return null;
    s.skip(u16); // item_count
    s.skip(u16); // short_delta_count
    const count = s.read(u16) catch return null;
    return s.read_array(u16, count) catch null;
}
