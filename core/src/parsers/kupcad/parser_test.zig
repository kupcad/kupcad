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

    // ELSIF
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

test "KupCAD Parser: Statement Modifiers (Yield Unless)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "yield unless 10 % 3 == 0";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseStatement();

    try testing.expectEqual(true, node.kind.if_stmt.is_unless);
    try testing.expectEqual(ast.BinaryOp.equal, node.kind.if_stmt.condition.kind.binary_op.op);

    const inner_yield = node.kind.if_stmt.then_branch.kind.block.stmts[0];
    try testing.expectEqual(true, inner_yield.kind == .yield_stmt);
}

test "KupCAD Parser: Functions, Classes, Arrays, and Range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\class MyPart < Base
        \\  def is_valid?(x = 10)
        \\    range = 20..100
        \\    arr = [1, 2]
        \\    return x ? true : false
        \\  end
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const class_node = try parser.parseStatement();

    try testing.expectEqualStrings("MyPart", class_node.kind.class_stmt.name);
    try testing.expectEqualStrings("Base", class_node.kind.class_stmt.super_class.?);

    const def_node = class_node.kind.class_stmt.body.kind.block.stmts[0];
    try testing.expectEqualStrings("is_valid?", def_node.kind.def_stmt.name);
    try testing.expectEqualStrings("x", def_node.kind.def_stmt.params[0].name);
    try testing.expectEqual(@as(f64, 10.0), def_node.kind.def_stmt.params[0].default_value.?.kind.number);

    const body_stmts = def_node.kind.def_stmt.body.kind.block.stmts;

    // range = 20..100
    const range_node = body_stmts[0].kind.assignment.value;
    try testing.expectEqual(@as(f64, 20.0), range_node.kind.range.start.kind.number);
    try testing.expectEqual(@as(f64, 100.0), range_node.kind.range.end.kind.number);

    // arr = [1, 2]
    const array_node = body_stmts[1].kind.assignment.value;
    try testing.expectEqual(@as(usize, 2), array_node.kind.array_literal.len);

    // return x ? true : false
    const ret_node = body_stmts[2].kind.return_stmt.?;
    try testing.expectEqualStrings("x", ret_node.kind.ternary_op.condition.kind.identifier);
    try testing.expectEqual(true, ret_node.kind.ternary_op.then_branch.kind.boolean);
    try testing.expectEqual(false, ret_node.kind.ternary_op.else_branch.kind.boolean);
}

test "KupCAD Parser: Shorthand Assignment and Hash Rocket" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\w += 10
        \\map = { "key" => w }
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const add_assign = try parser.parseStatement();
    try testing.expectEqualStrings("w", add_assign.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.add, add_assign.kind.assignment.op.?);

    const hash_assign = try parser.parseStatement();
    const hash_node = hash_assign.kind.assignment.value;
    try testing.expectEqualStrings("key", hash_node.kind.hash_literal[0].key.kind.string);
}

test "KupCAD Parser: String Interpolation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "echo(\"Value: #{x + 10} mm\")";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const echo_call = try parser.parseStatement();
    const interp_node = echo_call.kind.method_call.args[0].value;

    try testing.expectEqual(@as(usize, 3), interp_node.kind.interpolated_string.len);

    // First part: "Value: " (strips opening quote)
    try testing.expectEqualStrings("Value: ", interp_node.kind.interpolated_string[0].kind.string);

    // Middle part: x + 10
    try testing.expectEqual(ast.BinaryOp.add, interp_node.kind.interpolated_string[1].kind.binary_op.op);

    // End part: " mm" (strips closing quote)
    try testing.expectEqualStrings(" mm", interp_node.kind.interpolated_string[2].kind.string);
}

test "KupCAD Parser: Exponentiation vs Unary Precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "-2 ** 2";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseExpression(.none);

    // In Ruby/Crystal, `-2 ** 2` is `(-2) ** 2` (Unary binds tighter)
    try testing.expectEqual(ast.Node.Kind.binary_op, @as(std.meta.Tag(ast.Node.Kind), node.kind));
    try testing.expectEqual(ast.BinaryOp.exponent, node.kind.binary_op.op);

    const left_node = node.kind.binary_op.left;
    try testing.expectEqual(ast.Node.Kind.unary_op, @as(std.meta.Tag(ast.Node.Kind), left_node.kind));
    try testing.expectEqual(ast.UnaryOp.negate, left_node.kind.unary_op.op);
}

test "KupCAD Parser: Parenthesis-less Method Calls (Command Syntax)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "cube x: 10, y: 20";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseStatement();

    try testing.expectEqual(ast.Node.Kind.method_call, @as(std.meta.Tag(ast.Node.Kind), node.kind));
    try testing.expectEqualStrings("cube", node.kind.method_call.method_name);
    try testing.expectEqual(@as(usize, 2), node.kind.method_call.args.len);
    try testing.expectEqualStrings("x", node.kind.method_call.args[0].name);
}

test "KupCAD Parser BUG: Empty String Interpolation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "\"Empty: #{}\"";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseExpression(.none);

    try testing.expectEqual(ast.Node.Kind.interpolated_string, @as(std.meta.Tag(ast.Node.Kind), node.kind));
}

test "KupCAD Parser: Namespace Resolution (Scope Operator ::)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "part = Hardware::Fasteners::M3_Bolt.new(length: 12)";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node = try parser.parseStatement();

    try testing.expectEqual(ast.Node.Kind.assignment, @as(std.meta.Tag(ast.Node.Kind), node.kind));
    const call_node = node.kind.assignment.value;

    try testing.expectEqualStrings("new", call_node.kind.method_call.method_name);

    const receiver = call_node.kind.method_call.receiver.?;
    try testing.expectEqual(ast.Node.Kind.namespace_access, @as(std.meta.Tag(ast.Node.Kind), receiver.kind));
    try testing.expectEqualStrings("Hardware", receiver.kind.namespace_access.path[0]);
    try testing.expectEqualStrings("Fasteners", receiver.kind.namespace_access.path[1]);
    try testing.expectEqualStrings("M3_Bolt", receiver.kind.namespace_access.path[2]);
}

test "KupCAD Parser: Case / When Control Flow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\case part_type
        \\when :screw
        \\  Hardware::Screw.new(length: 10)
        \\when :nut
        \\  Hardware::Nut.new
        \\else
        \\  Box.new
        \\end
    ;

    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node = try parser.parseStatement();

    try testing.expectEqual(ast.Node.Kind.case_stmt, @as(std.meta.Tag(ast.Node.Kind), node.kind));
    try testing.expectEqualStrings("part_type", node.kind.case_stmt.condition.?.kind.identifier);

    const branches = node.kind.case_stmt.when_branches;
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expectEqualStrings("screw", branches[0].conditions[0].kind.symbol);
    try testing.expectEqualStrings("nut", branches[1].conditions[0].kind.symbol);

    const else_branch = node.kind.case_stmt.else_branch.?;
    try testing.expectEqualStrings("new", else_branch.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Multiple Assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "x, y, z = get_coordinates()";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node = try parser.parseStatement();

    try testing.expectEqual(ast.Node.Kind.multiple_assignment, @as(std.meta.Tag(ast.Node.Kind), node.kind));
    try testing.expectEqual(@as(usize, 3), node.kind.multiple_assignment.names.len);
    try testing.expectEqualStrings("x", node.kind.multiple_assignment.names[0]);
    try testing.expectEqualStrings("y", node.kind.multiple_assignment.names[1]);
    try testing.expectEqualStrings("z", node.kind.multiple_assignment.names[2]);
}

test "KupCAD Parser: Self and Super constructs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def build
        \\  super(x: 10)
        \\  self
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const def_node = try parser.parseStatement();

    const stmts = def_node.kind.def_stmt.body.kind.block.stmts;
    try testing.expectEqual(ast.Node.Kind.super_call, @as(std.meta.Tag(ast.Node.Kind), stmts[0].kind));
    try testing.expectEqualStrings("x", stmts[0].kind.super_call.args[0].name);

    try testing.expectEqual(ast.Node.Kind.self_expr, @as(std.meta.Tag(ast.Node.Kind), stmts[1].kind));
}

test "KupCAD Parser: Stabby Lambda (Anonymous Function)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "my_lambda = ->(x, y) { x + y }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node = try parser.parseStatement();

    // Verify it evaluates to Assignment.
    try testing.expectEqual(ast.Node.Kind.assignment, @as(std.meta.Tag(ast.Node.Kind), node.kind));
    const lambda = node.kind.assignment.value;

    // Verify AST Node mapping
    try testing.expectEqual(ast.Node.Kind.lambda_expr, @as(std.meta.Tag(ast.Node.Kind), lambda.kind));

    // Verify mapped params
    try testing.expectEqualStrings("x", lambda.kind.lambda_expr.params[0].name);
    try testing.expectEqualStrings("y", lambda.kind.lambda_expr.params[1].name);

    // Verify mapped AST payload / body block
    const body_stmts = lambda.kind.lambda_expr.body.kind.block.stmts;
    try testing.expectEqual(ast.BinaryOp.add, body_stmts[0].kind.binary_op.op);
}
