//! An [Axis Variations Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/avar) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");

const Table = @This();

/// The segment maps array — one segment map for each axis
/// in the order of axes specified in the `fvar` table.
segment_maps: SegmentMaps,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u32);
    if (version != 0x00010000) return error.ParseFail;

    s.skip(u16); // reserved

    return .{
        .segment_maps = .{
            // TODO: check that `axisCount` is the same as in `fvar`?
            .count = try s.read(u16),
            .data = try s.tail(),
        },
    };
}

/// Maps a single coordinate. return true on success
pub fn map_coordinate(
    self: *const Table,
    coordinates: []lib.NormalizedCoordinate,
    coordinate_index: usize,
) !void {
    if (self.segment_maps.count != coordinates.len) return error.DataError;

    var iter = self.segment_maps.iterator();
    var i: usize = 0;
    while (iter.next()) |map| : (i += 1) if (i == coordinate_index) {
        coordinates[i] = .from(map_value(&map, coordinates[i].inner) orelse return error.MapError);
        break;
    };
}

/// A list of segment maps.
///
/// Can be empty.
///
/// The internal data layout is not designed for random access,
/// therefore we're not providing the `get()` method and only an iterator.
pub const SegmentMaps = struct {
    count: u16,
    data: []const u8,

    pub fn iterator(
        self: SegmentMaps,
    ) Iterator {
        return .{ .stream = parser.Stream.new(self.data) };
    }

    pub const Iterator = struct {
        stream: parser.Stream,

        pub fn next(
            self: *Iterator,
        ) ?parser.LazyArray16(AxisValueMap) {
            const count = self.stream.read(u16) catch return null;
            return self.stream.read_array(AxisValueMap, count) catch null;
        }
    };
};

/// An axis value map.
pub const AxisValueMap = struct {
    /// A normalized coordinate value obtained using default normalization.
    from_coordinate: i16,
    /// The modified, normalized coordinate value.
    to_coordinate: i16,

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

fn map_value(
    map: *const parser.LazyArray16(AxisValueMap),
    value: i16,
) ?i16 {
    // This code is based on harfbuzz implementation.

    if (map.len() == 0)
        return value;

    if (map.len() == 1) {
        const record = map.get(0) orelse unreachable;
        return value - record.from_coordinate + record.to_coordinate;
    }

    const record_0 = map.get(0) orelse unreachable;
    if (value <= record_0.from_coordinate)
        return value - record_0.from_coordinate + record_0.to_coordinate;

    var i: u16 = 1;
    while (i < map.len() and value > map.get(i).?.from_coordinate) i += 1;

    if (i == map.len()) i -= 1;

    const record_curr = map.get(i) orelse unreachable;
    const curr_from = record_curr.from_coordinate;
    const curr_to = record_curr.to_coordinate;
    if (value >= curr_from)
        return value - curr_from + curr_to;

    const record_prev = map.get(i - 1) orelse unreachable; // map of size 2 or longet
    const prev_from = record_prev.from_coordinate;
    const prev_to = record_prev.to_coordinate;
    if (prev_from == curr_from)
        return prev_to;

    const denom = @as(i32, curr_from) - @as(i32, prev_from);
    const k = (@as(i32, curr_to) - @as(i32, prev_to)) *
        (@as(i32, value) - @as(i32, prev_from)) +
        @divFloor(denom, 2);

    return std.math.cast(i16, @as(i32, prev_to) + @divFloor(k, denom));
}
