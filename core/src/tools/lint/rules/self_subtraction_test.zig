const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const SelfSubtractionRule = @import("self_subtraction.zig").SelfSubtractionRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    errdefer engine.deinit();
    var rule_impl = SelfSubtractionRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    // Tokens and AST are scratch; only the engine (and its diagnostics) is returned
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);
    return engine;
}

test "Linter Rule: SelfSubtractionRule catches a - a" {
    const source = "result = part - part";
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CSG Warning: Self-difference operation ('part - part') will result in empty geometry.", engine.diagnostics.items[0].message);
}
