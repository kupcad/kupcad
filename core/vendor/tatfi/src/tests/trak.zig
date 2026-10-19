const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;

const Table = ttf.tables.trak;

test "empty" {
    const data = try convert(&.{
        .{ .fixed = 1.0 }, // version
        .{ .unt16 = 0 }, // format
        .{ .unt16 = 0 }, // horizontal data offset
        .{ .unt16 = 0 }, // vertical data offset
        .{ .unt16 = 0 }, // padding
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    try t.expectEqual(0, table.horizontal.tracks.records.len());
    try t.expectEqual(0, table.horizontal.sizes.len());
    try t.expectEqual(0, table.vertical.tracks.records.len());
    try t.expectEqual(0, table.vertical.sizes.len());
}

test "basic" {
    const data = try convert(&.{
        .{ .fixed = 1.0 }, // version
        .{ .unt16 = 0 }, // format
        .{ .unt16 = 12 }, // horizontal data offset
        .{ .unt16 = 0 }, // vertical data offset
        .{ .unt16 = 0 }, // padding
        // TrackData
        .{ .unt16 = 3 }, // number of tracks
        .{ .unt16 = 2 }, // number of sizes
        .{ .unt32 = 44 }, // offset to size table
        // TrackTableEntry [0]
        .{ .fixed = -1.0 }, // track
        .{ .unt16 = 256 }, // name index
        .{ .unt16 = 52 }, // offset of the two per-size tracking values
        // TrackTableEntry [1]
        .{ .fixed = 0.0 }, // track
        .{ .unt16 = 258 }, // name index
        .{ .unt16 = 60 }, // offset of the two per-size tracking values
        // TrackTableEntry [2]
        .{ .fixed = 1.0 }, // track
        .{ .unt16 = 257 }, // name index
        .{ .unt16 = 56 }, // offset of the two per-size tracking values
        // Size [0]
        .{ .fixed = 12.0 }, // points
        // Size [1]
        .{ .fixed = 24.0 }, // points
        // Per-size tracking values.
        .{ .int16 = -15 },
        .{ .int16 = -7 },
        .{ .int16 = 50 },
        .{ .int16 = 20 },
        .{ .int16 = 0 },
        .{ .int16 = 0 },
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);

    try t.expectEqual(3, table.horizontal.tracks.records.len());
    try t.expectEqual(-1.0, table.horizontal.tracks.get(0).?.value);
    try t.expectEqual(0.0, table.horizontal.tracks.get(1).?.value);
    try t.expectEqual(1.0, table.horizontal.tracks.get(2).?.value);
    try t.expectEqual(256, @intFromEnum(table.horizontal.tracks.get(0).?.name_index));
    try t.expectEqual(258, @intFromEnum(table.horizontal.tracks.get(1).?.name_index));
    try t.expectEqual(257, @intFromEnum(table.horizontal.tracks.get(2).?.name_index));
    try t.expectEqual(2, table.horizontal.tracks.get(0).?.values.len());
    try t.expectEqual(-15, table.horizontal.tracks.get(0).?.values.get(0).?);
    try t.expectEqual(-7, table.horizontal.tracks.get(0).?.values.get(1).?);
    try t.expectEqual(2, table.horizontal.tracks.get(1).?.values.len());
    try t.expectEqual(0, table.horizontal.tracks.get(1).?.values.get(0).?);
    try t.expectEqual(0, table.horizontal.tracks.get(1).?.values.get(1).?);
    try t.expectEqual(2, table.horizontal.tracks.get(2).?.values.len());
    try t.expectEqual(50, table.horizontal.tracks.get(2).?.values.get(0).?);
    try t.expectEqual(20, table.horizontal.tracks.get(2).?.values.get(1).?);
    try t.expectEqual(2, table.horizontal.sizes.len());
    try t.expectEqual(12.0, table.horizontal.sizes.get(0).?.value);
    try t.expectEqual(24.0, table.horizontal.sizes.get(1).?.value);

    try t.expectEqual(0, table.vertical.tracks.records.len());
    try t.expectEqual(0, table.vertical.sizes.len());
}
