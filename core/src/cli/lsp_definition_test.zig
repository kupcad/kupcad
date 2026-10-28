//! Go-to-definition (lsp_definition.zig) over a parsed document: from each kind of name to
//! where it is defined, and nothing for a name the document doesn't define.

const std = @import("std");
const testing = std.testing;
const Document = @import("../frontend/document.zig").Document;
const definition = @import("lsp_definition.zig");

const SOURCE =
    \\import box from "./box.kup"
    \\offset_mm = 1
    \\def plate(width_mm)
    \\  width_mm + offset_mm
    \\end
    \\class Bracket
    \\  def build
    \\    self.helper
    \\  end
    \\  def helper = 1
    \\end
    \\def helper = 2
    \\plate(3)
    \\Bracket.new
    \\[1].each { |item| item + offset_mm }
    \\offset_mm = 5
    \\box
    \\cube(1)
;

/// Where the `nth` (from 1) `needle` in SOURCE starts.
fn at(needle: []const u8, nth: usize) usize {
    var from: usize = 0;
    var found: usize = 0;
    while (std.mem.findPos(u8, SOURCE, from, needle)) |i| : (from = i + 1) {
        found += 1;
        if (found == nth) return i;
    }
    unreachable;
}

/// The `nth` `needle` goes to the `def_nth` one.
fn expectHere(doc: *const Document, needle: []const u8, nth: usize, def_nth: usize) !void {
    errdefer std.debug.print("{s} #{d}\n", .{ needle, nth });
    const target = definition.definitionAt(doc, at(needle, nth)) orelse return error.NoDefinition;
    try testing.expectEqual(definition.Target{ .here = .{ .offset = @intCast(at(needle, def_nth)), .length = @intCast(needle.len) } }, target);
}

test "definition: a local, a parameter and a block's parameter go to where they are declared" {
    var doc = try Document.parse(testing.allocator, SOURCE);
    defer doc.deinit();
    // A def's parameter, and a script variable read inside it (an upvalue)
    try expectHere(&doc, "width_mm", 2, 1);
    try expectHere(&doc, "offset_mm", 2, 1);
    // A block's parameter, and a script variable read in the block
    try expectHere(&doc, "item", 2, 1);
    try expectHere(&doc, "offset_mm", 3, 1);
    // A reassignment goes to the first assignment
    try expectHere(&doc, "offset_mm", 4, 1);
}

test "definition: a method goes to its def, in the caller's class first, and a class to its statement" {
    var doc = try Document.parse(testing.allocator, SOURCE);
    defer doc.deinit();
    // self.helper inside Bracket is Bracket's helper, not the script's
    try expectHere(&doc, "helper", 1, 2);
    try expectHere(&doc, "plate", 2, 1);
    try expectHere(&doc, "Bracket", 2, 1);
    // A name an import binds (the second "box" is in its path)
    try expectHere(&doc, "box", 3, 1);
}

test "definition: an import's path is its module, and a built-in or a number is nothing" {
    var doc = try Document.parse(testing.allocator, SOURCE);
    defer doc.deinit();
    try testing.expectEqualStrings("./box.kup", (definition.definitionAt(&doc, at("box.kup", 1)) orelse return error.NoDefinition).module);
    try testing.expectEqual(@as(?definition.Target, null), definition.definitionAt(&doc, at("cube", 1)));
    try testing.expectEqual(@as(?definition.Target, null), definition.definitionAt(&doc, at("3", 1)));
    try testing.expectEqual(@as(?definition.Target, null), definition.definitionAt(&doc, at("new", 1)));
}

test "definition: a class declared by its path is found by its name, and doesn't hide the others" {
    // `class Fasteners::Nut`'s path was read as an identifier's string: an id out of range.
    // (A name inside a path, `Fasteners::Nut.new`'s, isn't looked up: no definition.)
    const source =
        \\module Fasteners
        \\end
        \\class Fasteners::Nut
        \\end
        \\class Bracket
        \\end
        \\Bracket.new
        \\Nut
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    const bracket = std.mem.find(u8, source, "Bracket").?;
    try testing.expectEqual(definition.Target{ .here = .{ .offset = @intCast(bracket), .length = 7 } }, definition.definitionAt(&doc, std.mem.findLast(u8, source, "Bracket").?).?);
    const nut = std.mem.find(u8, source, "Nut").?;
    try testing.expectEqual(definition.Target{ .here = .{ .offset = @intCast(nut), .length = 3 } }, definition.definitionAt(&doc, std.mem.findLast(u8, source, "Nut").?).?);
}
