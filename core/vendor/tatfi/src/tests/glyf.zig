const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const init_outline_builder = @import("cff1.zig").init_outline_builder;

test "endless_loop" {
    const data = "\x00\x01\x00\x00\x00\x0f\x00\x10\x00PTT-W\x002h\xd7\x81x\x00" ++
        "\x00\x00?L\xbaN\x00c\x9a\x9e\x8f\x96\xe3\xfeu\xff\x00\xb2\x00@\x03\x00\xb8" ++
        "cvt 5:\x00\x00\x00\xb5\xf8\x01\x00\x03\x9ckEr\x92\xd7\xe6\x98M\xdc\x00\x00" ++
        "\x03\xe0\x00\x00\x00dglyf\"\t\x15`\x00\x00\x03\xe0\x00\x00\x00dglyf\"\t\x15" ++
        "`\x00\x00\x00 \x00\x00\x00\xfc\x97\x9fmx\x87\xc9\xc8\xfe\x00\x00\xbad\xff" ++
        "\xff\xf1\xc8head\xc7\x17\xce[\x00\x00\x00\xfc\x00\x00\x006hhea\x03\xc6\x05" ++
        "\xe4\x00\x00\x014\x00\x00\x00$hmtx\xc9\xfdq\xed\x00\x00\xb5\xf8\x01\x00\x03" ++
        "\x9ckEr\x92\xd7\xe6\xdch\x00\x00\xc9d\x00\x00\x04 loca\x00M\x82\x11\x00\x00" ++
        "\x00\x06\x00\x00\x00\xa0maxp\x17\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00 name" ++
        "\xf4\xd6\xfe\xad\x00OTTO\x00\x02gpost5;5\xe1\x00\x00\xb0P\x00\x00\x01\xf0perp%" ++
        "\xb0{\x04\x93D\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x01\x00\x00\xe1!yf%1" ++
        "\x08\x95\x00\x00\x00\x00\x00\xaa\x06\x80fmtx\x02\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00a\xcc\xff" ++
        "\xce\x03CCCCCCCCC\x00\x00\x00\x00\x00C\x00\x00\x00\x00\xb5\xf8\x01\x00\x00\x9c";

    const face = try ttf.Face.parse(data, 0);

    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    _ = face.outline_glyph(t.allocator, .{0}, builder);
}

test "a flag repeated 255 times" {
    // One contour of 300 points: a flag repeated 255 more times (256 points), then one
    // repeated 43 more (44), each on the curve with one-byte x and y. A repeat count of
    // 255 plus the flag itself overflowed the u8 it was read as (KupCAD's font fuzz target
    // found it).
    const on_curve_short_repeated = 0x01 | 0x02 | 0x04 | 0x08;
    const flags = "\x01\x2b" ++ // the contour's last point, 299
        "\x00\x00" ++ // no instructions
        [_]u8{ on_curve_short_repeated, 255, on_curve_short_repeated, 43 };
    const coords: [600]u8 = @splat(1);
    const data = flags ++ coords;

    var points = try ttf.tables.glyf.parse_simple_outline(data, 1);
    var count: usize = 0;
    while (points.next()) |_| count += 1;
    try t.expectEqual(300, count);
}

test "the points of a composite glyph of 65536 components" {
    // [KupCAD] Counting the components overflowed their u16 count; it wraps, as
    // ttf-parser's `as u16` does.
    var glyph: std.ArrayList(u8) = .empty;
    defer glyph.deinit(t.allocator);
    try glyph.appendSlice(t.allocator, &[_]u8{ 0xFF, 0xFF } ++ @as([8]u8, @splat(0))); // composite, bbox
    // Each of glyph 1, no arguments; all but the last say more follow
    for (0..0x10000) |i| try glyph.appendSlice(t.allocator, &.{ 0, if (i < 0xFFFF) 0x20 else 0, 0, 1 });

    var loca_data: [8]u8 = undefined;
    std.mem.writeInt(u32, loca_data[0..4], 0, .big);
    std.mem.writeInt(u32, loca_data[4..8], @intCast(glyph.items.len), .big);
    const loca_table = try ttf.tables.loca.Table.parse(1, .long, &loca_data);
    const glyf_table = ttf.tables.glyf.parse(loca_table, glyph.items);
    try t.expectEqual(0, glyf_table.outline_points(.{0}));
}
