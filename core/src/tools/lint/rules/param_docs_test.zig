const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const ParamDocsRule = @import("param_docs.zig").ParamDocsRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    var rule_impl = ParamDocsRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, allocator);
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, root, parser.diagnostics.list.items);
    return engine;
}

test "Linter Rule: ParamDocsRule catches missing variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\# @param missing_var [Length] This variable doesn't exist
        \\actual_var = 100
    ;
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("@param annotation references variable 'missing_var', which is never declared in standard scope.", engine.diagnostics.items[0].message);
}

test "Linter Rule: ParamDocsRule stays quiet on valid matching variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\# @param radius [Length] Outer radius
        \\radius = 10.5
    ;
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}
