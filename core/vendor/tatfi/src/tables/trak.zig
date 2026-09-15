//! A [Tracking Table](
//! https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6trak.html) implementation.

const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const name = @import("name.zig");

const Table = @This();

/// Horizontal track data.
horizontal: TrackData,
/// Vertical track data.
vertical: TrackData,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    if (try s.read(u32) != 0x00010000) return error.ParseFail; // version

    if (try s.read(u16) != 0) return error.ParseFail; // format

    const hor_offset = try s.read_optional(parser.Offset16);
    const ver_offset = try s.read_optional(parser.Offset16);
    s.skip(u16); // reserved

    const horizontal: TrackData = if (hor_offset) |offset|
        try .parse(offset[0], data)
    else
        .{};
    const vertical: TrackData = if (ver_offset) |offset|
        try .parse(offset[0], data)
    else
        .{};

    return .{
        .horizontal = horizontal,
        .vertical = vertical,
    };
}

/// A track data.
pub const TrackData = struct {
    /// A list of tracks.
    tracks: Tracks = .{},
    /// A list of sizes.
    sizes: parser.LazyArray16(parser.Fixed) = .{},

    fn parse(
        offset: usize,
        data: []const u8,
    ) parser.Error!TrackData {
        var s = try parser.Stream.new_at(data, offset);

        const tracks_count = try s.read(u16);
        const sizes_count = try s.read(u16);
        const size_table_offset = try s.read(parser.Offset32); // Offset from start of the table.

        const tracks: Tracks = .{
            .data = data,
            .records = try s.read_array(TrackTableRecord, tracks_count),
            .sizes_count = sizes_count,
        };

        // TODO: Isn't the size table is directly after the tracks table?!
        //       Why we need an offset then?
        const sizes = s: {
            var subs = try parser.Stream.new_at(data, size_table_offset[0]);
            break :s try subs.read_array(parser.Fixed, sizes_count);
        };

        return .{
            .tracks = tracks,
            .sizes = sizes,
        };
    }
};

/// A list of tracks.
pub const Tracks = struct {
    data: []const u8 = &.{}, // the whole table
    records: parser.LazyArray16(TrackTableRecord) = .{},
    sizes_count: u16 = 0,

    /// Returns a track at index.
    pub fn get(
        self: Tracks,
        index: u16,
    ) ?Track {
        const record = self.records.get(index) orelse return null;
        const data = utils.slice(self.data, record.offset[0]) catch return null;
        var s = parser.Stream.new(data);
        return .{
            .value = record.value.value,
            .values = s.read_array(i16, self.sizes_count) catch return null,
            .name_index = record.name_id,
        };
    }

    pub fn iterator(
        tracks: Tracks,
    ) Iterator {
        return .{ .tracks = tracks };
    }

    pub const Iterator = struct {
        tracks: Tracks,
        index: u16 = 0,

        pub fn next(
            self: *Iterator,
        ) ?Track {
            if (self.index >= self.tracks.records.len()) return null;

            defer self.index += 1;
            return self.tracks.get(self.index);
        }
    };
};

const TrackTableRecord = struct {
    value: parser.Fixed,
    name_id: name.NameId,
    offset: parser.Offset16, // Offset from start of the table.

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

/// A single track.
pub const Track = struct {
    /// A track value.
    value: f32,
    /// The `name` table index for the track's name.
    name_index: name.NameId,
    /// A list of tracking values for each size.
    values: parser.LazyArray16(i16),
};
