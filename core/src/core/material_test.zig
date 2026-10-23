const std = @import("std");
const testing = std.testing;
const material = @import("material.zig");

test "parseHexColor: six or three hex digits after '#', nothing else" {
    const cases = [_]struct { text: []const u8, rgb: ?[3]u8 }{
        .{ .text = "#FF2000", .rgb = .{ 0xFF, 0x20, 0x00 } },
        .{ .text = "#aabbcc", .rgb = .{ 0xAA, 0xBB, 0xCC } },
        .{ .text = "#abc", .rgb = .{ 0xAA, 0xBB, 0xCC } }, // each digit doubled
        .{ .text = "#000", .rgb = .{ 0, 0, 0 } },
        .{ .text = "#+10000", .rgb = null }, // a sign is no digit
        .{ .text = "#1_0000", .rgb = null },
        .{ .text = "#gg0000", .rgb = null },
        .{ .text = "#abcd", .rgb = null },
        .{ .text = "abc", .rgb = null },
        .{ .text = "#", .rgb = null },
        .{ .text = "", .rgb = null },
    };
    for (cases) |case| {
        errdefer std.debug.print("color: \"{s}\"\n", .{case.text});
        try testing.expectEqual(case.rgb, material.parseHexColor(case.text));
    }
}
