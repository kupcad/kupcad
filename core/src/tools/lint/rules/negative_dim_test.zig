const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const NegativeDimRule = @import("negative_dim.zig").NegativeDimRule;
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, .{});
    errdefer engine.deinit();
    var rule_impl = NegativeDimRule{};
    try engine.rules.append(allocator, rule_impl.rule());

    // Tokens and AST are scratch; only the engine (and its diagnostics) is returned
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);

    // Lex everything upfront to SoA tokens
    const tokens = try lexer.lexAll(arena.allocator());

    // Initialize parser with tokens and source
    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const root = try parser.parseProgram();

    // Pass token bounds to the linter engine for diagnostic locations
    try engine.check(&parser.b.tree, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);

    return engine;
}

test "Linter Rule: NegativeDimRule catches negative dimensions in method calls" {
    const source = "cyl = Cylinder.new(r: -50, h: 20)";
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'r' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}

test "Linter Rule: NegativeDimRule catches negative dimensions in property assignment" {
    const source = "box.width = -10";
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'width' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}

test "Linter Rule: NegativeDimRule ignores negative coordinates" {
    const source = "box = Box.new(x: -50, y: -20, z: -10)";
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "Linter Rule: NegativeDimRule catches negative dimensions inside arrays" {
    const source = "box = Box.new(size: [10, -20, 30])";
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("CAD Warning: Property 'size' in primitive construction has non-positive dimension.", engine.diagnostics.items[0].message);
}
