//! A [Metrics Variations Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/mvar) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");

const ItemVariationStore = @import("../var_store.zig");

const Table = @This();

variation_store: ItemVariationStore,
records: parser.LazyArray16(ValueRecord),

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s: parser.Stream = .new(data);

    const version = try s.read(u32);
    if (version != 0x00010000) return error.ParseFail;

    s.skip(u16);
    const value_record_size = try s.read(u16);

    if (value_record_size != ValueRecord.FromData.SIZE) return error.ParseFail;

    const count = try s.read(u16);
    if (count == 0) return error.ParseFail;

    const var_store_offset = try s.read_optional(parser.Offset16) orelse return error.ParseFail;
    const records = try s.read_array(ValueRecord, count);

    var var_s: parser.Stream = try .new_at(data, var_store_offset[0]);
    const variation_store: ItemVariationStore = try .parse(&var_s);

    return .{
        .records = records,
        .variation_store = variation_store,
    };
}

/// Returns a metric offset by tag.
pub fn metric_offset(
    self: *const Table,
    tag: lib.Tag,
    coordinates: []const lib.NormalizedCoordinate,
) ?f32 {
    const func = struct {
        fn func(record: ValueRecord, t: lib.Tag) std.math.Order {
            const lhs = record.value_tag.inner;
            const rhs = t.inner;

            return std.math.order(lhs, rhs);
        }
    }.func;

    _, const record = self.records.binary_search_by(
        tag,
        func,
    ) catch return null;

    return self.variation_store.parse_delta(
        record.delta_set_outer_index,
        record.delta_set_inner_index,
        coordinates,
    ) catch null;
}

const ValueRecord = struct {
    value_tag: lib.Tag,
    delta_set_outer_index: u16,
    delta_set_inner_index: u16,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 8;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};
