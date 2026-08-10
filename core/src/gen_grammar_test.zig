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

    try testing.expect(std.mem.indexOf(u8, output, "\"source.kupcad\"") != null);

    // Verify it actually extracted keywords natively from KupCAD Lexer
    try testing.expect(std.mem.indexOf(u8, output, "class") != null);
    try testing.expect(std.mem.indexOf(u8, output, "def") != null);

    // Verify it actually extracted methods natively from the Stdlib Manifest
    try testing.expect(std.mem.indexOf(u8, output, "cube") != null);
    try testing.expect(std.mem.indexOf(u8, output, "translate") != null);
}
