const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;

const Table = ttf.tables.feat;

test "basic" {
    const data = try convert(&.{
        .{ .fixed = 1.0 }, // version
        .{ .unt16 = 4 }, // number of features
        .{ .unt16 = 0 }, // reserved
        .{ .unt32 = 0 }, // reserved
        // Feature Name [0]
        .{ .unt16 = 0 }, // feature
        .{ .unt16 = 1 }, // number of settings
        .{ .unt32 = 60 }, // offset to settings table
        .{ .unt16 = 0 }, // flags: none
        .{ .unt16 = 260 }, // name index
        // Feature Name [1]
        .{ .unt16 = 1 }, // feature
        .{ .unt16 = 1 }, // number of settings
        .{ .unt32 = 64 }, // offset to settings table
        .{ .unt16 = 0 }, // flags: none
        .{ .unt16 = 256 }, // name index
        // Feature Name [2]
        .{ .unt16 = 3 }, // feature
        .{ .unt16 = 3 }, // number of settings
        .{ .unt32 = 68 }, // offset to settings table
        .{ .raw = &.{ 0x80, 0x00 } }, // flags: exclusive
        .{ .unt16 = 262 }, // name index
        // Feature Name [3]
        .{ .unt16 = 6 }, // feature
        .{ .unt16 = 2 }, // number of settings
        .{ .unt32 = 80 }, // offset to settings table
        .{ .raw = &.{ 0xC0, 0x01 } }, // flags: exclusive and other
        .{ .unt16 = 258 }, // name index
        // Setting Name [0]
        .{ .unt16 = 0 }, // setting
        .{ .unt16 = 261 }, // name index
        // Setting Name [1]
        .{ .unt16 = 2 }, // setting
        .{ .unt16 = 257 }, // name index
        // Setting Name [2]
        .{ .unt16 = 0 }, // setting
        .{ .unt16 = 268 }, // name index
        .{ .unt16 = 3 }, // setting
        .{ .unt16 = 264 }, // name index
        .{ .unt16 = 4 }, // setting
        .{ .unt16 = 265 }, // name index
        // Setting Name [3]
        .{ .unt16 = 0 }, // setting
        .{ .unt16 = 259 }, // name index
        .{ .unt16 = 1 }, // setting
        .{ .unt16 = 260 }, // name index
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    try t.expectEqual(4, table.names.records.len());

    const feature0 = table.names.get(0).?;
    try t.expectEqual(0, feature0.feature);
    try t.expectEqual(1, feature0.setting_names.len());
    try t.expectEqual(false, feature0.exclusive);
    try t.expectEqual(260, @intFromEnum(feature0.name_index));

    const feature2 = table.names.get(2).?;
    try t.expectEqual(3, feature2.feature);
    try t.expectEqual(3, feature2.setting_names.len());
    try t.expectEqual(true, feature2.exclusive);

    try t.expectEqual(3, feature2.setting_names.get(1).?.setting);
    try t.expectEqual(264, @intFromEnum(feature2.setting_names.get(1).?.name_index));

    const feature3 = table.names.get(3).?;
    try t.expectEqual(1, feature3.default_setting_index);
    try t.expectEqual(true, feature3.exclusive);
}
