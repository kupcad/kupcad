//! [ARS] integration tests live here.

const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;

test {
    _ = @import("aat.zig");
    _ = @import("avar.zig");
    _ = @import("ankr.zig");
    _ = @import("cblc.zig");
    _ = @import("cff1.zig");
    _ = @import("cff2.zig");
    _ = @import("cmap.zig");
    _ = @import("colr.zig");
    _ = @import("feat.zig");
    _ = @import("glyf.zig");
    _ = @import("gvar.zig");
    _ = @import("gpos.zig");
    _ = @import("hmtx.zig");
    _ = @import("loca.zig");
    _ = @import("math.zig");
    _ = @import("maxp.zig");
    _ = @import("os2.zig");
    _ = @import("sbix.zig");
    _ = @import("trak.zig");
    _ = @import("var_store.zig");

    _ = @import("bitmap.zig");
}

pub const Unit = union(enum) {
    raw: []const u8,
    true_type_magic,
    open_type_magic,
    font_collection_magic,
    int8: i8,
    unt8: u8,
    int16: i16,
    unt16: u16,
    int32: i32,
    unt32: u32,
    fixed: f32,
    cff_int: i32,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .raw => |bytes| try writer.writeAll(bytes),
            .true_type_magic => try writer.writeAll(&.{ 0x00, 0x01, 0x00, 0x00 }),
            .open_type_magic => try writer.writeAll(&.{ 0x4F, 0x54, 0x54, 0x4F }),
            .font_collection_magic => try writer.writeAll(&.{ 0x74, 0x74, 0x63, 0x66 }),
            .fixed => |n| {
                const buf = try writer.writableArray(@sizeOf(i32));
                std.mem.writeInt(i32, buf, std.math.lossyCast(i32, n * 65536), .big);
            },
            .cff_int => |n| switch (n) {
                -107...107 => {
                    const buf = try writer.writableArray(1);
                    std.mem.writeInt(u8, buf, std.math.lossyCast(u8, n + 139), .big);
                },
                108...1131 => {
                    const buf = try writer.writableArray(2);
                    std.mem.writeInt(u16, buf, std.math.lossyCast(u16, n + 63124), .big);
                },
                -1131...-108 => {
                    const buf = try writer.writableArray(2);
                    std.mem.writeInt(u16, buf, std.math.lossyCast(u16, -n + 64148), .big);
                },
                -32768...-1132, 1132...32767 => {
                    try writer.writeByte(28);
                    const buf = try writer.writableArray(2);
                    std.mem.writeInt(i16, buf, std.math.lossyCast(i16, n), .big);
                },
                else => {
                    try writer.writeByte(29);
                    const buf = try writer.writableArray(4);
                    std.mem.writeInt(i32, buf, n, .big);
                },
            },
            inline else => |n| {
                const buf = try writer.writableArray(@sizeOf(@TypeOf(n)));
                std.mem.writeInt(@TypeOf(n), buf, n, .big);
            },
        }
    }
};

pub fn convert(units: []const Unit) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(t.allocator);
    defer w.deinit();

    for (units) |v| try w.writer.print("{f}", .{v});

    return try w.toOwnedSlice();
}

/// A font of `tables`, given in the order of their tags, as a table directory must have them.
pub fn font_of(tables: []const struct { *const [4]u8, []const u8 }) ![]u8 {
    var data: std.ArrayList(u8) = .fromOwnedSlice(try convert(&.{
        .true_type_magic, // magic
        .{ .unt16 = @intCast(tables.len) }, // numTables
        .{ .unt16 = 0 }, // searchRange
        .{ .unt16 = 0 }, // entrySelector
        .{ .unt16 = 0 }, // rangeShift
    }));
    errdefer data.deinit(t.allocator);
    var offset: u32 = @intCast(12 + 16 * tables.len);
    for (tables) |table| {
        const record = try convert(&.{
            .{ .raw = table[0] }, // tag
            .{ .unt32 = 0 }, // checksum
            .{ .unt32 = offset }, // offset
            .{ .unt32 = @intCast(table[1].len) }, // length
        });
        defer t.allocator.free(record);
        try data.appendSlice(t.allocator, record);
        offset += @intCast(table[1].len);
    }
    for (tables) |table| try data.appendSlice(t.allocator, table[1]);
    return data.toOwnedSlice(t.allocator);
}

/// A head table whose global bounding box is `bbox`.
pub fn head_table(bbox: ttf.Rect) ![]u8 {
    var data = try t.allocator.alloc(u8, 54);
    @memset(data, 0);
    std.mem.writeInt(u16, data[18..20], 1000, .big); // units per em
    std.mem.writeInt(i16, data[36..38], bbox.x_min, .big);
    std.mem.writeInt(i16, data[38..40], bbox.y_min, .big);
    std.mem.writeInt(i16, data[40..42], bbox.x_max, .big);
    std.mem.writeInt(i16, data[42..44], bbox.y_max, .big);
    return data;
}

/// An hhea or vhea table of `ascender` and `descender`, with one metric.
pub fn hhea_table(ascender: i16, descender: i16) ![]u8 {
    var data = try t.allocator.alloc(u8, 36);
    @memset(data, 0);
    std.mem.writeInt(i16, data[4..6], ascender, .big);
    std.mem.writeInt(i16, data[6..8], descender, .big);
    std.mem.writeInt(u16, data[34..36], 1, .big); // number of metrics
    return data;
}

/// A maxp table of one glyph.
pub const maxp_table = [_]u8{ 0x00, 0x00, 0x50, 0x00, 0x00, 0x01 };

test "metrics past an i16" {
    // [KupCAD] The face's height and vertical height, and its bounding box's width and
    // height, overflowed the i16s they were computed in; they saturate.
    const head = try head_table(.{ .x_min = -32768, .y_min = -2, .x_max = 32767, .y_max = 32767 });
    defer t.allocator.free(head);
    const hhea = try hhea_table(32767, -1);
    defer t.allocator.free(hhea);
    const vhea = try hhea_table(32767, 1);
    defer t.allocator.free(vhea);
    const data = try font_of(&.{ .{ "head", head }, .{ "hhea", hhea }, .{ "maxp", &maxp_table }, .{ "vhea", vhea } });
    defer t.allocator.free(data);

    const face = try ttf.Face.parse(data, 0);
    try t.expectEqual(32767, face.height());
    try t.expectEqual(32767, face.vertical_height());
    try t.expectEqual(32767, face.global_bounding_box().width());
    try t.expectEqual(32767, face.global_bounding_box().height());
}

/// An HVAR or VVAR table of `maps` mappings, each but the first (advances, directly by glyph
/// ID) mapping glyph 0 to an item whose delta is +1 in every region.
fn metrics_variations(maps: u8) ![]u8 {
    const ivs_offset: u32 = 8 + 4 * @as(u32, maps);
    const map_offset = ivs_offset + 32;
    var units: std.ArrayList(Unit) = .empty;
    defer units.deinit(t.allocator);
    try units.appendSlice(t.allocator, &.{
        .{ .unt32 = 0x00010000 }, // version
        .{ .unt32 = ivs_offset }, // item variation store offset
        .{ .unt32 = 0 }, // advance mapping: none
    });
    for (1..maps) |_| try units.append(t.allocator, .{ .unt32 = map_offset });
    try units.appendSlice(t.allocator, &.{
        // Item variation store
        .{ .unt16 = 1 }, // format
        .{ .unt32 = 12 }, // offset to the region list
        .{ .unt16 = 1 }, // number of item variation data
        .{ .unt32 = 22 }, // offset to item variation data 0
        // Region list: one axis, one region from 0 to 0, which every coordinate is in
        .{ .unt16 = 1 },
        .{ .unt16 = 1 },
        .{ .int16 = 0 },
        .{ .int16 = 0 },
        .{ .int16 = 0 },
        // Item variation data 0: one item of one word delta
        .{ .unt16 = 1 }, // item count
        .{ .unt16 = 1 }, // word delta count
        .{ .unt16 = 1 }, // region index count
        .{ .unt16 = 0 }, // region index 0
        .{ .int16 = 1 }, // item 0's delta
        // Delta set index map: glyph 0 to item 0
        .{ .unt8 = 0 }, // format
        .{ .unt8 = 0 }, // entry format
        .{ .unt16 = 1 }, // map count
        .{ .unt8 = 0 }, // entry 0
    });
    return convert(units.items);
}

test "variable metrics past their type" {
    // [KupCAD] A metric from the font plus its variation's offset overflowed the u16 or i16
    // they were added in; they add in f32, as ttf-parser does, and past the type are null.
    const head = try head_table(.{ .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 });
    defer t.allocator.free(head);
    const hhea = try hhea_table(800, -200);
    defer t.allocator.free(hhea);
    const hvar = try metrics_variations(3);
    defer t.allocator.free(hvar);
    const vvar = try metrics_variations(4);
    defer t.allocator.free(vvar);
    const fvar = try convert(&.{
        .{ .unt32 = 0x00010000 }, // version
        .{ .unt16 = 16 }, // offset to the axes
        .{ .unt16 = 2 }, // reserved
        .{ .unt16 = 1 }, // axis count
        .{ .unt16 = 20 }, // axis size
        .{ .unt16 = 0 }, // instance count
        .{ .unt16 = 8 }, // instance size
        .{ .raw = "wght" }, // axis 0
        .{ .fixed = 0 }, // min
        .{ .fixed = 0 }, // default
        .{ .fixed = 1 }, // max
        .{ .unt16 = 0 }, // flags
        .{ .unt16 = 0 }, // name ID
    });
    defer t.allocator.free(fvar);
    const metrics = [_]u8{ 0xFF, 0xFF, 0x7F, 0xFF }; // advance 65535, bearing 32767
    const vorg = [_]u8{ 0, 1, 0, 0, 0x7F, 0xFF, 0, 0 }; // default origin 32767
    const data = try font_of(&.{
        .{ "HVAR", hvar },     .{ "VORG", &vorg },       .{ "VVAR", vvar },
        .{ "fvar", fvar },     .{ "head", head },        .{ "hhea", hhea },
        .{ "hmtx", &metrics }, .{ "maxp", &maxp_table }, .{ "vhea", hhea },
        .{ "vmtx", &metrics },
    });
    defer t.allocator.free(data);

    const face = try ttf.Face.parse(data, 0);
    try t.expect(face.is_variable());
    try t.expectEqual(null, face.glyph_hor_advance(t.allocator, .{0}));
    try t.expectEqual(null, face.glyph_ver_advance(t.allocator, .{0}));
    try t.expectEqual(null, face.glyph_hor_side_bearing(.{0}));
    try t.expectEqual(null, face.glyph_ver_side_bearing(.{0}));
    try t.expectEqual(null, face.glyph_y_origin(.{0}));
}

test "empty font" {
    const f = ttf.Face.parse(&.{}, 0);
    try t.expectError(error.UnknownMagic, f);
}

test "zero tables" {
    const data = try convert(&.{
        .true_type_magic, // magic
        .{ .unt16 = 0 }, // numTables
        .{ .unt16 = 0 }, // searchRange
        .{ .unt16 = 0 }, // entrySelector
        .{ .unt16 = 0 }, // rangeShift
    });
    defer t.allocator.free(data);

    try t.expectError(error.NoHeadTable, ttf.Face.parse(data, 0));
}

test "tables count overflow" {
    const data = try convert(&.{
        .true_type_magic, // magic
        .{ .unt16 = std.math.maxInt(u16) }, // numTables
        .{ .unt16 = 0 }, // searchRange
        .{ .unt16 = 0 }, // entrySelector
        .{ .unt16 = 0 }, // rangeShift
    });
    defer t.allocator.free(data);

    try t.expectError(error.MalformedFont, ttf.Face.parse(data, 0));
}

test "a font of 65535 tables" {
    // [KupCAD] Collecting the tables went one past the last of 65535 records, overflowing
    // the iterator's u16 index.
    var data: std.ArrayList(u8) = .fromOwnedSlice(try convert(&.{
        .true_type_magic, // magic
        .{ .unt16 = std.math.maxInt(u16) }, // numTables
        .{ .unt16 = 0 }, // searchRange
        .{ .unt16 = 0 }, // entrySelector
        .{ .unt16 = 0 }, // rangeShift
    }));
    defer data.deinit(t.allocator);
    try data.appendNTimes(t.allocator, 0, std.math.maxInt(u16) * 16); // empty table records

    try t.expectError(error.NoHeadTable, ttf.Face.parse(data.items, 0));
}

test "empty font collection" {
    const data = try convert(&.{
        .font_collection_magic, // magic
        .{ .unt16 = 0 }, // majorVersion
        .{ .unt16 = 0 }, // minorVersion
        .{ .unt32 = 0 }, // numFonts
    });
    defer t.allocator.free(data);

    try t.expectEqual(0, ttf.fonts_in_collection(data));
    try t.expectError(error.FaceIndexOutOfBounds, ttf.Face.parse(data, 0));
}

test "font collection num fonts overflow" {
    const data = try convert(&.{
        .font_collection_magic, // magic
        .{ .unt16 = 0 }, // majorVersion
        .{ .unt16 = 0 }, // minorVersion
        .{ .unt32 = std.math.maxInt(u32) }, // numFonts
    });
    defer t.allocator.free(data);

    try t.expectEqual(std.math.maxInt(u32), ttf.fonts_in_collection(data));
    // [KupCAD] an error, where ttf-parser's debug assert panics: 16 bytes a script imports
    // must not crash it
    try t.expectError(error.MalformedFont, ttf.Face.parse(data, 0));
}

test "font index overflow" {
    const data = try convert(&.{
        .font_collection_magic, // magic
        .{ .unt16 = 0 }, // majorVersion
        .{ .unt16 = 0 }, // minorVersion
        .{ .unt32 = 1 }, // numFonts
        .{ .unt32 = 12 }, // offset [0]
    });
    defer t.allocator.free(data);

    try t.expectEqual(1, ttf.fonts_in_collection(data));
    try t.expectError(
        error.FaceIndexOutOfBounds,
        ttf.Face.parse(data, std.math.maxInt(u32)),
    );
}

test "font index overflow on regular font" {
    const data = try convert(&.{
        .true_type_magic, // magic
        .{ .unt16 = 0 }, // numTables
        .{ .unt16 = 0 }, // searchRange
        .{ .unt16 = 0 }, // entrySelector
        .{ .unt16 = 0 }, // rangeShift
    });
    defer t.allocator.free(data);

    try t.expectEqual(null, ttf.fonts_in_collection(data));
    try t.expectError(error.FaceIndexOutOfBounds, ttf.Face.parse(data, 1));
}
