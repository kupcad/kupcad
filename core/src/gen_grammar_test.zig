const std = @import("std");
const testing = std.testing;
const registry = @import("core/registry.zig");
const gen_grammar = @import("gen_grammar.zig");

test "gen_grammar: generates valid JSON using std.json" {
    const allocator = testing.allocator;

    const dummy_tokens = [_]registry.TokenMeta{
        .{ .name = "import", .category = .keyword },
        .{ .name = "box", .category = .primitive_3d },
        .{ .name = "translate", .category = .transform },
    };

    const output = try gen_grammar.generateTextMateJson(allocator, &dummy_tokens);
    defer allocator.free(output);

    // If the test fails, print the actual string so we can see what Zig generated
    if (std.mem.indexOf(u8, output, "\"KupCAD\"") == null) {
        std.debug.print("\n--- JSON OUTPUT WAS ---\n{s}\n-----------------------\n", .{output});
        return error.TestUnexpectedResult;
    }

    try testing.expect(std.mem.indexOf(u8, output, "\"source.kupcad\"") != null);

    // Verify the negative lookaround regexes are present instead of \b
    // We use \\\\\\\\ to match the double-escaped \\w in the generated JSON string.
    try testing.expect(std.mem.indexOf(u8, output, "(?<![\\\\\\\\w.])(import)(?![\\\\\\\\w?!])") != null);
    try testing.expect(std.mem.indexOf(u8, output, "(?<![\\\\\\\\w])(box)(?![\\\\\\\\w?!])") != null);
    try testing.expect(std.mem.indexOf(u8, output, "(?<![\\\\\\\\w])(translate)(?![\\\\\\\\w?!])") != null);
}
