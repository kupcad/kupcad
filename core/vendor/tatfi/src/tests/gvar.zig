const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const gvar = ttf.tables.gvar;

/// The phantom points of glyph 0, an empty glyph, in a gvar table of one axis whose glyph 0
/// has `glyph_variation_data`, at `coordinate` on the axis.
fn phantom_points(glyph_variation_data: []const u8, coordinate: i16) !?ttf.PhantomPoints {
    const header = try convert(&.{
        .{ .unt32 = 0x00010000 }, // version
        .{ .unt16 = 1 }, // axis count
        .{ .unt16 = 0 }, // shared tuple count
        .{ .unt32 = 28 }, // offset to shared tuples
        .{ .unt16 = 1 }, // glyph count
        .{ .unt16 = 1 }, // flags: long offsets
        .{ .unt32 = 28 }, // offset to glyph variation data
        .{ .unt32 = 0 }, // glyph 0's offset
        .{ .unt32 = @intCast(glyph_variation_data.len) }, // its end
    });
    defer t.allocator.free(header);
    const data = try std.mem.concat(t.allocator, u8, &.{ header, glyph_variation_data });
    defer t.allocator.free(data);

    const table = try gvar.parse(data);
    const loca_table = try ttf.tables.loca.Table.parse(1, .short, &.{ 0, 0, 0, 0 });
    const glyf_table = ttf.tables.glyf.parse(loca_table, &.{});
    return table.phantom_points(t.allocator, glyf_table, &.{.{ .inner = coordinate }}, .{0});
}

test "a tuple whose shared tuple isn't there" {
    // [KupCAD] Slicing the shared tuples past their end panicked; ttf-parser's slice
    // returns None.
    const data = try convert(&.{
        .{ .unt16 = 1 }, // tuple variation count
        .{ .unt16 = 8 }, // offset to the serialized data
        .{ .unt16 = 0 }, // tuple 0's serialized data size
        .{ .unt16 = 0 }, // tuple 0's index: shared tuple 0, of none
    });
    defer t.allocator.free(data);

    try t.expectEqual(null, try phantom_points(data, 0));
}
