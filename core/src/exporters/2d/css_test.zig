const std = @import("std");
const testing = std.testing;
const css = @import("css.zig");

fn sheetOf(arena: std.mem.Allocator, text: []const u8) !css.Sheet {
    var sheet: css.Sheet = .{};
    try sheet.add(arena, text);
    return sheet;
}

fn element(name: []const u8, id: ?[]const u8, classes: []const u8) css.Element {
    return .{ .name = name, .id = id, .classes = classes };
}

test "css: a declaration list's value of a property, the last given, without !important" {
    try testing.expectEqualStrings("none", css.declared("fill: none; stroke: red", "fill").?);
    try testing.expectEqualStrings("blue", css.declared("fill:red;fill : blue ;", "fill").?);
    try testing.expectEqualStrings("red", css.declared("fill: red !important", "fill").?);
    try testing.expect(css.declared("stroke: red", "fill") == null);
}

test "css: the matching rule of the highest specificity wins, the last of equals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const sheet = try sheetOf(arena_state.allocator(), "rect { fill: a } .x { fill: b } #i { fill: c } rect.x { fill: d } .x.y { fill: e } .z { fill: f } .z { fill: g } * { fill: h }");
    try testing.expectEqualStrings("c", sheet.value(element("rect", "i", "x"), "fill").?);
    try testing.expectEqualStrings("d", sheet.value(element("rect", null, "x"), "fill").?);
    try testing.expectEqualStrings("a", sheet.value(element("rect", null, ""), "fill").?);
    try testing.expectEqualStrings("b", sheet.value(element("circle", null, "x"), "fill").?);
    try testing.expectEqualStrings("e", sheet.value(element("circle", null, "y  x"), "fill").?);
    try testing.expectEqualStrings("g", sheet.value(element("path", null, "z"), "fill").?);
    try testing.expectEqualStrings("h", sheet.value(element("path", null, ""), "fill").?);
    try testing.expect(sheet.value(element("path", null, ""), "display") == null);
}

test "css: selector lists, and what a drawing leaves out: other selectors, at-rules, comments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const text = "<![CDATA[ /* Illustrator */ @import url(more.css); @media print { .x { fill: none } } " ++
        "g rect { fill: none } a:hover { fill: none } rect[x] { fill: none } .p, path { fill: q } ]]>";
    const sheet = try sheetOf(arena_state.allocator(), text);
    try testing.expect(sheet.value(element("rect", null, "x"), "fill") == null);
    try testing.expectEqualStrings("q", sheet.value(element("path", null, ""), "fill").?);
    try testing.expectEqualStrings("q", sheet.value(element("circle", null, "p"), "fill").?);
}
