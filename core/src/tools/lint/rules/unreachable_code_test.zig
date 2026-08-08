const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const UnreachableCodeRule = @import("unreachable_code.zig").UnreachableCodeRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    var rule_impl = UnreachableCodeRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(allocator);

    var parser = parser_mod.Parser.init(tokens, source, allocator);
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);
    return engine;
}

test "Linter Rule: UnreachableCodeRule catches code after return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def check_flow()
        \\  return
        \\  cube()
        \\end
    ;
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnreachableCodeRule catches code after break and next" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\while true
        \\  break
        \\  cube() # Unreachable
        \\end
    ;
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unreachable code detected after explicit control flow return/break.", engine.diagnostics.items[0].message);
}
