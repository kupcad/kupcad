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

test "a variation store read from its own offset" {
    // [KupCAD] The store was parsed from the stream left after the Global Subroutines, not
    // from its offset: a store anywhere else, here after the CharStrings, failed the table.
    const data = try convert(&.{
        // Header
        .{ .unt8 = 2 }, // major version
        .{ .unt8 = 0 }, // minor version
        .{ .unt8 = 5 }, // header size
        .{ .unt16 = 4 }, // Top DICT length
        // Top DICT
        .{ .cff_int = 13 },
        .{ .unt8 = 17 }, // CharStrings offset
        .{ .cff_int = 21 },
        .{ .unt8 = 24 }, // variation store offset
        // Global Subroutines INDEX, at 9
        .{ .unt32 = 0 }, // count
        // CharStrings INDEX, at 13
        .{ .unt32 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 2 }, // index[1]
        .{ .unt8 = 0 }, // data
        // Variation store, at 21: its length, then the store
        .{ .unt16 = 26 }, // length
        .{ .unt16 = 1 }, // format
        .{ .unt32 = 12 }, // offset to the region list
        .{ .unt16 = 1 }, // number of item variation data
        .{ .unt32 = 22 }, // offset to item variation data 0
        // Region list
        .{ .unt16 = 1 }, // axis count
        .{ .unt16 = 1 }, // region count
        .{ .unt16 = 0 }, // start
        .{ .unt16 = 0x4000 }, // peak
        .{ .unt16 = 0x4000 }, // end
        // Item variation data 0
        .{ .unt16 = 0 }, // item count
        .{ .unt16 = 0 }, // word delta count
        .{ .unt16 = 0 }, // region index count
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    try t.expectEqual(1, table.item_variation_store.regions.axis_count);
}

test "a private DICT read from its start, not its length" {
    // [KupCAD] The Private operator's operands are its length then its offset; both were
    // read from the first, so the local subroutines were looked for at the length.
    const data = try convert(&.{
        // Header
        .{ .unt8 = 2 }, // major version
        .{ .unt8 = 0 }, // minor version
        .{ .unt8 = 5 }, // header size
        .{ .unt16 = 5 }, // Top DICT length
        // Top DICT
        .{ .cff_int = 14 },
        .{ .unt8 = 17 }, // CharStrings offset
        .{ .cff_int = 22 },
        .{ .unt8 = 12 },
        .{ .unt8 = 36 }, // Font DICT INDEX offset
        // Global Subroutines INDEX, at 10
        .{ .unt32 = 0 }, // count
        // CharStrings INDEX, at 14
        .{ .unt32 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 2 }, // index[1]
        .{ .unt8 = 0 }, // data
        // Font DICT INDEX, at 22
        .{ .unt32 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 4 }, // index[1]
        .{ .cff_int = 2 }, // the Private DICT's length
        .{ .cff_int = 32 }, // its offset
        .{ .unt8 = 18 }, // Private
        // Private DICT, at 32
        .{ .cff_int = 2 },
        .{ .unt8 = 19 }, // local subroutines, from the Private DICT's start
        // Local Subroutines INDEX, at 34
        .{ .unt32 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 2 }, // index[1]
        .{ .unt8 = 11 }, // data: return
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    try t.expectEqual(1, table.local_subrs.len());
}
