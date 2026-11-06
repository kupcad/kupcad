const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const math = ttf.tables.math;

test "a constant past the end of the constants" {
    // [KupCAD] Reading a value record of four bytes where two are left sliced past the data.
    const data = try convert(&.{
        .{ .unt16 = 1 }, // major version
        .{ .unt16 = 0 }, // minor version
        .{ .unt16 = 10 }, // constants offset
        .{ .unt16 = 0 }, // glyph info offset
        .{ .unt16 = 0 }, // variants offset
        .{ .raw = &@as([10]u8, @splat(0)) }, // constants: up to the math leading's first half
    });
    defer t.allocator.free(data);

    const table = try math.parse(data);
    try t.expectEqual(0, table.constants.?.math_leading().value);
}

test "a math kern of 65535 heights" {
    // [KupCAD] Its number of kerns, one more than its heights, overflowed the u16.
    const data = try convert(&.{
        .{ .unt16 = 1 }, // major version
        .{ .unt16 = 0 }, // minor version
        .{ .unt16 = 0 }, // constants offset
        .{ .unt16 = 10 }, // glyph info offset
        .{ .unt16 = 0 }, // variants offset
        // Glyph info, at 10
        .{ .unt16 = 0 }, // italics corrections offset
        .{ .unt16 = 0 }, // top accent attachments offset
        .{ .unt16 = 0 }, // extended shapes offset
        .{ .unt16 = 8 }, // kern infos offset
        // Kern infos, at 18
        .{ .unt16 = 12 }, // coverage offset
        .{ .unt16 = 1 }, // count
        .{ .unt16 = 18 }, // record 0: top right
        .{ .unt16 = 0 }, // top left
        .{ .unt16 = 0 }, // bottom right
        .{ .unt16 = 0 }, // bottom left
        // Coverage: format 1, glyph 5
        .{ .unt16 = 1 },
        .{ .unt16 = 1 },
        .{ .unt16 = 5 },
        // Kern
        .{ .unt16 = 0xFFFF }, // height count
    });
    defer t.allocator.free(data);
    // Its heights, zeros, so the kerns after them are read
    const heights: [0xFFFF * 4]u8 = @splat(0);
    const kern = try std.mem.concat(t.allocator, u8, &.{ data, &heights });
    defer t.allocator.free(kern);

    const table = try math.parse(kern);
    const info = table.glyph_info.?.kern_infos.?.get(.{5}).?;
    try t.expectEqual(null, info.top_right);
}
