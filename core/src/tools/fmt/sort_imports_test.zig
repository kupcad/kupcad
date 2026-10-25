const std = @import("std");
const testing = std.testing;
const ast = @import("../../core/ast.zig");
const lexer_mod = @import("../../frontend/lexer.zig");
const parser_mod = @import("../../frontend/parser.zig");
const sort_imports = @import("sort_imports.zig");

test "sort imports: sorts standard contiguous imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import "z_lib.kup"
        \\import "a_lib.kup"
        \\import "m_lib.kup"
    ;

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const tree_idx = try parser.parseProgram();

    const root_node = parser.b.tree.getNode(tree_idx).?;
    const root_block = parser.b.tree.block(root_node);

    const sorted_stmts = try sort_imports.sortedImports(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_block.stmts), try uncommented(arena.allocator(), parser.b.tree.getNodes(root_block.stmts).len));

    const n0 = parser.b.tree.getNode(sorted_stmts[0]).?;
    const n1 = parser.b.tree.getNode(sorted_stmts[1]).?;
    const n2 = parser.b.tree.getNode(sorted_stmts[2]).?;

    try testing.expectEqualStrings("a_lib.kup", parser.b.tree.getString(parser.b.tree.importStmt(n0).path));
    try testing.expectEqualStrings("m_lib.kup", parser.b.tree.getString(parser.b.tree.importStmt(n1).path));
    try testing.expectEqualStrings("z_lib.kup", parser.b.tree.getString(parser.b.tree.importStmt(n2).path));
}

test "sort imports: handles named and destructured imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import { ThreadedInsert } from "z_hardware.kup"
        \\import Math from "b_math.kup"
        \\import "a_global.kup"
    ;

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const tree_idx = try parser.parseProgram();

    const root_node = parser.b.tree.getNode(tree_idx).?;
    const root_block = parser.b.tree.block(root_node);

    const sorted_stmts = try sort_imports.sortedImports(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_block.stmts), try uncommented(arena.allocator(), parser.b.tree.getNodes(root_block.stmts).len));

    const n0 = parser.b.tree.getNode(sorted_stmts[0]).?;
    const n1 = parser.b.tree.getNode(sorted_stmts[1]).?;
    const n2 = parser.b.tree.getNode(sorted_stmts[2]).?;

    // Should sort entirely by the path string, ignoring the symbol bindings
    try testing.expectEqualStrings("a_global.kup", parser.b.tree.getString(parser.b.tree.importStmt(n0).path));
    try testing.expectEqualStrings("b_math.kup", parser.b.tree.getString(parser.b.tree.importStmt(n1).path));
    try testing.expectEqualStrings("z_hardware.kup", parser.b.tree.getString(parser.b.tree.importStmt(n2).path));

    // Verify payload is preserved safely
    // "b_math.kup" is at index 1 and has the symbol "Math"
    const math_symbols_span = parser.b.tree.importStmt(n1).symbols;
    const math_symbols = parser.b.tree.getAliasPairs(math_symbols_span);
    try testing.expectEqualStrings("Math", parser.b.tree.getString(math_symbols[0].original));

    // "z_hardware.kup" is at index 2 and has the symbol "ThreadedInsert"
    const hardware_symbols_span = parser.b.tree.importStmt(n2).symbols;
    const hardware_symbols = parser.b.tree.getAliasPairs(hardware_symbols_span);
    try testing.expectEqualStrings("ThreadedInsert", parser.b.tree.getString(hardware_symbols[0].original));
}

test "sort imports: respects non-contiguous blocks" {
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
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const tree_idx = try parser.parseProgram();

    const root_node = parser.b.tree.getNode(tree_idx).?;
    const root_block = parser.b.tree.block(root_node);

    const stmts = try sort_imports.sortedImports(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_block.stmts), try uncommented(arena.allocator(), parser.b.tree.getNodes(root_block.stmts).len));

    const n0 = parser.b.tree.getNode(stmts[0]).?;
    const n1 = parser.b.tree.getNode(stmts[1]).?;
    const n2 = parser.b.tree.getNode(stmts[2]).?;
    const n3 = parser.b.tree.getNode(stmts[3]).?;
    const n4 = parser.b.tree.getNode(stmts[4]).?;

    // Block 1 (Indexes 0, 1)
    try testing.expectEqualStrings("a.kup", parser.b.tree.getString(parser.b.tree.importStmt(n0).path));
    try testing.expectEqualStrings("z.kup", parser.b.tree.getString(parser.b.tree.importStmt(n1).path));

    // Middle statement (Index 2)
    try testing.expectEqual(ast.Tag.assignment, n2.tag);
    try testing.expectEqualStrings("x", parser.b.tree.getString(parser.b.tree.assignment(n2).name));

    // Block 2 (Indexes 3, 4)
    try testing.expectEqualStrings("b.kup", parser.b.tree.getString(parser.b.tree.importStmt(n3).path));
    try testing.expectEqualStrings("y.kup", parser.b.tree.getString(parser.b.tree.importStmt(n4).path));
}

test "sort imports: handles imports with trailing attributes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\import "z.kup" with { type: "kup" }
        \\import "a.kup" with { type: :kup }
    ;

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena.allocator());

    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const tree_idx = try parser.parseProgram();

    const root_node = parser.b.tree.getNode(tree_idx).?;
    const root_block = parser.b.tree.block(root_node);

    const sorted_stmts = try sort_imports.sortedImports(arena.allocator(), &parser.b.tree, parser.b.tree.getNodes(root_block.stmts), try uncommented(arena.allocator(), parser.b.tree.getNodes(root_block.stmts).len));

    const n0 = parser.b.tree.getNode(sorted_stmts[0]).?;
    const n1 = parser.b.tree.getNode(sorted_stmts[1]).?;

    try testing.expectEqualStrings("a.kup", parser.b.tree.getString(parser.b.tree.importStmt(n0).path));
    try testing.expectEqualStrings("z.kup", parser.b.tree.getString(parser.b.tree.importStmt(n1).path));

    // Ensure the attributes hash is kept intact on the right node
    const a_attrs_idx = parser.b.tree.importStmt(n0).attributes;
    const a_attrs_node = parser.b.tree.getNode(a_attrs_idx).?;

    // Hash literals now extract their data via tree.nodeSpan
    const a_attrs = parser.b.tree.getHashEntries(parser.b.tree.nodeSpan(a_attrs_node));

    // a.kup's is the symbol `:kup`, z.kup's the string "kup"
    const val_node = parser.b.tree.getNode(a_attrs[0].value).?;
    try testing.expectEqual(ast.Tag.symbol, val_node.tag);
}

/// No statement has a comment attached: any of them may be reordered.
fn uncommented(allocator: std.mem.Allocator, count: usize) ![]const bool {
    const flags = try allocator.alloc(bool, count);
    @memset(flags, false);
    return flags;
}
