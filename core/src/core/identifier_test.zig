const std = @import("std");
const testing = std.testing;
const identifier = @import("identifier.zig");

test "identifier: isBareSymbol is what `:name` reads back as, isLabelName what `name:` does" {
    // The formatter writes a symbol that isn't either in another form (fmt's own tests)
    for ([_][]const u8{ "a", "_x", "θ_angle", "valid?", "destroy!", "x=", "@a", "$a", "A", "if", "a?b" }) |name| {
        errdefer std.debug.print("name: {s}\n", .{name});
        try testing.expect(identifier.isBareSymbol(name));
    }
    for ([_][]const u8{ "", "a:", "M:%i", "a-b", "1a", "a b", "a=b", "a\"b" }) |name| {
        errdefer std.debug.print("name: {s}\n", .{name});
        try testing.expect(!identifier.isBareSymbol(name));
    }
    for ([_][]const u8{ "a", "valid?", "A", "@a", "$a", "θ" }) |name| {
        errdefer std.debug.print("name: {s}\n", .{name});
        try testing.expect(identifier.isLabelName(name));
    }
    for ([_][]const u8{ "", "if", "a b", "a=", "a-b", "$$a", " a" }) |name| {
        errdefer std.debug.print("name: {s}\n", .{name});
        try testing.expect(!identifier.isLabelName(name));
    }
}

test "identifier: a name ends at a character names don't have, or at a byte that isn't UTF-8" {
    try testing.expectEqual(@as(usize, 6), identifier.end("valid?", 0));
    try testing.expectEqual(@as(usize, 1), identifier.end("a-b", 0));
    try testing.expectEqual(@as(usize, 3), identifier.end("x.y", 2));
    try testing.expectEqual(@as(usize, 8), identifier.end("θ_angle", 0));
    try testing.expectEqual(@as(usize, 1), identifier.end("a\xC3(", 0));
    try testing.expectEqual(@as(usize, 1), identifier.end("a\xE2\x82", 0));
}

test "identifier: a global starts with `$` and a letter or `_`, not another `$` or a digit" {
    try testing.expect(identifier.startsAt("$a", 0));
    try testing.expect(identifier.startsAt("$_", 0));
    try testing.expect(!identifier.startsAt("$", 0));
    try testing.expect(!identifier.startsAt("$$a", 0));
    try testing.expect(!identifier.startsAt("$1", 0));
    try testing.expect(identifier.startsAt("x = $a", 4));
    try testing.expect(!identifier.startsAt("a", 1));
}

test "identifier: the reserved words are keywords, other names aren't" {
    for (identifier.KEYWORDS) |word| try testing.expect(identifier.isKeyword(word));
    for ([_][]const u8{ "If", "ends", "", "lambda", "puts" }) |name| try testing.expect(!identifier.isKeyword(name));
}
