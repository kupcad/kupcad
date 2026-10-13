const std = @import("std");
const testing = std.testing;
const gen_grammar = @import("gen_grammar.zig");

test "gen_grammar: generates valid JSON using std.json" {
    const allocator = testing.allocator;

    // Generates output purely from our live architecture definitions
    const output = try gen_grammar.generateTextMateJson(allocator);
    defer allocator.free(output);

    if (std.mem.indexOf(u8, output, "\"KupCAD\"") == null) {
        std.debug.print("\n--- JSON OUTPUT WAS ---\n{s}\n-----------------------\n", .{output});
        return error.TestUnexpectedResult;
    }

    // Must be well-formed JSON with the expected scope
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("source.kupcad", parsed.value.object.get("scopeName").?.string);

    // Keywords come from the KupCAD lexer, methods from the stdlib manifest.
    // Whole-word matches: a bare substring "def" would also match "default".
    for ([_][]const u8{ "class", "def", "cube", "translate" }) |word| {
        try testing.expect(containsWord(output, word));
    }
}

fn containsWord(haystack: []const u8, word: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, word)) |i| : (start = i + 1) {
        const before_ok = i == 0 or !std.ascii.isAlphanumeric(haystack[i - 1]);
        const end = i + word.len;
        const after_ok = end == haystack.len or !std.ascii.isAlphanumeric(haystack[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}
