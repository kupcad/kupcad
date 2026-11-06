const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const stat = ttf.tables.stat;

/// A STAT table (1.1) of the axes wght and wdth, with a format 1 axis value of 400 for wght and
/// one of 100 for wdth, at offsets 4 and 16 from their offsets' list, at 36.
fn two_axes() ![]u8 {
    return convert(&.{
        .{ .unt16 = 1 }, // major version
        .{ .unt16 = 1 }, // minor version
        .{ .unt16 = 8 }, // design axis size
        .{ .unt16 = 2 }, // design axis count
        .{ .unt32 = 20 }, // design axes offset
        .{ .unt16 = 2 }, // axis value count
        .{ .unt32 = 36 }, // offset to the axis value offsets
        .{ .unt16 = 2 }, // elided fallback name ID
        // Design axes, at 20
        .{ .raw = "wght" },
        .{ .unt16 = 256 }, // name ID
        .{ .unt16 = 0 }, // ordering
        .{ .raw = "wdth" },
        .{ .unt16 = 257 }, // name ID
        .{ .unt16 = 1 }, // ordering
        // Axis value offsets, at 36
        .{ .unt16 = 4 },
        .{ .unt16 = 16 },
        // Axis value 0, at 40
        .{ .unt16 = 1 }, // format
        .{ .unt16 = 0 }, // axis index: wght
        .{ .unt16 = 0 }, // flags
        .{ .unt16 = 258 }, // value name ID
        .{ .fixed = 400 },
        // Axis value 1, at 52
        .{ .unt16 = 1 }, // format
        .{ .unt16 = 1 }, // axis index: wdth
        .{ .unt16 = 0 }, // flags
        .{ .unt16 = 259 }, // value name ID
        .{ .fixed = 100 },
    });
}

test "axis values are read from their offsets' list" {
    // [KupCAD] Their offsets were taken from the start of the table, not from the start of
    // their list, as ttf-parser and the spec have them.
    const data = try two_axes();
    defer t.allocator.free(data);

    const table = try stat.parse(data);
    var subtables = table.subtables();
    try t.expectEqual(400, subtables.next().?.format1.value.value);
    try t.expectEqual(100, subtables.next().?.format1.value.value);
    try t.expectEqual(null, subtables.next());
}

test "an axis's subtable is that axis's" {
    // [KupCAD] A format 1 or 3 subtable of the axis was skipped and one of another axis
    // returned (`==` where ttf-parser has `!=`).
    const data = try two_axes();
    defer t.allocator.free(data);

    const table = try stat.parse(data);
    const wdth = table.subtable_for_axis(.from_bytes("wdth"), null).?;
    try t.expectEqual(1, wdth.format1.axis_index);
    try t.expectEqual(100, wdth.format1.value.value);
    try t.expectEqual(400, table.subtable_for_axis(.from_bytes("wght"), null).?.format1.value.value);
}
