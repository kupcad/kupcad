const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const ItemVariationStore = @import("../var_store.zig");

test "a region from -32768 to 0" {
    // [KupCAD] The region's end minus its peak, 0 - -32768, overflowed the i16s.
    const region = [_]u8{ 0x80, 0x00, 0x80, 0x00, 0, 0 }; // start, peak -32768, end 0
    const regions: ItemVariationStore.VariationRegionList = .{ .axis_count = 1, .regions = .new(&region) };
    try t.expectEqual(1.0 / 32768.0, regions.evaluate_region(0, &.{.{ .inner = -1 }}));
}

test "a region index past a u16" {
    // [KupCAD] Region 0x8000 of two axes, its first record's index, overflowed the u16.
    const regions: ItemVariationStore.VariationRegionList = .{ .axis_count = 2 };
    try t.expectEqual(0.0, regions.evaluate_region(0x8000, &.{ .{ .inner = 0 }, .{ .inner = 0 } }));
}

test "a delta set past a u16" {
    // [KupCAD] Its length, 0x7FFF word deltas plus 0x8001 regions, overflowed the u16.
    var data: std.ArrayList(u8) = .fromOwnedSlice(try convert(&.{
        .{ .unt16 = 1 }, // format
        .{ .unt32 = 12 }, // offset to the region list
        .{ .unt16 = 1 }, // number of item variation data
        .{ .unt32 = 16 }, // offset to item variation data 0
        .{ .unt16 = 0 }, // region list: axis count
        .{ .unt16 = 0 }, // region count
        // Item variation data 0
        .{ .unt16 = 1 }, // item count
        .{ .unt16 = 0x7FFF }, // word delta count
        .{ .unt16 = 0x8001 }, // region index count
    }));
    defer data.deinit(t.allocator);
    try data.appendNTimes(t.allocator, 0, 0x8001 * 2); // region indices, no deltas

    var s = @import("../parser.zig").Stream.new(data.items);
    const store = try ItemVariationStore.parse(&s);
    try t.expectError(error.ParseFail, store.parse_delta(0, 0, &.{.{ .inner = 0 }}));
}

test "a region list past a 32-bit usize" {
    // [KupCAD] The store's offset plus the region list's, 0xFFFFFFFF, overflowed a 32-bit
    // usize (wasm32) advancing to it.
    const data = try convert(&.{
        .{ .unt32 = 0 }, // what comes before the store
        .{ .unt16 = 1 }, // format
        .{ .unt32 = 0xFFFFFFFF }, // offset to the region list
        .{ .unt16 = 0 }, // number of item variation data
    });
    defer t.allocator.free(data);

    var s = try @import("../parser.zig").Stream.new_at(data, 4);
    try t.expectError(error.ParseFail, ItemVariationStore.parse(&s));
}
