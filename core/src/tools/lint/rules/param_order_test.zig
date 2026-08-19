const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const ParamOrderRule = @import("param_order.zig").ParamOrderRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    var rule_impl = ParamOrderRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(allocator);

    var parser = try parser_mod.Parser.init(tokens, source, allocator);
    const root = try parser.parseProgram();

    try engine.check(&parser.b.tree, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);
    return engine;
}

test "Linter Rule: ParamOrderRule warns on usage before definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\x = param(:width)
        \\param(:width, default: 20)
    ;
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Parameter ':width' used before definition.", engine.diagnostics.items[0].message);
}

test "Linter Rule: ParamOrderRule warns on parameter definitions inside functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def build_part()
        \\  param(:height, default: 10)
        \\end
    ;
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Parameter ':height' definition should be placed at the top level for static UI extraction.", engine.diagnostics.items[0].message);
}

test "Linter Rule: ParamOrderRule passes on clean top-level definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\param(:width, default: 20)
        \\box = cube(param(:width))
    ;
    const engine = try runRule(arena.allocator(), source);

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}
