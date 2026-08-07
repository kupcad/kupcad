const std = @import("std");
const testing = std.testing;
const ast = @import("../../../core/ast.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const SortImportsRule = @import("sort_imports.zig").SortImportsRule;

test "Formatter Rule: SortImportsRule sorts standard contiguous imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import "z_lib.kup"
        \\import "a_lib.kup"
        \\import "m_lib.kup"
    ;

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    const tree_idx = try parser.parseProgram();

    var rule_impl = SortImportsRule{};
    const rule = rule_impl.rule();
    const root_node = parser.b.tree.getNode(tree_idx).?;

    const sorted_stmts = rule.processBlockStmts(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_node.kind.block.stmts));

    try testing.expectEqualStrings("a_lib.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[0]).?.kind.import_stmt.path));
    try testing.expectEqualStrings("m_lib.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[1]).?.kind.import_stmt.path));
    try testing.expectEqualStrings("z_lib.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[2]).?.kind.import_stmt.path));
}

test "Formatter Rule: SortImportsRule handles named and destructured imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import { ThreadedInsert } from "z_hardware.kup"
        \\import Math from "b_math.kup"
        \\import "a_global.kup"
    ;

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    const tree_idx = try parser.parseProgram();

    var rule_impl = SortImportsRule{};
    const rule = rule_impl.rule();
    const root_node = parser.b.tree.getNode(tree_idx).?;

    const sorted_stmts = rule.processBlockStmts(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_node.kind.block.stmts));

    // Should sort entirely by the path string, ignoring the symbol bindings
    try testing.expectEqualStrings("a_global.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[0]).?.kind.import_stmt.path));
    try testing.expectEqualStrings("b_math.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[1]).?.kind.import_stmt.path));
    try testing.expectEqualStrings("z_hardware.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[2]).?.kind.import_stmt.path));

    // Verify payload is preserved safely (B_Math should be at index 1 now)
    const math_symbols_span = parser.b.tree.getNode(sorted_stmts[1]).?.kind.import_stmt.symbols;
    const math_symbols = parser.b.tree.getStringLists(math_symbols_span);
    try testing.expectEqualStrings("Math", parser.b.tree.getString(math_symbols[0]));
}

test "Formatter Rule: SortImportsRule respects non-contiguous blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import "z.kup"
        \\import "a.kup"
        \\
        \\x = 10
        \\
        \\import "y.kup"
        \\import "b.kup"
    ;

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    const tree_idx = try parser.parseProgram();

    var rule_impl = SortImportsRule{};
    const rule = rule_impl.rule();
    const root_node = parser.b.tree.getNode(tree_idx).?;

    const stmts = rule.processBlockStmts(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_node.kind.block.stmts));

    // Block 1 (Indexes 0, 1)
    try testing.expectEqualStrings("a.kup", parser.b.tree.getString(parser.b.tree.getNode(stmts[0]).?.kind.import_stmt.path));
    try testing.expectEqualStrings("z.kup", parser.b.tree.getString(parser.b.tree.getNode(stmts[1]).?.kind.import_stmt.path));

    // Middle statement (Index 2)
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).assignment, std.meta.activeTag(parser.b.tree.getNode(stmts[2]).?.kind));
    try testing.expectEqualStrings("x", parser.b.tree.getString(parser.b.tree.getNode(stmts[2]).?.kind.assignment.name));

    // Block 2 (Indexes 3, 4)
    try testing.expectEqualStrings("b.kup", parser.b.tree.getString(parser.b.tree.getNode(stmts[3]).?.kind.import_stmt.path));
    try testing.expectEqualStrings("y.kup", parser.b.tree.getString(parser.b.tree.getNode(stmts[4]).?.kind.import_stmt.path));
}

test "Formatter Rule: SortImportsRule handles imports with trailing attributes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import "z.kup" with { version: 2 }
        \\import "a.kup" with { version: 1 }
    ;

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    const tree_idx = try parser.parseProgram();

    var rule_impl = SortImportsRule{};
    const rule = rule_impl.rule();
    const root_node = parser.b.tree.getNode(tree_idx).?;

    const sorted_stmts = rule.processBlockStmts(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_node.kind.block.stmts));

    try testing.expectEqualStrings("a.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[0]).?.kind.import_stmt.path));
    try testing.expectEqualStrings("z.kup", parser.b.tree.getString(parser.b.tree.getNode(sorted_stmts[1]).?.kind.import_stmt.path));

    // Ensure the attributes hash is kept intact on the right node
    const a_attrs_idx = parser.b.tree.getNode(sorted_stmts[0]).?.kind.import_stmt.attributes;
    const a_attrs_node = parser.b.tree.getNode(a_attrs_idx).?;
    const a_attrs = parser.b.tree.getHashEntries(a_attrs_node.kind.hash_literal);
    try testing.expectEqual(@as(f64, 1.0), parser.b.tree.getNode(a_attrs[0].value).?.kind.number);
}
