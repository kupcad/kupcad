const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const folder = @import("constant_folder.zig");

// Use the existing KupCAD parser test utility
const Lexer = @import("../frontend/kupcad/lexer.zig").Lexer;
const Parser = @import("../frontend/kupcad/parser.zig").Parser;
const ParserTest = @import("../frontend/test_utils.zig").ParserTest;
const KTest = ParserTest(Lexer, Parser);

test "Constant Folder: folds nested binary operations bottom-up" {
    // 10 * 2 + 5  =>  20 + 5  =>  25
    const source = "10 * 2 + 5";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const expr_idx = try pt.parser.parseExpression(.none);

    var f = folder.ConstantFolder{ .b = &pt.parser.b };
    try f.fold(expr_idx);

    // The node should have been successfully mutated into a single number!
    const folded_node = pt.getNode(expr_idx);
    try testing.expectEqual(ast.Tag.number, folded_node.tag);
    try testing.expectEqual(@as(f64, 25.0), pt.parser.b.tree.number(folded_node));
    try testing.expectEqual(@as(usize, 2), f.folded_count); // 2 operations folded
}

test "Constant Folder: folds unary and binary operations together" {
    // -(10 + 5) * 2  =>  -(15) * 2  =>  -15 * 2  =>  -30
    const source = "-(10 + 5) * 2";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const expr_idx = try pt.parser.parseExpression(.none);

    var f = folder.ConstantFolder{ .b = &pt.parser.b };
    try f.fold(expr_idx);

    const folded_node = pt.getNode(expr_idx);
    try testing.expectEqual(ast.Tag.number, folded_node.tag);
    try testing.expectEqual(@as(f64, -30.0), pt.parser.b.tree.number(folded_node));
    try testing.expectEqual(@as(usize, 3), f.folded_count); // Add, Negate, Multiply
}

test "ConstantFolder: leaves non-finite results unfolded" {
    // Division/modulo by zero and overflow to Inf must stay runtime operations
    const sources = [_][]const u8{ "val = 10 / 0", "val = 1e300 * 1e300", "val = 10 % 0.0" };
    for (sources) |source| {
        var pt = try KTest.init(source);
        defer pt.deinit();
        const tree = &pt.parser.b.tree;

        const root_idx = try pt.parser.parseProgram();
        var f = folder.ConstantFolder{ .b = &pt.parser.b };
        try f.fold(root_idx);

        try testing.expectEqual(@as(usize, 0), f.folded_count);
        const stmt = pt.getNode(tree.getNodes(tree.block(pt.getNode(root_idx)).stmts)[0]);
        try testing.expectEqual(ast.Tag.binary_op, pt.getNode(tree.assignment(stmt).value).tag);
    }
}
