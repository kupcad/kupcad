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
