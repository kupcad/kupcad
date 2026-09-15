//! [ARS] integration tests live here.

const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;

test {
    _ = @import("aat.zig");
    _ = @import("ankr.zig");
    _ = @import("cff1.zig");
    _ = @import("cmap.zig");
    _ = @import("colr.zig");
    _ = @import("feat.zig");
    _ = @import("glyf.zig");
    _ = @import("hmtx.zig");
    _ = @import("maxp.zig");
    _ = @import("sbix.zig");
    _ = @import("trak.zig");

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
    // try t.expectError(error.MalformedFont, ttf.Face.parse(data, 0)); // should panic
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
