const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const parent_map = @import("parent_map.zig");

// Use the existing KupCAD parser test utility
const Lexer = @import("../frontend/kupcad/lexer.zig").Lexer;
const Parser = @import("../frontend/kupcad/parser.zig").Parser;
const ParserTest = @import("../frontend/test_utils.zig").ParserTest;
const KTest = ParserTest(Lexer, Parser);

test "ParentMap: correctly maps children to parents in binary expression" {
    const source = "val = 10 + 20";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var pmap = try parent_map.ParentMap.init(testing.allocator, &pt.parser.b.tree);
    defer pmap.deinit();

    try pmap.build(&pt.parser.b.tree, root_idx);

    const tree = &pt.parser.b.tree;

    // Root is a block. Its parent should be .none.
    try testing.expectEqual(ast.NodeIndex.none, pmap.parents[@intFromEnum(root_idx)]);

    const root_block = tree.block(tree.getNode(root_idx).?);
    const stmts = tree.getNodes(root_block.stmts);
    const assign_idx = stmts[0];

    // The assignment's parent is the root block.
    try testing.expectEqual(root_idx, pmap.parents[@intFromEnum(assign_idx)]);

    const assign = tree.assignment(tree.getNode(assign_idx).?);
    const bin_idx = assign.value;

    // The binary op's parent is the assignment node.
    try testing.expectEqual(assign_idx, pmap.parents[@intFromEnum(bin_idx)]);

    const bin = tree.binaryExpr(tree.getNode(bin_idx).?);
    const left_idx = bin.left;
    const right_idx = bin.right;

    // Both numbers' parents are the binary op node.
    try testing.expectEqual(bin_idx, pmap.parents[@intFromEnum(left_idx)]);
    try testing.expectEqual(bin_idx, pmap.parents[@intFromEnum(right_idx)]);
}

test "ParentMap: correctly maps blocks and method calls" {
    const source =
        \\cube(10) do
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const root_idx = try pt.parser.parseProgram();

    var pmap = try parent_map.ParentMap.init(testing.allocator, &pt.parser.b.tree);
    defer pmap.deinit();

    try pmap.build(&pt.parser.b.tree, root_idx);

    const tree = &pt.parser.b.tree;
    const root_block = tree.block(tree.getNode(root_idx).?);
    const call_idx = tree.getNodes(root_block.stmts)[0];

    // Call's parent is root block
    try testing.expectEqual(root_idx, pmap.parents[@intFromEnum(call_idx)]);

    const call = tree.methodCall(tree.getNode(call_idx).?);
    const arg_idx = tree.getNamedArgs(call.args)[0].value;
    const child_block_idx = call.block;

    // Arg's parent is the call
    try testing.expectEqual(call_idx, pmap.parents[@intFromEnum(arg_idx)]);
    // Nested Block's parent is the call
    try testing.expectEqual(call_idx, pmap.parents[@intFromEnum(child_block_idx)]);
}
