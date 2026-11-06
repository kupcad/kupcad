const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const Unit = @import("main.zig").Unit;
const gpos = ttf.tables.gpos;

/// A pair adjustment subtable (format 1) for first glyph 5, from `value_formats` and the
/// bytes of its one PairSet, which starts at offset 18.
fn pair_subtable(value_formats: [2]u16, pair_set: []const Unit) ![]u8 {
    var units: std.ArrayList(Unit) = .empty;
    defer units.deinit(t.allocator);
    try units.appendSlice(t.allocator, &.{
        .{ .unt16 = 1 }, // format
        .{ .unt16 = 12 }, // coverage offset
        .{ .unt16 = value_formats[0] },
        .{ .unt16 = value_formats[1] },
        .{ .unt16 = 1 }, // pair set count
        .{ .unt16 = 18 }, // pair set offset
        // Coverage: format 1, glyph 5
        .{ .unt16 = 1 },
        .{ .unt16 = 1 },
        .{ .unt16 = 5 },
    });
    try units.appendSlice(t.allocator, pair_set);
    return convert(units.items);
}

/// The value records of glyphs 5 and `second`.
fn pair(data: []const u8, second: u16) !struct { gpos.ValueRecord, gpos.ValueRecord } {
    const subtable = try gpos.PositioningSubtable.parse(data, 2);
    const set = subtable.pair.format1.sets.get(subtable.coverage().get(.{5}).?).?;
    return set.get(.{second});
}

test "pair set: an empty second value format reads the first glyph's value only" {
    // Kerning moves the first glyph alone: the second record took the first's format and
    // read past the record, so no pair was found.
    const data = try pair_subtable(.{ 0x0004, 0 }, &.{
        .{ .unt16 = 2 }, // pair value count
        .{ .unt16 = 7 },
        .{ .int16 = -80 },
        .{ .unt16 = 9 },
        .{ .int16 = -40 },
    });
    defer t.allocator.free(data);

    try t.expectEqual(-80, (try pair(data, 7))[0].x_advance);
    try t.expectEqual(-40, (try pair(data, 9))[0].x_advance);
    try t.expectError(error.ParseFail, pair(data, 8));
}

test "pair set: the second value record has its own format" {
    const data = try pair_subtable(.{ 0x0004, 0x0001 }, &.{
        .{ .unt16 = 1 },
        .{ .unt16 = 7 },
        .{ .int16 = -80 }, // first: x advance
        .{ .int16 = 15 }, // second: x placement
    });
    defer t.allocator.free(data);

    const first, const second = try pair(data, 7);
    try t.expectEqual(-80, first.x_advance);
    try t.expectEqual(0, first.x_placement);
    try t.expectEqual(15, second.x_placement);
    try t.expectEqual(0, second.x_advance);
}

test "pair set: a device offset is from the start of the pair set" {
    const data = try pair_subtable(.{ 0x0044, 0 }, &.{
        .{ .unt16 = 1 },
        .{ .unt16 = 7 },
        .{ .int16 = -80 },
        .{ .unt16 = 8 }, // x advance device, 8 bytes into the pair set
        // Device: a variation index
        .{ .unt16 = 1 },
        .{ .unt16 = 2 },
        .{ .unt16 = 0x8000 },
    });
    defer t.allocator.free(data);

    const first, _ = try pair(data, 7);
    try t.expectEqual(-80, first.x_advance);
    const device = first.x_advance_device.?.variation;
    try t.expectEqual(1, device.outer_index);
    try t.expectEqual(2, device.inner_index);
}

test "a device table that ends before it starts" {
    // [KupCAD] Its count of deltas underflowed: end size minus start size, in u16.
    try t.expectError(error.ParseFail, gpos.Device.parse(&.{ 0, 5, 0, 1, 0, 1 }));
}

test "a device table of every size" {
    // [KupCAD] Its count of deltas overflowed: 0xFFFF minus 0 plus one, in u16.
    // Format 1: eight two-bit deltas a word, 65536 sizes in 8192 words
    const data: [6 + 0x4000]u8 = .{ 0, 0, 0xFF, 0xFF, 0, 1 } ++ @as([0x4000]u8, @splat(0));
    const device = try gpos.Device.parse(&data);
    try t.expectEqual(0x2000, device.hinting.delta_values.len());
}

test "a single adjustment of every value" {
    // [KupCAD] A value format of all eight flags overflowed the size of its record, the u4
    // @popCount gives times two.
    const data = try convert(&.{
        .{ .unt16 = 2 }, // format
        .{ .unt16 = 24 }, // coverage offset
        .{ .unt16 = 0x00FF }, // value format: all eight values
        .{ .unt16 = 1 }, // value count
        .{ .raw = &@as([16]u8, @splat(0)) }, // value 0: zeros, no devices
        // Coverage: format 1, glyph 5
        .{ .unt16 = 1 },
        .{ .unt16 = 1 },
        .{ .unt16 = 5 },
    });
    defer t.allocator.free(data);

    const subtable = try gpos.PositioningSubtable.parse(data, 1);
    try t.expectEqual(0, subtable.single.format2.values.get(0).?.x_advance);
}

test "an extension of an extension" {
    // [KupCAD] An extension subtable pointing to itself recursed until the stack
    // overflowed.
    const data = try convert(&.{
        .{ .unt16 = 1 }, // format
        .{ .unt16 = 9 }, // extension lookup type: an extension
        .{ .unt32 = 0 }, // extension offset: this subtable
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, gpos.PositioningSubtable.parse(data, 9));
}
