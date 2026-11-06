const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const avar = ttf.tables.avar;

/// `coordinate` mapped by an avar table of one axis whose map is `pairs`.
fn map(pairs: []const [2]i16, coordinate: i16) !i16 {
    var data: std.ArrayList(u8) = .fromOwnedSlice(try convert(&.{
        .{ .unt32 = 0x00010000 }, // version
        .{ .unt16 = 0 }, // reserved
        .{ .unt16 = 1 }, // axis count
        .{ .unt16 = @intCast(pairs.len) }, // axis 0's map count
    }));
    defer data.deinit(t.allocator);
    for (pairs) |pair| for (pair) |c|
        try data.appendSlice(t.allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, c)));

    const table = try avar.parse(data.items);
    var coordinates = [_]ttf.NormalizedCoordinate{.{ .inner = coordinate }};
    try table.map_coordinate(&coordinates, 0);
    return coordinates[0].inner;
}

test "an axis map past an i16" {
    // [KupCAD] Mapping 0 by the one pair -32768 to 0 overflowed the i16 it was computed in;
    // past an i16 is a map error, as an interpolation past one was.
    try t.expectError(error.MapError, map(&.{.{ -32768, 0 }}, 0));
}

test "an axis map interpolated past an i32" {
    // [KupCAD] Interpolating 1 between -32768 to -32768 and 32767 to 32767 overflowed the
    // i32 it was computed in.
    try t.expectEqual(1, map(&.{ .{ -32768, -32768 }, .{ 32767, 32767 } }, 1));
}
