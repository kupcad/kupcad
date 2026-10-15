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

test "gen_grammar: `in` is highlighted as a keyword after `for`, and only there" {
    // `in` isn't a reserved word (so `in:` keeps working as a label), so the keyword rule
    // never highlighted it in `for x in xs`.
    const allocator = testing.allocator;
    const output = try gen_grammar.generateTextMateJson(allocator);
    defer allocator.free(output);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const rule = parsed.value.object.get("repository").?.object.get("for_in").?.object;
    try testing.expectEqualStrings(gen_grammar.FOR_IN_MATCH, rule.get("match").?.string);
    const captures = rule.get("captures").?.object;
    for ([_][]const u8{ "1", "3" }) |group| {
        try testing.expectEqualStrings("keyword.control.kupcad", captures.get(group).?.object.get("name").?.string);
    }
    // It must come before the plain keyword rule, or that one claims `for` first.
    var for_in_at: ?usize = null;
    var keywords_at: ?usize = null;
    for (parsed.value.object.get("patterns").?.array.items, 0..) |p, i| {
        const include = p.object.get("include").?.string;
        if (std.mem.eql(u8, include, "#for_in")) for_in_at = i;
        if (std.mem.eql(u8, include, "#keywords")) keywords_at = i;
    }
    try testing.expect(for_in_at.? < keywords_at.?);
    // The keyword list itself still leaves `in` out.
    try testing.expect(!containsWord(rule_keywords(parsed.value), "in"));
}

fn rule_keywords(root: std.json.Value) []const u8 {
    return root.object.get("repository").?.object.get("keywords").?.object.get("match").?.string;
}
