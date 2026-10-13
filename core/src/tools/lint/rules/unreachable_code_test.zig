const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const UnreachableCodeRule = @import("unreachable_code.zig").UnreachableCodeRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    errdefer engine.deinit();
    var rule_impl = UnreachableCodeRule{};
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

test "Linter Rule: UnreachableCodeRule catches code after return" {
    const source =
        \\def check_flow()
        \\  return
        \\  cube()
        \\end
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnreachableCodeRule catches code after break and next" {
    inline for (.{ "break", "next" }) |keyword| {
        const source = "while true\n  " ++ keyword ++ "\n  cube() # Unreachable\nend";
        var engine = try runRule(testing.allocator, source);
        defer engine.deinit();

        try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
        try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", engine.diagnostics.items[0].message);
    }
}
