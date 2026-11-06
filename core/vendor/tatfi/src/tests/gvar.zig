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

test "an intermediate region from -32768 to 0" {
    // [KupCAD] The region's end minus its peak, 0 - -32768, overflowed the i16s.
    const data = try convert(&.{
        .{ .unt16 = 1 }, // tuple variation count
        .{ .unt16 = 10 }, // offset to the serialized data
        .{ .unt16 = 0 }, // tuple 0's serialized data size
        .{ .unt16 = 0xC000 }, // tuple 0's index: an embedded peak and an intermediate region
        .{ .int16 = -32768 }, // peak
        .{ .int16 = -32768 }, // start
        .{ .int16 = 0 }, // end
    });
    defer t.allocator.free(data);

    // The tuple's scalar is 0, so it's skipped, and the phantom points don't move
    try t.expectEqual(std.mem.zeroes(ttf.PhantomPoints), try phantom_points(data, 0));
}

test "a composite glyph of 65536 components" {
    // [KupCAD] Counting the components overflowed their u16 count; it wraps, as
    // ttf-parser's `as u16` does.
    var glyph: std.ArrayList(u8) = .fromOwnedSlice(try convert(&.{
        .{ .int16 = -1 }, // number of contours: a composite glyph
        .{ .raw = &@as([8]u8, @splat(0)) }, // bounding box
    }));
    defer glyph.deinit(t.allocator);
    // Each of glyph 1, no arguments; all but the last say more follow
    for (0..0x10000) |i| try glyph.appendSlice(t.allocator, &.{ 0, if (i < 0xFFFF) 0x20 else 0, 0, 1 });

    var loca_data: [8]u8 = undefined;
    std.mem.writeInt(u32, loca_data[0..4], 0, .big);
    std.mem.writeInt(u32, loca_data[4..8], @intCast(glyph.items.len), .big);
    const loca_table = try ttf.tables.loca.Table.parse(1, .long, &loca_data);
    const glyf_table = ttf.tables.glyf.parse(loca_table, glyph.items);

    // A gvar table of one axis whose glyph 0 has no variation data
    const data = try convert(&.{
        .{ .unt32 = 0x00010000 }, // version
        .{ .unt16 = 1 }, // axis count
        .{ .unt16 = 0 }, // shared tuple count
        .{ .unt32 = 28 }, // offset to shared tuples
        .{ .unt16 = 1 }, // glyph count
        .{ .unt16 = 1 }, // flags: long offsets
        .{ .unt32 = 28 }, // offset to glyph variation data
        .{ .unt32 = 0 }, // glyph 0's offset
        .{ .unt32 = 0 }, // its end
    });
    defer t.allocator.free(data);
    const table = try gvar.parse(data);

    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = @import("cff1.zig").init_outline_builder(&writer.writer);
    try t.expectEqual(null, table.outline(t.allocator, &glyf_table, &.{.{ .inner = 0 }}, .{0}, builder));
}
