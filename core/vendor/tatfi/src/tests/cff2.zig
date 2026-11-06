const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const init_outline_builder = @import("cff1.zig").init_outline_builder;
const Table = ttf.tables.cff2;

test "a blend of no operands" {
    // [KupCAD] Popping the number of blends off the empty stack reached unreachable.
    const data = try convert(&.{
        // Header
        .{ .unt8 = 2 }, // major version
        .{ .unt8 = 0 }, // minor version
        .{ .unt8 = 5 }, // header size
        .{ .unt16 = 4 }, // Top DICT length
        // Top DICT
        .{ .cff_int = 35 },
        .{ .unt8 = 17 }, // CharStrings offset
        .{ .cff_int = 11 },
        .{ .unt8 = 24 }, // variation store offset: its length is the subroutines' last two bytes
        // Global Subroutines INDEX
        .{ .unt32 = 0 }, // count
        // Item variation store, at 13
        .{ .unt16 = 1 }, // format
        .{ .unt32 = 12 }, // offset to the region list
        .{ .unt16 = 1 }, // number of item variation data
        .{ .unt32 = 16 }, // offset to item variation data 0
        // Region list
        .{ .unt16 = 0 }, // axis count
        .{ .unt16 = 0 }, // region count
        // Item variation data 0
        .{ .unt16 = 0 }, // item count
        .{ .unt16 = 0 }, // word delta count
        .{ .unt16 = 0 }, // region index count
        // CharStrings INDEX, at 35
        .{ .unt32 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 2 }, // index[1]
        // Data
        .{ .unt8 = 16 }, // blend
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    try t.expectError(
        error.InvalidArgumentsStackLength,
        table.outline(&.{}, .{0}, init_outline_builder(&writer.writer)),
    );
}
