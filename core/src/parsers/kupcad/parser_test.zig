const std = @import("std");
const testing = std.testing;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const ast = @import("../common/ast.zig");

test "KupCAD Parser: Operator Precedence (* vs +)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "1 + 2 * 3";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseExpression(.none);

    try testing.expectEqual(ast.BinaryOp.add, node.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 1.0), node.kind.binary_op.left.kind.number);

    const right = node.kind.binary_op.right;
    try testing.expectEqual(ast.BinaryOp.multiply, right.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 2.0), right.kind.binary_op.left.kind.number);
    try testing.expectEqual(@as(f64, 3.0), right.kind.binary_op.right.kind.number);
}

test "KupCAD Parser: Right Associativity for Exponentiation (**)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "2 ** 3 ** 4";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseExpression(.none);

    try testing.expectEqual(ast.BinaryOp.exponent, node.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 2.0), node.kind.binary_op.left.kind.number);

    const right = node.kind.binary_op.right;
    try testing.expectEqual(ast.BinaryOp.exponent, right.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 3.0), right.kind.binary_op.left.kind.number);
    try testing.expectEqual(@as(f64, 4.0), right.kind.binary_op.right.kind.number);
}

test "KupCAD Parser: Method Chaining with Named Args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "Box.new(x: 50).translate(z: 10)";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseExpression(.none);

    try testing.expectEqualStrings("translate", node.kind.method_call.method_name);
    try testing.expectEqualStrings("z", node.kind.method_call.args[0].name);
    try testing.expectEqual(@as(f64, 10.0), node.kind.method_call.args[0].value.kind.number);

    const receiver = node.kind.method_call.receiver.?;
    try testing.expectEqualStrings("new", receiver.kind.method_call.method_name);
    try testing.expectEqualStrings("Box", receiver.kind.method_call.receiver.?.kind.identifier);
    try testing.expectEqualStrings("x", receiver.kind.method_call.args[0].name);
    try testing.expectEqual(@as(f64, 50.0), receiver.kind.method_call.args[0].value.kind.number);
}

test "KupCAD Parser: Import Statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "import { ThreadedInsert, Screw } from \"./hardware.kup\"";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseStatement();

    try testing.expectEqualStrings("./hardware.kup", node.kind.import_stmt.path);
    try testing.expectEqual(@as(usize, 2), node.kind.import_stmt.symbols.len);
    try testing.expectEqualStrings("ThreadedInsert", node.kind.import_stmt.symbols[0]);
    try testing.expectEqualStrings("Screw", node.kind.import_stmt.symbols[1]);
}

test "KupCAD Parser: If / Elsif / Else Control Flow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\if x > 10
        \\  a = 1
        \\elsif x == 10
        \\  a = 2
        \\else
        \\  a = 3
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const if_node = try parser.parseStatement();

    // Top IF
    try testing.expectEqual(ast.BinaryOp.greater, if_node.kind.if_stmt.condition.kind.binary_op.op);
    try testing.expectEqualStrings("a", if_node.kind.if_stmt.then_branch.kind.block.stmts[0].kind.assignment.name);

    // ELSIF (nested in else_branch)
    const elsif_node = if_node.kind.if_stmt.else_branch.?;
    try testing.expectEqual(ast.BinaryOp.equal, elsif_node.kind.if_stmt.condition.kind.binary_op.op);
    try testing.expectEqualStrings("a", elsif_node.kind.if_stmt.then_branch.kind.block.stmts[0].kind.assignment.name);

    // ELSE
    const else_block = elsif_node.kind.if_stmt.else_branch.?;
    try testing.expectEqualStrings("a", else_block.kind.block.stmts[0].kind.assignment.name);
}

test "KupCAD Parser: Method Call with Do Block and Parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\base.on_face(:top) do |face, idx|
        \\  c1 + c2
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseStatement();

    try testing.expectEqualStrings("on_face", node.kind.method_call.method_name);

    const block = node.kind.method_call.block.?;
    try testing.expectEqual(@as(usize, 2), block.kind.block.params.len);
    try testing.expectEqualStrings("face", block.kind.block.params[0]);
    try testing.expectEqualStrings("idx", block.kind.block.params[1]);

    const stmts = block.kind.block.stmts;
    try testing.expectEqual(ast.BinaryOp.add, stmts[0].kind.binary_op.op);
}
