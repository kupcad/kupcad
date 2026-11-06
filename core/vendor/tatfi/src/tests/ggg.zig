const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const ClassDefinition = ttf.opentype_layout.ClassDefinition;

test "class definition format 2 gives its range's class" {
    // [KupCAD] It gave the range's class plus the glyph's place in the range, as a coverage
    // table's index is computed; ttf-parser and the spec give the class.
    const data = try convert(&.{
        .{ .unt16 = 2 }, // format
        .{ .unt16 = 1 }, // range count
        .{ .unt16 = 10 }, // range 0: first glyph
        .{ .unt16 = 20 }, // last glyph
        .{ .unt16 = 3 }, // class
    });
    defer t.allocator.free(data);

    const class_def = try ClassDefinition.parse(data);
    try t.expectEqual(3, class_def.get(.{10}));
    try t.expectEqual(3, class_def.get(.{15}));
    try t.expectEqual(3, class_def.get(.{20}));
    try t.expectEqual(0, class_def.get(.{21}));
}
