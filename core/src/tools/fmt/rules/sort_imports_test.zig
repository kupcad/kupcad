const std = @import("std");
const testing = std.testing;
const ast = @import("../../../core/ast.zig");
const lexer_mod = @import("../../../frontend/kupcad/lexer.zig");
const parser_mod = @import("../../../frontend/kupcad/parser.zig");
const SortImportsRule = @import("sort_imports.zig").SortImportsRule;

fn runRule(allocator: std.mem.Allocator, source: []const u8) !*ast.Node {
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, allocator);

    // DO NOT call `defer parser.deinit()` here
    // The parser owns the StringPool. If we deinit it, all strings
    // inside the AST nodes become dangling pointers.
    // We let the caller's ArenaAllocator clean it all up safely at the end.

    const tree = try parser.parseProgram();

    var rule_impl = SortImportsRule{};
    const rule = rule_impl.rule();
    rule.normalize(tree);

    return tree;
}

test "Formatter Rule: SortImportsRule sorts standard contiguous imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import "z_lib.kup"
        \\import "a_lib.kup"
        \\import "m_lib.kup"
    ;

    const tree = try runRule(arena.allocator(), source);
    const sorted_stmts = tree.kind.block.stmts;

    try testing.expectEqualStrings("a_lib.kup", sorted_stmts[0].kind.import_stmt.path);
    try testing.expectEqualStrings("m_lib.kup", sorted_stmts[1].kind.import_stmt.path);
    try testing.expectEqualStrings("z_lib.kup", sorted_stmts[2].kind.import_stmt.path);
}

test "Formatter Rule: SortImportsRule handles named and destructured imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import { ThreadedInsert } from "z_hardware.kup"
        \\import Math from "b_math.kup"
        \\import "a_global.kup"
    ;

    const tree = try runRule(arena.allocator(), source);
    const sorted_stmts = tree.kind.block.stmts;

    // Should sort entirely by the path string, ignoring the symbol bindings
    try testing.expectEqualStrings("a_global.kup", sorted_stmts[0].kind.import_stmt.path);
    try testing.expectEqualStrings("b_math.kup", sorted_stmts[1].kind.import_stmt.path);
    try testing.expectEqualStrings("z_hardware.kup", sorted_stmts[2].kind.import_stmt.path);

    // Verify payload is preserved safely (B_Math should be at index 1 now)
    try testing.expectEqualStrings("Math", sorted_stmts[1].kind.import_stmt.symbols[0]);
}

test "Formatter Rule: SortImportsRule respects non-contiguous blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // If an assignment (or any other statement) interrupts the imports,
    // it should format them as two distinct, isolated import blocks.
    const source =
        \\import "z.kup"
        \\import "a.kup"
        \\
        \\x = 10
        \\
        \\import "y.kup"
        \\import "b.kup"
    ;

    const tree = try runRule(arena.allocator(), source);
    const stmts = tree.kind.block.stmts;

    // Block 1 (Indexes 0, 1)
    try testing.expectEqualStrings("a.kup", stmts[0].kind.import_stmt.path);
    try testing.expectEqualStrings("z.kup", stmts[1].kind.import_stmt.path);

    // Middle statement (Index 2)
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).assignment, std.meta.activeTag(stmts[2].kind));
    try testing.expectEqualStrings("x", stmts[2].kind.assignment.name);

    // Block 2 (Indexes 3, 4)
    try testing.expectEqualStrings("b.kup", stmts[3].kind.import_stmt.path);
    try testing.expectEqualStrings("y.kup", stmts[4].kind.import_stmt.path);
}

test "Formatter Rule: SortImportsRule handles imports with trailing attributes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import "z.kup" with { version: 2 }
        \\import "a.kup" with { version: 1 }
    ;

    const tree = try runRule(arena.allocator(), source);
    const sorted_stmts = tree.kind.block.stmts;

    try testing.expectEqualStrings("a.kup", sorted_stmts[0].kind.import_stmt.path);
    try testing.expectEqualStrings("z.kup", sorted_stmts[1].kind.import_stmt.path);

    // Ensure the attributes hash is kept intact on the right node
    const a_attrs = sorted_stmts[0].kind.import_stmt.attributes.?.kind.hash_literal;
    try testing.expectEqual(@as(f64, 1.0), a_attrs[0].value.kind.number);
}
