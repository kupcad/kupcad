const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const SelfSubtractionRule = @import("self_subtraction.zig").SelfSubtractionRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    var rule_impl = SelfSubtractionRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, allocator);
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, root, parser.diagnostics.list.items);
    return engine;
}

test "Linter Rule: SelfSubtractionRule catches a - a" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "result = part - part";
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CSG Warning: Self-difference operation ('part - part') will result in empty geometry.", engine.diagnostics.items[0].message);
}
