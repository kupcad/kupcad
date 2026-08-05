const std = @import("std");
const testing = std.testing;
const ast = @import("../../core/ast.zig");
const ParserTest = @import("../test_utils.zig").ParserTest;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;

const KTest = ParserTest(Lexer, Parser);

test "AST Node Memory Size Optimization" {
    // Verifies that large payload boxing keeps Node struct size <= 40 bytes
    try testing.expect(@sizeOf(ast.NodeKind) <= 40);
}

test "AST Builder: String Interning Memory Optimization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var builder = ast.Builder.init(arena.allocator());
    defer builder.deinit();

    const str1 = try builder.intern("duplicate_key");
    const str2 = try builder.intern("duplicate_key");

    // Must return the exact same slice pointer (identical memory address)
    try testing.expectEqual(str1.ptr, str2.ptr);
    try testing.expectEqualStrings("duplicate_key", str1);
}

test "KupCAD Parser: Operator Precedence (* vs +)" {
    var pt = try KTest.init("1 + 2 * 3");
    defer pt.deinit();

    const stmt = try pt.parser.parseExpression(.none);

    try testing.expectEqual(ast.BinaryOp.add, stmt.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 1.0), stmt.kind.binary_op.left.kind.number);

    const right = stmt.kind.binary_op.right;
    try testing.expectEqual(ast.BinaryOp.multiply, right.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 2.0), right.kind.binary_op.left.kind.number);
    try testing.expectEqual(@as(f64, 3.0), right.kind.binary_op.right.kind.number);
}

test "KupCAD Parser: Right Associativity for Exponentiation (**)" {
    var pt = try KTest.init("2 ** 3 ** 4");
    defer pt.deinit();

    const stmt = try pt.parser.parseExpression(.none);

    try testing.expectEqual(ast.BinaryOp.exponent, stmt.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 2.0), stmt.kind.binary_op.left.kind.number);

    const right = stmt.kind.binary_op.right;
    try testing.expectEqual(ast.BinaryOp.exponent, right.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 3.0), right.kind.binary_op.left.kind.number);
    try testing.expectEqual(@as(f64, 4.0), right.kind.binary_op.right.kind.number);
}

test "KupCAD Parser: Method Chaining with Named Args" {
    var pt = try KTest.init("Box.new(x: 50).translate(z: 10)");
    defer pt.deinit();

    const stmt = try pt.parser.parseExpression(.none);

    try testing.expectEqualStrings("translate", stmt.kind.method_call.method_name);
    try testing.expectEqualStrings("z", stmt.kind.method_call.args[0].name);
    try testing.expectEqual(@as(f64, 10.0), stmt.kind.method_call.args[0].value.kind.number);

    const receiver = stmt.kind.method_call.receiver.?;
    try testing.expectEqualStrings("new", receiver.kind.method_call.method_name);
    try testing.expectEqualStrings("Box", receiver.kind.method_call.receiver.?.kind.identifier);
    try testing.expectEqualStrings("x", receiver.kind.method_call.args[0].name);
    try testing.expectEqual(@as(f64, 50.0), receiver.kind.method_call.args[0].value.kind.number);
}

test "KupCAD Parser: Import Statement" {
    const source = "import { ThreadedInsert, Screw } from \"./hardware.kup\"";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqualStrings("./hardware.kup", stmt.kind.import_stmt.path);
    try testing.expectEqual(@as(usize, 2), stmt.kind.import_stmt.symbols.len);
    try testing.expectEqualStrings("ThreadedInsert", stmt.kind.import_stmt.symbols[0]);
    try testing.expectEqualStrings("Screw", stmt.kind.import_stmt.symbols[1]);
}

test "KupCAD Parser: If / Elsif / Else Control Flow" {
    const source =
        \\if x > 10
        \\  a = 1
        \\elsif x == 10
        \\  a = 2
        \\else
        \\  a = 3
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const if_node = try pt.parser.parseStatement();

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
    const source =
        \\base.on_face(:top) do |face, idx|
        \\  c1 + c2
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqualStrings("on_face", stmt.kind.method_call.method_name);
    const block = stmt.kind.method_call.block.?;

    try testing.expectEqual(@as(usize, 2), block.kind.block.params.len);
    try testing.expectEqualStrings("face", block.kind.block.params[0].kind.identifier);
    try testing.expectEqualStrings("idx", block.kind.block.params[1].kind.identifier);

    const stmts = block.kind.block.stmts;
    try testing.expectEqual(ast.BinaryOp.add, stmts[0].kind.binary_op.op);
}

test "KupCAD Parser: Statement Modifiers (Yield Unless)" {
    const source = "yield unless 10 % 3 == 0";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(true, stmt.kind.if_stmt.is_unless);
    try testing.expectEqual(ast.BinaryOp.equal, stmt.kind.if_stmt.condition.kind.binary_op.op);

    const inner_yield = stmt.kind.if_stmt.then_branch.kind.block.stmts[0];
    try testing.expectEqual(@as(usize, 0), inner_yield.kind.yield_stmt.len);
}

test "KupCAD Parser: Functions, Classes, Arrays, and Range" {
    const source =
        \\class MyPart < Base
        \\  def is_valid?(x = 10)
        \\    range = 20..100
        \\    arr = [1, 2]
        \\    return x ? true : false
        \\  end
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const class_stmt = try pt.parser.parseStatement();

    try testing.expectEqualStrings("MyPart", class_stmt.kind.class_stmt.name.kind.identifier);
    try testing.expectEqualStrings("Base", class_stmt.kind.class_stmt.super_class.?.kind.identifier);

    const def_node = class_stmt.kind.class_stmt.body.kind.block.stmts[0];
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
    const source =
        \\w += 10
        \\map = { "key" => w }
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const add_assign = try pt.parser.parseStatement();

    try testing.expectEqualStrings("w", add_assign.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.add, add_assign.kind.assignment.op.?);

    const hash_assign = try pt.parser.parseStatement();
    const hash_node = hash_assign.kind.assignment.value;
    try testing.expectEqualStrings("key", hash_node.kind.hash_literal[0].key.kind.string);
}

test "KupCAD Parser: String Interpolation" {
    const source = "echo(\"Value: #{x + 10} mm\")";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const echo_call = try pt.parser.parseStatement();

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
    const source = "-2 ** 2";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseExpression(.none);

    // In Ruby/Crystal, `-2 ** 2` is `-(2 ** 2)` (Exponentiation binds tighter)
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).unary_op, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(ast.UnaryOp.negate, stmt.kind.unary_op.op);

    const right_node = stmt.kind.unary_op.operand;
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).binary_op, @as(std.meta.Tag(ast.NodeKind), right_node.kind));
    try testing.expectEqual(ast.BinaryOp.exponent, right_node.kind.binary_op.op);
}

test "KupCAD Parser: Parenthesis-less Method Calls (Command Syntax)" {
    const source = "cube x: 10, y: 20";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("cube", stmt.kind.method_call.method_name);
    try testing.expectEqual(@as(usize, 2), stmt.kind.method_call.args.len);
    try testing.expectEqualStrings("x", stmt.kind.method_call.args[0].name);
}

test "KupCAD Parser BUG: Empty String Interpolation" {
    const source = "\"Empty: #{}\"";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseExpression(.none);

    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
}

test "KupCAD Parser: Namespace Resolution (Scope Operator ::)" {
    const source = "part = Hardware::Fasteners::M3_Bolt.new(length: 12)";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    const call_node = stmt.kind.assignment.value;
    try testing.expectEqualStrings("new", call_node.kind.method_call.method_name);

    const receiver = call_node.kind.method_call.receiver.?;
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), receiver.kind));
    try testing.expectEqualStrings("Hardware", receiver.kind.namespace_access.path[0]);
    try testing.expectEqualStrings("Fasteners", receiver.kind.namespace_access.path[1]);
    try testing.expectEqualStrings("M3_Bolt", receiver.kind.namespace_access.path[2]);
}

test "KupCAD Parser: Case / When Control Flow" {
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
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.case_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("part_type", stmt.kind.case_stmt.condition.?.kind.identifier);

    const branches = stmt.kind.case_stmt.when_branches;
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expectEqualStrings("screw", branches[0].conditions[0].kind.symbol);
    try testing.expectEqualStrings("nut", branches[1].conditions[0].kind.symbol);

    const else_branch = stmt.kind.case_stmt.else_branch.?;
    try testing.expectEqualStrings("new", else_branch.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Multiple Assignment" {
    const source = "x, y, z = get_coordinates()";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.multiple_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(@as(usize, 3), stmt.kind.multiple_assignment.lhs.len);
    try testing.expectEqualStrings("x", stmt.kind.multiple_assignment.lhs[0].name);
    try testing.expectEqualStrings("y", stmt.kind.multiple_assignment.lhs[1].name);
    try testing.expectEqualStrings("z", stmt.kind.multiple_assignment.lhs[2].name);
}

test "KupCAD Parser: Self and Super constructs" {
    const source =
        \\def build
        \\  super(x: 10)
        \\  self
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const def_node = try pt.parser.parseStatement();

    const stmts = def_node.kind.def_stmt.body.kind.block.stmts;
    try testing.expectEqual(ast.NodeKind.super_call, @as(std.meta.Tag(ast.NodeKind), stmts[0].kind));
    try testing.expectEqualStrings("x", stmts[0].kind.super_call.args[0].name);
    try testing.expectEqual(ast.NodeKind.self_expr, @as(std.meta.Tag(ast.NodeKind), stmts[1].kind));
}

test "KupCAD Parser: Stabby Lambda (Anonymous Function)" {
    const source = "my_lambda = ->(x, y) { x + y }";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    // Verify it evaluates to Assignment.
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    const lambda = stmt.kind.assignment.value;

    // Verify AST Node mapping
    try testing.expectEqual(ast.NodeKind.lambda_expr, @as(std.meta.Tag(ast.NodeKind), lambda.kind));

    // Verify mapped params
    try testing.expectEqualStrings("x", lambda.kind.lambda_expr.params[0].name);
    try testing.expectEqualStrings("y", lambda.kind.lambda_expr.params[1].name);

    // Verify mapped AST payload / body block
    const body_stmts = lambda.kind.lambda_expr.body.kind.block.stmts;
    try testing.expectEqual(ast.BinaryOp.add, body_stmts[0].kind.binary_op.op);
}

test "KupCAD Parser: Exclusive Range (...)" {
    const source = "1...5";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseExpression(.none);

    try testing.expectEqual(ast.NodeKind.range, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.range.is_exclusive);
    try testing.expectEqual(@as(f64, 5.0), stmt.kind.range.end.kind.number);
}

test "KupCAD Parser: Statement Modifiers (Trailing if)" {
    const source = "box.chamfer() if render_chamfer";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("render_chamfer", stmt.kind.if_stmt.condition.kind.identifier);

    // The then_branch block should wrap the method call statement
    const then_branch = stmt.kind.if_stmt.then_branch;
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), then_branch.kind.block.stmts[0].kind));
}

test "KupCAD Parser: Unary Plus Support" {
    const source = "val = +10";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const assign_node = try pt.parser.parseStatement();

    try testing.expectEqualStrings("val", assign_node.kind.assignment.name);
    try testing.expectEqual(ast.UnaryOp.positive, assign_node.kind.assignment.value.kind.unary_op.op);
}

test "KupCAD Parser: Splats and Block Forwarding" {
    const source =
        \\def wrapper(*args, **kwargs, &block)
        \\  target.call(*args, **kwargs, &block)
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const def_node = try pt.parser.parseStatement();

    // Validate Function Parameters
    const params = def_node.kind.def_stmt.params;
    try testing.expectEqual(ast.ArgModifier.splat, params[0].modifier.?);
    try testing.expectEqualStrings("args", params[0].name);
    try testing.expectEqual(ast.ArgModifier.double_splat, params[1].modifier.?);
    try testing.expectEqualStrings("kwargs", params[1].name);
    try testing.expectEqual(ast.ArgModifier.block, params[2].modifier.?);
    try testing.expectEqualStrings("block", params[2].name);

    // Validate Method Call Arguments
    const call_node = def_node.kind.def_stmt.body.kind.block.stmts[0];
    const args = call_node.kind.method_call.args;
    try testing.expectEqual(ast.ArgModifier.splat, args[0].modifier.?);
    try testing.expectEqual(ast.ArgModifier.double_splat, args[1].modifier.?);
    try testing.expectEqual(ast.ArgModifier.block, args[2].modifier.?);
}

test "KupCAD Parser: Shift/Append (<<) and Safe Navigation (&.)" {
    const source = "arr << 5\npart&.cut()";
    var pt = try KTest.init(source);
    defer pt.deinit();

    // Validate Append / Shift Left
    const shift_node = try pt.parser.parseStatement();
    try testing.expectEqual(ast.BinaryOp.shift_left, shift_node.kind.binary_op.op);
    try testing.expectEqualStrings("arr", shift_node.kind.binary_op.left.kind.identifier);
    try testing.expectEqual(@as(f64, 5.0), shift_node.kind.binary_op.right.kind.number);

    // Validate Safe Navigation Call
    const safe_call = try pt.parser.parseStatement();
    try testing.expectEqualStrings("cut", safe_call.kind.method_call.method_name);
    try testing.expectEqual(true, safe_call.kind.method_call.is_safe);
}

test "KupCAD Parser: CSG Intersections and Bitwise Operators" {
    // Simulates an inversion and a CSG Intersection
    const source = "result = ~part1 & part2 | part3 ^ part4";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    // Assigning to `result`
    try testing.expectEqualStrings("result", stmt.kind.assignment.name);

    // The lowest precedence here is Bitwise OR (`|`) and XOR (`^`) which share a level.
    // They are left-associative, so the root of the tree is the XOR (`^`)
    const xor_node = stmt.kind.assignment.value;
    try testing.expectEqual(ast.BinaryOp.bitwise_xor, xor_node.kind.binary_op.op);
    try testing.expectEqualStrings("part4", xor_node.kind.binary_op.right.kind.identifier);

    // Left side of XOR is the OR (`|`)
    const or_node = xor_node.kind.binary_op.left;
    try testing.expectEqual(ast.BinaryOp.bitwise_or, or_node.kind.binary_op.op);
    try testing.expectEqualStrings("part3", or_node.kind.binary_op.right.kind.identifier);

    // Left side of OR is the AND (`&`)
    const and_node = or_node.kind.binary_op.left;
    try testing.expectEqual(ast.BinaryOp.bitwise_and, and_node.kind.binary_op.op);
    try testing.expectEqualStrings("part2", and_node.kind.binary_op.right.kind.identifier);

    // Left side of AND is the Unary NOT (`~`)
    const not_node = and_node.kind.binary_op.left;
    try testing.expectEqual(ast.UnaryOp.bitwise_not, not_node.kind.unary_op.op);
    try testing.expectEqualStrings("part1", not_node.kind.unary_op.operand.kind.identifier);
}

test "KupCAD Parser: Curly Brace Method Blocks" {
    const source = "faces.each { |f| f.fillet(2) }";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqualStrings("each", stmt.kind.method_call.method_name);
    const block = stmt.kind.method_call.block.?;
    try testing.expectEqualStrings("f", block.kind.block.params[0].kind.identifier);
    try testing.expectEqualStrings("fillet", block.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Next Statement and Until/While Modifiers" {
    const source = "next 10 until x == 5";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.while_stmt.is_until);

    const inner_next = stmt.kind.while_stmt.body.kind.block.stmts[0];
    try testing.expectEqual(ast.NodeKind.next_stmt, @as(std.meta.Tag(ast.NodeKind), inner_next.kind));
    try testing.expectEqual(@as(f64, 10.0), inner_next.kind.next_stmt.?.kind.number);
}

test "KupCAD Parser: LHS Splats and Multiple Assignment" {
    const source = "first, *rest = get_faces()";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    const lhs = stmt.kind.multiple_assignment.lhs;
    try testing.expectEqual(@as(usize, 2), lhs.len);
    try testing.expectEqualStrings("first", lhs[0].name);
    try testing.expectEqual(ast.ArgModifier.splat, lhs[1].modifier.?);
    try testing.expectEqualStrings("rest", lhs[1].name);
}

test "KupCAD Parser: Keyword Arguments in Definitions" {
    const source = "def build(width:, height: 10)\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    const params = stmt.kind.def_stmt.params;
    try testing.expectEqual(true, params[0].is_keyword);
    try testing.expectEqualStrings("width", params[0].name);
    try testing.expectEqual(true, params[1].is_keyword);
    try testing.expectEqualStrings("height", params[1].name);
    try testing.expectEqual(@as(f64, 10.0), params[1].default_value.?.kind.number);
}

test "KupCAD Parser: Begin / Rescue / Ensure" {
    const source = "begin\n  build()\nrescue => e\n  log()\nensure\n  clean()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("build", stmt.kind.begin_stmt.body.kind.block.stmts[0].kind.method_call.method_name);
    try testing.expectEqualStrings("log", stmt.kind.begin_stmt.rescues[0].body.kind.block.stmts[0].kind.method_call.method_name);
    try testing.expectEqualStrings("clean", stmt.kind.begin_stmt.ensure_body.?.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Object Property Assignment" {
    const source = "box.width = 100";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("box", stmt.kind.property_assignment.target.kind.identifier);
    try testing.expectEqualStrings("width", stmt.kind.property_assignment.property);
    try testing.expectEqual(@as(f64, 100.0), stmt.kind.property_assignment.value.kind.number);
}

test "KupCAD Parser: Receiver Command Syntax" {
    const source = "box.translate x: 10, y: 20 do\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("translate", stmt.kind.method_call.method_name);
    try testing.expectEqualStrings("box", stmt.kind.method_call.receiver.?.kind.identifier);

    const args = stmt.kind.method_call.args;
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("x", args[0].name);
    try testing.expectEqualStrings("y", args[1].name);
    try testing.expect(stmt.kind.method_call.block != null);
}

test "KupCAD Parser: Begin / Rescue / Ensure with Classes" {
    const source = "begin\n  build()\nrescue IOError, KeyError => e\n  log()\nensure\n  clean()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("build", stmt.kind.begin_stmt.body.kind.block.stmts[0].kind.method_call.method_name);

    const rescue_clause = stmt.kind.begin_stmt.rescues[0];
    try testing.expectEqual(@as(usize, 2), rescue_clause.errors.len);
    try testing.expectEqualStrings("IOError", rescue_clause.errors[0]);
    try testing.expectEqualStrings("KeyError", rescue_clause.errors[1]);
    try testing.expectEqualStrings("e", rescue_clause.variable.?);
    try testing.expectEqualStrings("log", rescue_clause.body.kind.block.stmts[0].kind.method_call.method_name);
    try testing.expectEqualStrings("clean", stmt.kind.begin_stmt.ensure_body.?.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Inline Rescue Modifier" {
    const source = "val = dangerous() rescue 0";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    const res_mod = stmt.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.rescue_modifier, @as(std.meta.Tag(ast.NodeKind), res_mod.kind));
    try testing.expectEqualStrings("dangerous", res_mod.kind.rescue_modifier.expr.kind.method_call.method_name);
    try testing.expectEqual(@as(f64, 0.0), res_mod.kind.rescue_modifier.rescue_expr.kind.number);
}

test "KupCAD Lexer and Parser: Percent Literals (%w, %i)" {
    const source = "list = %w[gear shaft motor]";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    const arr = stmt.kind.assignment.value.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqualStrings("gear", arr[0].kind.string);
    try testing.expectEqualStrings("shaft", arr[1].kind.string);
    try testing.expectEqualStrings("motor", arr[2].kind.string);
}

test "KupCAD Parser: Class Methods and Namespaced Inheritance" {
    const source = "class Hardware::Screw < Base::Part\n  def self.build()\n  end\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const class_stmt = try pt.parser.parseStatement();

    // Check Namespaces
    try testing.expectEqualStrings("Hardware", class_stmt.kind.class_stmt.name.kind.namespace_access.path[0]);
    try testing.expectEqualStrings("Base", class_stmt.kind.class_stmt.super_class.?.kind.namespace_access.path[0]);

    // Check Class Method
    const def_node = class_stmt.kind.class_stmt.body.kind.block.stmts[0];
    try testing.expectEqual(true, def_node.kind.def_stmt.is_class_method);
    try testing.expectEqualStrings("build", def_node.kind.def_stmt.name);
}

test "KupCAD Parser: Implicit RHS Tuples and Array/Hash Splats" {
    const source = "x, y = 10, 20\narr = [1, *other]\nopts = {a: 1, **kwargs}";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const multi_assign = try pt.parser.parseStatement();
    try testing.expectEqual(@as(usize, 2), multi_assign.kind.multiple_assignment.value.kind.array_literal.len); // Implicit tuple array

    const arr_assign = try pt.parser.parseStatement();
    const arr_lit = arr_assign.kind.assignment.value.kind.array_literal;
    try testing.expectEqual(ast.NodeKind.splat_expr, @as(std.meta.Tag(ast.NodeKind), arr_lit[1].kind));

    const hash_assign = try pt.parser.parseStatement();
    const hash_lit = hash_assign.kind.assignment.value.kind.hash_literal;
    try testing.expectEqual(ast.NodeKind.double_splat_expr, @as(std.meta.Tag(ast.NodeKind), hash_lit[1].key.kind));
}

test "KupCAD Parser: Quoted Symbols, Single Quotes, Destructuring" {
    const source = "map.each(:'key name') do |(x, y), val|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    const args = stmt.kind.method_call.args;
    try testing.expectEqualStrings("key name", args[0].value.kind.symbol); // Quoted Symbol

    const params = stmt.kind.method_call.block.?.kind.block.params;
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), params[0].kind));
    try testing.expectEqualStrings("x", params[0].kind.array_literal[0].kind.identifier); // Nested Tuple
    try testing.expectEqualStrings("y", params[0].kind.array_literal[1].kind.identifier);
    try testing.expectEqualStrings("val", params[1].kind.identifier);
}

test "KupCAD Parser: Super with Command Syntax and Blocks" {
    const source = "super x: 10 do\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.super_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("x", stmt.kind.super_call.args[0].name);
    try testing.expect(stmt.kind.super_call.block != null);
}

test "KupCAD Parser: Optional 'then' Keyword" {
    const source = "if x > 5 then a = 1 end";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("a", stmt.kind.if_stmt.then_branch.kind.block.stmts[0].kind.assignment.name);
}

test "KupCAD Parser: Implicit Def Rescue / Ensure" {
    const source =
        \\def process
        \\  run_step()
        \\rescue => err
        \\  handle_error()
        \\ensure
        \\  cleanup()
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const def_node = try pt.parser.parseStatement();

    try testing.expectEqualStrings("process", def_node.kind.def_stmt.name);

    // Body should be wrapped in an implicit begin_stmt
    const begin_node = def_node.kind.def_stmt.body;
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), begin_node.kind));

    // Verify main body
    try testing.expectEqualStrings("run_step", begin_node.kind.begin_stmt.body.kind.block.stmts[0].kind.method_call.method_name);

    // Verify rescue
    const rescue_clause = begin_node.kind.begin_stmt.rescues[0];
    try testing.expectEqualStrings("err", rescue_clause.variable.?);
    try testing.expectEqualStrings("handle_error", rescue_clause.body.kind.block.stmts[0].kind.method_call.method_name);

    // Verify ensure
    try testing.expectEqualStrings("cleanup", begin_node.kind.begin_stmt.ensure_body.?.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Advanced Number Literals (0x, 0b, 0o, Scientific, Underscores)" {
    const source =
        \\hex = 0x1F
        \\bin = 0b1010
        \\oct = 0o755
        \\sci = 1.5e3
        \\num = 1_000_000
        \\leading_dot = .56
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    // 0x1F = 31
    const n1 = try pt.parser.parseStatement();
    try testing.expectEqual(@as(f64, 31.0), n1.kind.assignment.value.kind.number);

    // 0b1010 = 10
    const n2 = try pt.parser.parseStatement();
    try testing.expectEqual(@as(f64, 10.0), n2.kind.assignment.value.kind.number);

    // 0o755 = 493
    const n3 = try pt.parser.parseStatement();
    try testing.expectEqual(@as(f64, 493.0), n3.kind.assignment.value.kind.number);

    // 1.5e3 = 1500
    const n4 = try pt.parser.parseStatement();
    try testing.expectEqual(@as(f64, 1500.0), n4.kind.assignment.value.kind.number);

    // 1_000_000 = 1000000
    const n5 = try pt.parser.parseStatement();
    try testing.expectEqual(@as(f64, 1000000.0), n5.kind.assignment.value.kind.number);

    // .56 = 0.56
    const n6 = try pt.parser.parseStatement();
    try testing.expectEqual(@as(f64, 0.56), n6.kind.assignment.value.kind.number);
}

test "KupCAD Parser: Multi-line Method Chaining (Fluent API)" {
    const source =
        \\Box.new(10)
        \\  .chamfer(2)
        \\  .translate(x: 5)
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt = try pt.parser.parseStatement();

    // Top node is translate
    try testing.expectEqualStrings("translate", stmt.kind.method_call.method_name);

    // Receiver of translate is chamfer
    const chamfer_node = stmt.kind.method_call.receiver.?;
    try testing.expectEqualStrings("chamfer", chamfer_node.kind.method_call.method_name);

    // Receiver of chamfer is new
    const new_node = chamfer_node.kind.method_call.receiver.?;
    try testing.expectEqualStrings("new", new_node.kind.method_call.method_name);
}

test "KupCAD Parser: Import / Export with Attributes (with {})" {
    const source =
        \\import { names } from "module-name" with { key: "data", key2: "data2" }
        \\export { names } from "module-name" with {}
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    // Import Statement
    const imp_node = try pt.parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.import_stmt, @as(std.meta.Tag(ast.NodeKind), imp_node.kind));
    try testing.expectEqualStrings("module-name", imp_node.kind.import_stmt.path);
    try testing.expectEqualStrings("names", imp_node.kind.import_stmt.symbols[0]);

    const attrs = imp_node.kind.import_stmt.attributes.?;
    try testing.expectEqual(@as(usize, 2), attrs.kind.hash_literal.len);
    try testing.expectEqualStrings("key", attrs.kind.hash_literal[0].key.kind.symbol);

    // Export Statement
    const exp_node = try pt.parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.export_stmt, @as(std.meta.Tag(ast.NodeKind), exp_node.kind));
    try testing.expectEqualStrings("module-name", exp_node.kind.export_stmt.path);

    const exp_attrs = exp_node.kind.export_stmt.attributes.?;
    try testing.expectEqual(@as(usize, 0), exp_attrs.kind.hash_literal.len);
}

test "KupCAD Parser: Optional Imports and Trailing Call Commas" {
    const source =
        \\import "global_config.kup"
        \\import Hardware from "hardware.kup"
        \\cube(10, 20, )
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    // Plain import
    const imp_node_1 = try pt.parser.parseStatement();
    try testing.expectEqualStrings("global_config.kup", imp_node_1.kind.import_stmt.path);
    try testing.expectEqual(@as(usize, 0), imp_node_1.kind.import_stmt.symbols.len);

    // Single-symbol import
    const imp_node_2 = try pt.parser.parseStatement();
    try testing.expectEqualStrings("hardware.kup", imp_node_2.kind.import_stmt.path);
    try testing.expectEqualStrings("Hardware", imp_node_2.kind.import_stmt.symbols[0]);

    // Method call trailing comma bypass
    const call_node = try pt.parser.parseStatement();
    try testing.expectEqualStrings("cube", call_node.kind.method_call.method_name);
    try testing.expectEqual(@as(usize, 2), call_node.kind.method_call.args.len);
}

test "KupCAD Parser: Diagnostics for Unexpected Token" {
    // Missing closing parenthesis
    const source = "(x + 1 ]";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const result = pt.parser.parseExpression(.none);

    // Assert it fails with the correct error
    try testing.expectError(error.UnexpectedToken, result);

    // Assert the diagnostic was captured
    try testing.expectEqual(@as(usize, 1), pt.parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Expected 'r_paren', but found ']'", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Diagnostics for Invalid Expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // We intentionally leave the RHS of an assignment as a curly brace
    const source = "val = }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const result = parser.parseStatement();

    try testing.expectError(error.InvalidExpression, result);

    try testing.expectEqual(@as(usize, 1), parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Invalid expression starting with '}'", parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Combinators and Trailing Commas" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\arr = [1, 2, ]
        \\map = {a: 1, b: 2, }
        \\obj.each do |x, y, |
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // Arrays
    const n1 = try parser.parseStatement();
    try testing.expectEqual(@as(usize, 2), n1.kind.assignment.value.kind.array_literal.len);

    // Hashes
    const n2 = try parser.parseStatement();
    try testing.expectEqual(@as(usize, 2), n2.kind.assignment.value.kind.hash_literal.len);

    // Block Params
    const n3 = try parser.parseStatement();
    try testing.expectEqual(@as(usize, 2), n3.kind.method_call.block.?.kind.block.params.len);
}

test "KupCAD Parser: Index Access and Index Compound Assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "points[0] += offset * 2";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.index_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("points", stmt.kind.index_assignment.target.kind.identifier);
    try testing.expectEqual(@as(f64, 0.0), stmt.kind.index_assignment.index.kind.number);
    try testing.expectEqual(ast.BinaryOp.add, stmt.kind.index_assignment.op.?);
    try testing.expectEqual(ast.BinaryOp.multiply, stmt.kind.index_assignment.value.kind.binary_op.op);
}

test "KupCAD Parser: Nested Module Definitions and Export Statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\export { Enclosure, Mount } from "./housing.kup" with { version: 2 }
        \\module Hardware
        \\  class Screw < Base
        \\  end
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const export_node = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.export_stmt, @as(std.meta.Tag(ast.NodeKind), export_node.kind));
    try testing.expectEqualStrings("./housing.kup", export_node.kind.export_stmt.path);
    try testing.expectEqualStrings("Enclosure", export_node.kind.export_stmt.symbols[0]);
    try testing.expectEqualStrings("Mount", export_node.kind.export_stmt.symbols[1]);

    const mod_node = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.module_stmt, @as(std.meta.Tag(ast.NodeKind), mod_node.kind));
    try testing.expectEqualStrings("Hardware", mod_node.kind.module_stmt.name);

    const inner_class = mod_node.kind.module_stmt.body.kind.block.stmts[0];
    try testing.expectEqualStrings("Screw", inner_class.kind.class_stmt.name.kind.identifier);
}

test "KupCAD Parser: Multi-line Arrays with Interspersed Comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\pts = [
        \\  # start point
        \\  10,
        \\  # mid point
        \\  20,
        \\  30
        \\]
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    const arr = stmt.kind.assignment.value.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(f64, 10.0), arr[0].kind.number);
    try testing.expectEqual(@as(f64, 20.0), arr[1].kind.number);
    try testing.expectEqual(@as(f64, 30.0), arr[2].kind.number);
}

test "KupCAD Parser: Safe Navigation Multi-line Fluent API" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\part
        \\  &.cut(hole)
        \\  &.chamfer(radius: 1.5)
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("chamfer", stmt.kind.method_call.method_name);
    try testing.expectEqual(true, stmt.kind.method_call.is_safe);

    const prev_call = stmt.kind.method_call.receiver.?;
    try testing.expectEqualStrings("cut", prev_call.kind.method_call.method_name);
    try testing.expectEqual(true, prev_call.kind.method_call.is_safe);
}

test "KupCAD Parser: Parametric Doc Comments Parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "# @param length [Length] Screw length { min: 10, max: 20 }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqual(std.meta.Tag(ast.NodeKind).param_doc, std.meta.activeTag(stmt.kind));
    const doc = stmt.kind.param_doc;

    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("length", doc.target_name.?);
    try testing.expectEqualStrings("Length", doc.type_name.?);
    try testing.expectEqualStrings("Screw length", doc.description);

    // Verify the sub-parser successfully parsed the options into a HashLiteral AST node
    const options_hash = doc.options_expr.?.kind.hash_literal;
    try testing.expectEqual(@as(usize, 2), options_hash.len);
    try testing.expectEqualStrings("min", options_hash[0].key.kind.symbol);
    try testing.expectEqual(@as(f64, 10.0), options_hash[0].value.kind.number);
}

test "KupCAD Parser: Diagnostics for Malformed Class Declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "class Box < 123\nend";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const result = parser.parseStatement();

    try testing.expectError(error.UnexpectedToken, result);

    try testing.expectEqual(@as(usize, 1), parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Expected 'constant', but found '123'", parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: CSG Math Chains with Mixed Arithmetic and Set Operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Union (+), Difference (-), Intersection (&) CSG expression pipeline
    const source = "base_mesh + (cover - cylinder(r: 2)) & boundary";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    // Intersection (&) has lower precedence than union (+)/difference (-) in KupCAD, so it's root
    try testing.expectEqual(ast.BinaryOp.bitwise_and, stmt.kind.binary_op.op);
    try testing.expectEqualStrings("boundary", stmt.kind.binary_op.right.kind.identifier);

    const left_expr = stmt.kind.binary_op.left; // base_mesh + (cover - cylinder)
    try testing.expectEqual(ast.BinaryOp.add, left_expr.kind.binary_op.op);
    try testing.expectEqualStrings("base_mesh", left_expr.kind.binary_op.left.kind.identifier);

    const paren_expr = left_expr.kind.binary_op.right; // (cover - cylinder)
    try testing.expectEqual(ast.BinaryOp.subtract, paren_expr.kind.binary_op.op);
    try testing.expectEqualStrings("cover", paren_expr.kind.binary_op.left.kind.identifier);
    try testing.expectEqualStrings("cylinder", paren_expr.kind.binary_op.right.kind.method_call.method_name);
}

test "KupCAD Parser: Nested Command Syntax Transforms with Blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\translate x: 10, y: 20 do
        \\  rotate z: 45 do
        \\    cube size: 10
        \\  end
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const top_call = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), top_call.kind));
    try testing.expectEqualStrings("translate", top_call.kind.method_call.method_name);
    try testing.expectEqual(@as(usize, 2), top_call.kind.method_call.args.len);

    const rotate_call = top_call.kind.method_call.block.?.kind.block.stmts[0];
    try testing.expectEqualStrings("rotate", rotate_call.kind.method_call.method_name);

    const cube_call = rotate_call.kind.method_call.block.?.kind.block.stmts[0];
    try testing.expectEqualStrings("cube", cube_call.kind.method_call.method_name);
    try testing.expectEqualStrings("size", cube_call.kind.method_call.args[0].name);
}

test "KupCAD Parser: Range Slicing inside Indexing Operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "subset = vertices[1..4]";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqualStrings("subset", stmt.kind.assignment.name);

    const index_access = stmt.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.index_access, @as(std.meta.Tag(ast.NodeKind), index_access.kind));
    try testing.expectEqualStrings("vertices", index_access.kind.index_access.target.kind.identifier);

    const range_node = index_access.kind.index_access.index;
    try testing.expectEqual(ast.NodeKind.range, @as(std.meta.Tag(ast.NodeKind), range_node.kind));
    try testing.expectEqual(@as(f64, 1.0), range_node.kind.range.start.kind.number);
    try testing.expectEqual(@as(f64, 4.0), range_node.kind.range.end.kind.number);
    try testing.expectEqual(false, range_node.kind.range.is_exclusive);
}

test "KupCAD Parser: Complex Nested Hashes with Symbol Arrays (%i)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "options = { style: :fillet, keys: %i[r h d], inner: { depth: 5 } }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    const hash = stmt.kind.assignment.value.kind.hash_literal;
    try testing.expectEqual(@as(usize, 3), hash.len);

    // Entry 1: style: :fillet
    try testing.expectEqualStrings("style", hash[0].key.kind.symbol);
    try testing.expectEqualStrings("fillet", hash[0].value.kind.symbol);

    // Entry 2: keys: %i[r h d]
    try testing.expectEqualStrings("keys", hash[1].key.kind.symbol);
    const sym_array = hash[1].value.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), sym_array.len);
    try testing.expectEqualStrings("r", sym_array[0].kind.symbol);

    // Entry 3: inner: { depth: 5 }
    try testing.expectEqualStrings("inner", hash[2].key.kind.symbol);
    const nested_hash = hash[2].value.kind.hash_literal;
    try testing.expectEqualStrings("depth", nested_hash[0].key.kind.symbol);
    try testing.expectEqual(@as(f64, 5.0), nested_hash[0].value.kind.number);
}

test "KupCAD Parser: Multiple Destructuring Assignment with Splats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "a, *middle, z = [1, 2, 3, 4, 5]";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.multiple_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const lhs = stmt.kind.multiple_assignment.lhs;
    try testing.expectEqual(@as(usize, 3), lhs.len);

    try testing.expectEqualStrings("a", lhs[0].name);
    try testing.expectEqual(@as(?ast.ArgModifier, null), lhs[0].modifier);

    try testing.expectEqualStrings("middle", lhs[1].name);
    try testing.expectEqual(ast.ArgModifier.splat, lhs[1].modifier.?);

    try testing.expectEqualStrings("z", lhs[2].name);
    try testing.expectEqual(@as(?ast.ArgModifier, null), lhs[2].modifier);
}

test "KupCAD Parser: Hexadecimal, Scientific, and Negative Math Operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = -0x1F + .5 * 1.5e2 - 0b10";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    const math_node = stmt.kind.assignment.value;

    // Root is subtraction `- 0b10`
    try testing.expectEqual(ast.BinaryOp.subtract, math_node.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 2.0), math_node.kind.binary_op.right.kind.number); // 0b10 = 2

    // Left is `-0x1F + (.5 * 1.5e2)`
    const add_node = math_node.kind.binary_op.left;
    try testing.expectEqual(ast.BinaryOp.add, add_node.kind.binary_op.op);

    // Negated Hex: -0x1F (-31)
    const neg_hex = add_node.kind.binary_op.left;
    try testing.expectEqual(ast.UnaryOp.negate, neg_hex.kind.unary_op.op);
    try testing.expectEqual(@as(f64, 31.0), neg_hex.kind.unary_op.operand.kind.number);

    // Multiplication: .5 * 150.0 = 75.0
    const mult_node = add_node.kind.binary_op.right;
    try testing.expectEqual(ast.BinaryOp.multiply, mult_node.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 0.5), mult_node.kind.binary_op.left.kind.number);
    try testing.expectEqual(@as(f64, 150.0), mult_node.kind.binary_op.right.kind.number);
}

test "KupCAD Parser: Class Inheritance with Scope Resolution and Class Methods" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\class CAD::Fastener::Bolt < Hardware::Base
        \\  def self.m3(length: 10)
        \\    new(diameter: 3, length: length)
        \\  end
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const class_stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.class_stmt, @as(std.meta.Tag(ast.NodeKind), class_stmt.kind));

    // Name: CAD::Fastener::Bolt
    const name_ns = class_stmt.kind.class_stmt.name.kind.namespace_access.path;
    try testing.expectEqual(@as(usize, 3), name_ns.len);
    try testing.expectEqualStrings("CAD", name_ns[0]);
    try testing.expectEqualStrings("Fastener", name_ns[1]);
    try testing.expectEqualStrings("Bolt", name_ns[2]);

    // Super: Hardware::Base
    const super_ns = class_stmt.kind.class_stmt.super_class.?.kind.namespace_access.path;
    try testing.expectEqual(@as(usize, 2), super_ns.len);
    try testing.expectEqualStrings("Hardware", super_ns[0]);
    try testing.expectEqualStrings("Base", super_ns[1]);

    // Class Method: def self.m3
    const def_node = class_stmt.kind.class_stmt.body.kind.block.stmts[0];
    try testing.expectEqual(true, def_node.kind.def_stmt.is_class_method);
    try testing.expectEqualStrings("m3", def_node.kind.def_stmt.name);
    try testing.expectEqualStrings("length", def_node.kind.def_stmt.params[0].name);
}

test "KupCAD Parser: Top-Level Scope Resolution with Chained Calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "part = ::Hardware::Fastener::Screw.build(length: 20)";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    const call_node = stmt.kind.assignment.value;
    try testing.expectEqualStrings("build", call_node.kind.method_call.method_name);

    const ns_access = call_node.kind.method_call.receiver.?;
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), ns_access.kind));
    const path = ns_access.kind.namespace_access.path;
    try testing.expectEqual(@as(usize, 3), path.len);
    try testing.expectEqualStrings("Hardware", path[0]);
    try testing.expectEqualStrings("Fastener", path[1]);
    try testing.expectEqualStrings("Screw", path[2]);
}

test "KupCAD Parser: Bitwise and Logical Shorthand Compound Assignments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\mask &= 0xFF
        \\flags |= 0b100
        \\key ^= 0x01
        \\buf <<= 8
        \\val ||= default_val
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // mask &= 0xFF
    const s1 = try parser.parseStatement();
    try testing.expectEqualStrings("mask", s1.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.bitwise_and, s1.kind.assignment.op.?);

    // flags |= 0b100
    const s2 = try parser.parseStatement();
    try testing.expectEqualStrings("flags", s2.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.bitwise_or, s2.kind.assignment.op.?);

    // key ^= 0x01
    const s3 = try parser.parseStatement();
    try testing.expectEqualStrings("key", s3.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.bitwise_xor, s3.kind.assignment.op.?);

    // buf <<= 8
    const s4 = try parser.parseStatement();
    try testing.expectEqualStrings("buf", s4.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.shift_left, s4.kind.assignment.op.?);

    // val ||= default_val
    const s5 = try parser.parseStatement();
    try testing.expectEqualStrings("val", s5.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.logical_or, s5.kind.assignment.op.?);
}

test "KupCAD Parser: Keyword Logical Operators (and, or, not) Precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "valid and ready or not disabled";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const expr = try parser.parseExpression(.none);
    // Logical OR has lower precedence than AND, so OR is root
    try testing.expectEqual(ast.BinaryOp.logical_or, expr.kind.binary_op.op);

    // Right of OR is `not disabled`
    const not_node = expr.kind.binary_op.right;
    try testing.expectEqual(ast.UnaryOp.not, not_node.kind.unary_op.op);
    try testing.expectEqualStrings("disabled", not_node.kind.unary_op.operand.kind.identifier);

    // Left of OR is `valid and ready`
    const and_node = expr.kind.binary_op.left;
    try testing.expectEqual(ast.BinaryOp.logical_and, and_node.kind.binary_op.op);
    try testing.expectEqualStrings("valid", and_node.kind.binary_op.left.kind.identifier);
    try testing.expectEqualStrings("ready", and_node.kind.binary_op.right.kind.identifier);
}

test "KupCAD Parser: Control Flow Statements with Payloads and Modifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\break 42 if finished?
        \\return x, y unless error?
        \\next val until done?
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // break 42 if finished?
    const s1 = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), s1.kind));
    try testing.expectEqualStrings("finished?", s1.kind.if_stmt.condition.kind.identifier);
    const break_node = s1.kind.if_stmt.then_branch.kind.block.stmts[0];
    try testing.expectEqual(@as(f64, 42.0), break_node.kind.break_stmt.?.kind.number);

    // return x, y unless error?
    const s2 = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), s2.kind));
    try testing.expectEqual(true, s2.kind.if_stmt.is_unless);
    const ret_node = s2.kind.if_stmt.then_branch.kind.block.stmts[0];
    const ret_arr = ret_node.kind.return_stmt.?.kind.array_literal;
    try testing.expectEqual(@as(usize, 2), ret_arr.len);

    // next val until done?
    const s3 = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), s3.kind));
    try testing.expectEqual(true, s3.kind.while_stmt.is_until);
    const next_node = s3.kind.while_stmt.body.kind.block.stmts[0];
    try testing.expectEqualStrings("val", next_node.kind.next_stmt.?.kind.identifier);
}

test "KupCAD Parser: Multi-Interpolation String with Expressions and Method Calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "\"Part: #{part.name} at X:#{part.x + 10}, Y:#{part.y}\"";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const expr = try parser.parseExpression(.none);

    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), expr.kind));

    const parts = expr.kind.interpolated_string;
    try testing.expectEqual(@as(usize, 7), parts.len);

    try testing.expectEqualStrings("Part: ", parts[0].kind.string);
    try testing.expectEqualStrings("name", parts[1].kind.method_call.method_name);
    try testing.expectEqualStrings(" at X:", parts[2].kind.string);
    try testing.expectEqual(ast.BinaryOp.add, parts[3].kind.binary_op.op);
    try testing.expectEqualStrings(", Y:", parts[4].kind.string);
    try testing.expectEqualStrings("y", parts[5].kind.method_call.method_name);
    try testing.expectEqualStrings("", parts[6].kind.string);
}

test "KupCAD Parser: Module Namespaces with Doc Comments and Class Constructors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\module Enclosures
        \\  # @param wall_thickness [Length] Thickness of enclosure walls
        \\  class Box < Base
        \\    def initialize(w = 100)
        \\      @w = w
        \\    end
        \\  end
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const mod_node = try parser.parseStatement();
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).module_stmt, std.meta.activeTag(mod_node.kind));
    try testing.expectEqualStrings("Enclosures", mod_node.kind.module_stmt.name);

    const block_stmts = mod_node.kind.module_stmt.body.kind.block.stmts;
    try testing.expectEqual(@as(usize, 2), block_stmts.len);

    // Statement 0: Doc Comment
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).param_doc, std.meta.activeTag(block_stmts[0].kind));
    const doc = block_stmts[0].kind.param_doc;
    try testing.expectEqualStrings("param", doc.tag_name);
    try testing.expectEqualStrings("wall_thickness", doc.target_name.?);
    try testing.expectEqualStrings("Length", doc.type_name.?);
    try testing.expectEqualStrings("Thickness of enclosure walls", doc.description);

    // Statement 1: Class Statement
    const class_stmt = block_stmts[1];
    try testing.expectEqualStrings("Box", class_stmt.kind.class_stmt.name.kind.identifier);
    try testing.expectEqualStrings("Base", class_stmt.kind.class_stmt.super_class.?.kind.identifier);

    const init_def = class_stmt.kind.class_stmt.body.kind.block.stmts[0];
    try testing.expectEqualStrings("initialize", init_def.kind.def_stmt.name);
    try testing.expectEqualStrings("w", init_def.kind.def_stmt.params[0].name);
    try testing.expectEqual(@as(f64, 100.0), init_def.kind.def_stmt.params[0].default_value.?.kind.number);
}

test "KupCAD Parser: Command-Syntax Calls with Trailing Statement Modifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "cube x: 10, y: 20 unless draft_mode?";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.if_stmt.is_unless);
    try testing.expectEqualStrings("draft_mode?", stmt.kind.if_stmt.condition.kind.identifier);

    const inner_stmt = stmt.kind.if_stmt.then_branch.kind.block.stmts[0];
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), inner_stmt.kind));
    try testing.expectEqualStrings("cube", inner_stmt.kind.method_call.method_name);
    try testing.expectEqual(@as(usize, 2), inner_stmt.kind.method_call.args.len);
}

test "KupCAD Parser: Safe Navigation inside Ternary Conditions and Global Scope Resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "target = part&.is_valid? ? part.build() : ::CAD::Default.build()";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqualStrings("target", stmt.kind.assignment.name);

    const ternary = stmt.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), ternary.kind));

    // Condition: part&.is_valid?
    const cond = ternary.kind.ternary_op.condition;
    try testing.expectEqualStrings("is_valid?", cond.kind.method_call.method_name);
    try testing.expectEqual(true, cond.kind.method_call.is_safe);

    // Else branch: ::CAD::Default.build()
    const else_branch = ternary.kind.ternary_op.else_branch;
    try testing.expectEqualStrings("build", else_branch.kind.method_call.method_name);
    const receiver_ns = else_branch.kind.method_call.receiver.?;
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), receiver_ns.kind));
    try testing.expectEqualStrings("CAD", receiver_ns.kind.namespace_access.path[0]);
    try testing.expectEqualStrings("Default", receiver_ns.kind.namespace_access.path[1]);
}

test "KupCAD Parser: Class Method Definitions with Rescue Blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def self.create(opts = {})
        \\  build(opts)
        \\rescue StandardError => err
        \\  handle_error(err)
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const def_node = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.def_stmt, @as(std.meta.Tag(ast.NodeKind), def_node.kind));
    try testing.expectEqual(true, def_node.kind.def_stmt.is_class_method);
    try testing.expectEqualStrings("create", def_node.kind.def_stmt.name);

    // Def body wrapped in begin_stmt due to rescue clause
    const begin_node = def_node.kind.def_stmt.body;
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), begin_node.kind));

    const rescue = begin_node.kind.begin_stmt.rescues[0];
    try testing.expectEqualStrings("StandardError", rescue.errors[0]);
    try testing.expectEqualStrings("err", rescue.variable.?);
}

test "KupCAD Parser: Multi-line Array Destructuring in Method Arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "mesh.transform([x, y, z], [10, 20, 30])";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqualStrings("transform", stmt.kind.method_call.method_name);

    const args = stmt.kind.method_call.args;
    try testing.expectEqual(@as(usize, 2), args.len);

    const arr1 = args[0].value.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), arr1.len);
    try testing.expectEqualStrings("x", arr1[0].kind.identifier);

    const arr2 = args[1].value.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), arr2.len);
    try testing.expectEqual(@as(f64, 10.0), arr2[0].kind.number);
}

test "KupCAD Parser: Destructuring with Nested Tuple Patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Multi-assignment with parenthesis tuple grouping: `a, (b, c) = data`
    // (Note: we simulate this with standard array mapping in AST)
    const source = "points.each do |(x, y), index|\nend";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    const params = stmt.kind.method_call.block.?.kind.block.params;
    try testing.expectEqual(@as(usize, 2), params.len);

    const tuple_param = params[0].kind.array_literal;
    try testing.expectEqual(@as(usize, 2), tuple_param.len);
    try testing.expectEqualStrings("x", tuple_param[0].kind.identifier);
    try testing.expectEqualStrings("y", tuple_param[1].kind.identifier);
    try testing.expectEqualStrings("index", params[1].kind.identifier);
}

test "KupCAD Parser: Complex Nested Modifier Precedence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // The trailing `unless` should bind to the assignment, not just `false`
    const source = "x = y ? true : false unless z == 1";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const root = try parser.parseStatement();

    // Root should be `if_stmt` (unless) wrapping the assignment
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), root.kind));
    try testing.expectEqual(true, root.kind.if_stmt.is_unless);

    const cond = root.kind.if_stmt.condition;
    try testing.expectEqual(ast.BinaryOp.equal, cond.kind.binary_op.op);
    try testing.expectEqualStrings("z", cond.kind.binary_op.left.kind.identifier);

    const assign = root.kind.if_stmt.then_branch.kind.block.stmts[0];
    try testing.expectEqualStrings("x", assign.kind.assignment.name);
    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), assign.kind.assignment.value.kind));
}

test "KupCAD Parser: Global Namespace Property Assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "::App::Config.debug_mode = true";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    try testing.expectEqualStrings("debug_mode", stmt.kind.property_assignment.property);
    try testing.expectEqual(true, stmt.kind.property_assignment.value.kind.boolean);

    const target_ns = stmt.kind.property_assignment.target;
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), target_ns.kind));
    try testing.expectEqual(@as(usize, 2), target_ns.kind.namespace_access.path.len);
    try testing.expectEqualStrings("App", target_ns.kind.namespace_access.path[0]);
    try testing.expectEqualStrings("Config", target_ns.kind.namespace_access.path[1]);
}

test "KupCAD Parser: Multiple Trailing Safe Navigation Calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "part&.cut(hole)&.translate(x: 10)&.chamfer()";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    // Top-most call is `chamfer`
    try testing.expectEqualStrings("chamfer", stmt.kind.method_call.method_name);
    try testing.expectEqual(true, stmt.kind.method_call.is_safe);

    // Receiver of chamfer is `translate`
    const translate_call = stmt.kind.method_call.receiver.?;
    try testing.expectEqualStrings("translate", translate_call.kind.method_call.method_name);
    try testing.expectEqual(true, translate_call.kind.method_call.is_safe);

    // Receiver of translate is `cut`
    const cut_call = translate_call.kind.method_call.receiver.?;
    try testing.expectEqualStrings("cut", cut_call.kind.method_call.method_name);
    try testing.expectEqual(true, cut_call.kind.method_call.is_safe);

    // Receiver of cut is `part`
    const part_ident = cut_call.kind.method_call.receiver.?;
    try testing.expectEqualStrings("part", part_ident.kind.identifier);
}

test "KupCAD Parser: Multi-Line Nested Array and Range Expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\points = [
        \\  [10, 20],
        \\  0...5,
        \\  [x, y, z]
        \\]
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    const arr = stmt.kind.assignment.value.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), arr.len);

    // First item is nested array
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), arr[0].kind));
    try testing.expectEqual(@as(f64, 10.0), arr[0].kind.array_literal[0].kind.number);

    // Second item is exclusive range
    try testing.expectEqual(ast.NodeKind.range, @as(std.meta.Tag(ast.NodeKind), arr[1].kind));
    try testing.expectEqual(true, arr[1].kind.range.is_exclusive);

    // Third item is identifier array
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), arr[2].kind));
    try testing.expectEqualStrings("x", arr[2].kind.array_literal[0].kind.identifier);
}

test "KupCAD Parser: Chained Comparisons (Ruby-style Equality)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "a == b and c != d or e >= f";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    // Root is OR
    try testing.expectEqual(ast.BinaryOp.logical_or, stmt.kind.binary_op.op);

    // Right of OR is e >= f
    const r_expr = stmt.kind.binary_op.right;
    try testing.expectEqual(ast.BinaryOp.greater_equal, r_expr.kind.binary_op.op);
    try testing.expectEqualStrings("e", r_expr.kind.binary_op.left.kind.identifier);
    try testing.expectEqualStrings("f", r_expr.kind.binary_op.right.kind.identifier);

    // Left of OR is a == b and c != d
    const l_expr = stmt.kind.binary_op.left;
    try testing.expectEqual(ast.BinaryOp.logical_and, l_expr.kind.binary_op.op);

    try testing.expectEqual(ast.BinaryOp.equal, l_expr.kind.binary_op.left.kind.binary_op.op);
    try testing.expectEqual(ast.BinaryOp.not_equal, l_expr.kind.binary_op.right.kind.binary_op.op);
}

test "KupCAD Parser: Return and Next with Multi-value Tuples" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def process
        \\  next 1, 2, 3 if skip?
        \\  return true, "done"
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const def_node = try parser.parseStatement();

    const stmts = def_node.kind.def_stmt.body.kind.block.stmts;

    // next 1, 2, 3 if skip? (If modifier wrapper)
    const if_node = stmts[0];
    try testing.expectEqualStrings("skip?", if_node.kind.if_stmt.condition.kind.identifier);
    const next_node = if_node.kind.if_stmt.then_branch.kind.block.stmts[0];

    // Multi-return/next gets parsed as an array_literal of values
    const next_vals = next_node.kind.next_stmt.?.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), next_vals.len);
    try testing.expectEqual(@as(f64, 2.0), next_vals[1].kind.number);

    // return true, "done"
    const ret_node = stmts[1];
    const ret_vals = ret_node.kind.return_stmt.?.kind.array_literal;
    try testing.expectEqual(@as(usize, 2), ret_vals.len);
    try testing.expectEqual(true, ret_vals[0].kind.boolean);
    try testing.expectEqualStrings("done", ret_vals[1].kind.string);
}

test "KupCAD Parser: Property and Index Assignment Interactions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Validates that method chains can be assigned to dynamically
    const source = "config.sections[0].name = \"Top\"";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    // Root should be Property Assignment (`.name = "Top"`)
    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("name", stmt.kind.property_assignment.property);
    try testing.expectEqualStrings("Top", stmt.kind.property_assignment.value.kind.string);

    // Target of property assignment should be Index Access (`config.sections[0]`)
    const target = stmt.kind.property_assignment.target;
    try testing.expectEqual(ast.NodeKind.index_access, @as(std.meta.Tag(ast.NodeKind), target.kind));
    try testing.expectEqual(@as(f64, 0.0), target.kind.index_access.index.kind.number);

    // Target of index access should be Method Call (`config.sections`)
    const access_target = target.kind.index_access.target;
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), access_target.kind));
    try testing.expectEqualStrings("sections", access_target.kind.method_call.method_name);
    try testing.expectEqualStrings("config", access_target.kind.method_call.receiver.?.kind.identifier);
}

test "KupCAD Parser: Multiple Sequential Rescue Clauses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\begin
        \\  calc()
        \\rescue MathError, DivByZero => e
        \\  1
        \\rescue => fallback
        \\  2
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), node.kind));

    const rescues = node.kind.begin_stmt.rescues;
    try testing.expectEqual(@as(usize, 2), rescues.len);

    // First rescue
    try testing.expectEqual(@as(usize, 2), rescues[0].errors.len);
    try testing.expectEqualStrings("MathError", rescues[0].errors[0]);
    try testing.expectEqualStrings("DivByZero", rescues[0].errors[1]);
    try testing.expectEqualStrings("e", rescues[0].variable.?);
    try testing.expectEqual(@as(f64, 1.0), rescues[0].body.kind.block.stmts[0].kind.number);

    // Second rescue (catch-all)
    try testing.expectEqual(@as(usize, 0), rescues[1].errors.len);
    try testing.expectEqualStrings("fallback", rescues[1].variable.?);
    try testing.expectEqual(@as(f64, 2.0), rescues[1].body.kind.block.stmts[0].kind.number);
}

test "KupCAD Parser: Trailing Modifiers on Compound Begin/End Blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\begin
        \\  step()
        \\end until done?
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    // The statement modifier should wrap the begin block
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.while_stmt.is_until);
    try testing.expectEqualStrings("done?", stmt.kind.while_stmt.condition.kind.identifier);

    // The body of the until statement should be the Begin Block
    const wrapped_begin = stmt.kind.while_stmt.body.kind.block.stmts[0];
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), wrapped_begin.kind));
    try testing.expectEqualStrings("step", wrapped_begin.kind.begin_stmt.body.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Global and Instance Variable Assignments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\@width = 10
        \\$offset = @width * 2
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // @width = 10
    const s1 = try parser.parseStatement();
    try testing.expectEqualStrings("@width", s1.kind.assignment.name);

    // $offset = @width * 2
    const s2 = try parser.parseStatement();
    try testing.expectEqualStrings("$offset", s2.kind.assignment.name);
    try testing.expectEqualStrings("@width", s2.kind.assignment.value.kind.binary_op.left.kind.identifier);
}

test "KupCAD Parser: Empty Literals and Blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\arr = []
        \\obj = {}
        \\run do
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const s1 = try parser.parseStatement();
    try testing.expectEqual(@as(usize, 0), s1.kind.assignment.value.kind.array_literal.len);

    const s2 = try parser.parseStatement();
    try testing.expectEqual(@as(usize, 0), s2.kind.assignment.value.kind.hash_literal.len);

    const s3 = try parser.parseStatement();
    try testing.expectEqualStrings("run", s3.kind.method_call.method_name);
    try testing.expectEqual(@as(usize, 0), s3.kind.method_call.block.?.kind.block.stmts.len);
}

test "KupCAD Parser: Method Calls on Array and Hash Literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\arr_max = [1, 2, 3].max
        \\hash_keys = { a: 1 }.keys()
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // arr_max = [1, 2, 3].max
    const stmt1 = try parser.parseStatement();
    try testing.expectEqualStrings("arr_max", stmt1.kind.assignment.name);

    const call1 = stmt1.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), call1.kind));
    try testing.expectEqualStrings("max", call1.kind.method_call.method_name);

    const receiver1 = call1.kind.method_call.receiver.?;
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), receiver1.kind));
    try testing.expectEqual(@as(usize, 3), receiver1.kind.array_literal.len);
    try testing.expectEqual(@as(f64, 1.0), receiver1.kind.array_literal[0].kind.number);

    // hash_keys = { a: 1 }.keys()
    const stmt2 = try parser.parseStatement();
    try testing.expectEqualStrings("hash_keys", stmt2.kind.assignment.name);

    const call2 = stmt2.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), call2.kind));
    try testing.expectEqualStrings("keys", call2.kind.method_call.method_name);

    const receiver2 = call2.kind.method_call.receiver.?;
    try testing.expectEqual(ast.NodeKind.hash_literal, @as(std.meta.Tag(ast.NodeKind), receiver2.kind));
    try testing.expectEqual(@as(usize, 1), receiver2.kind.hash_literal.len);
    try testing.expectEqualStrings("a", receiver2.kind.hash_literal[0].key.kind.symbol);
}

test "KupCAD Parser: Diagnostics Line and Column Tracking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def build()
        \\  x = 10 + }
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    _ = try parser.parseStatement();

    try testing.expectEqual(@as(usize, 1), parser.diagnostics.list.items.len);
    const diag = parser.diagnostics.list.items[0];

    // Validate error message
    try testing.expectEqualStrings("Invalid expression starting with '}'", diag.message);

    // Validate exact coordinates for LSP squigglies
    // Line 2: `  x = 10 + }`
    // Col 12 is exactly the closing brace `}`
    try testing.expectEqual(@as(u32, 2), diag.loc.line);
    try testing.expectEqual(@as(u32, 12), diag.loc.col);
}

test "KupCAD Parser: Empty Class and Module Declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\module Math
        \\end
        \\class Vector
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const mod_stmt = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.module_stmt, @as(std.meta.Tag(ast.NodeKind), mod_stmt.kind));
    try testing.expectEqualStrings("Math", mod_stmt.kind.module_stmt.name);
    try testing.expectEqual(@as(usize, 0), mod_stmt.kind.module_stmt.body.kind.block.stmts.len);

    const class_stmt = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.class_stmt, @as(std.meta.Tag(ast.NodeKind), class_stmt.kind));
    try testing.expectEqualStrings("Vector", class_stmt.kind.class_stmt.name.kind.identifier);
    try testing.expectEqual(@as(usize, 0), class_stmt.kind.class_stmt.body.kind.block.stmts.len);
}

test "KupCAD Parser: Block Passing in Property Assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A block appended to a property assignment right hand side
    const source =
        \\model.callback = ->(event) do
        \\  log(event)
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("callback", stmt.kind.property_assignment.property);

    const lambda = stmt.kind.property_assignment.value;
    try testing.expectEqual(ast.NodeKind.lambda_expr, @as(std.meta.Tag(ast.NodeKind), lambda.kind));
    try testing.expectEqualStrings("event", lambda.kind.lambda_expr.params[0].name);

    const call_node = lambda.kind.lambda_expr.body.kind.block.stmts[0];
    try testing.expectEqualStrings("log", call_node.kind.method_call.method_name);
}

test "KupCAD Parser: Naked Return Statement (No Arguments)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\def validate
        \\  return if !ready
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    const body_stmt = stmt.kind.def_stmt.body.kind.block.stmts[0];
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), body_stmt.kind));

    const ret_stmt = body_stmt.kind.if_stmt.then_branch.kind.block.stmts[0];
    try testing.expectEqual(ast.NodeKind.return_stmt, @as(std.meta.Tag(ast.NodeKind), ret_stmt.kind));
    // When `return` has no arguments, the wrapped Node is null
    try testing.expectEqual(@as(?*ast.Node, null), ret_stmt.kind.return_stmt);
}

test "KupCAD Parser: Inline Array/Hash Creation within Command Arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "extrude [0, 0, 10], opts: { twist: 360 }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("extrude", stmt.kind.method_call.method_name);

    const args = stmt.kind.method_call.args;
    try testing.expectEqual(@as(usize, 2), args.len);

    // Arg 1 is Array
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), args[0].value.kind));
    try testing.expectEqual(@as(usize, 3), args[0].value.kind.array_literal.len);

    // Arg 2 is Hash
    try testing.expectEqualStrings("opts", args[1].name);
    try testing.expectEqual(ast.NodeKind.hash_literal, @as(std.meta.Tag(ast.NodeKind), args[1].value.kind));
    try testing.expectEqualStrings("twist", args[1].value.kind.hash_literal[0].key.kind.symbol);
}

test "KupCAD Parser: Multiple Comma-Separated Conditions in 'When' Clauses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\case type
        \\when :hex, :square, :round
        \\  extrude(5)
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    const branches = stmt.kind.case_stmt.when_branches;
    try testing.expectEqual(@as(usize, 1), branches.len);

    const conditions = branches[0].conditions;
    try testing.expectEqual(@as(usize, 3), conditions.len);
    try testing.expectEqualStrings("hex", conditions[0].kind.symbol);
    try testing.expectEqualStrings("square", conditions[1].kind.symbol);
    try testing.expectEqualStrings("round", conditions[2].kind.symbol);
}

test "KupCAD Parser: Parenthesis-less Method Definitions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\def build width, height: 10
        \\  cube()
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    const def_node = stmt.kind.def_stmt;
    try testing.expectEqualStrings("build", def_node.name);
    try testing.expectEqual(@as(usize, 2), def_node.params.len);
    try testing.expectEqualStrings("width", def_node.params[0].name);
    try testing.expectEqualStrings("height", def_node.params[1].name);
    try testing.expectEqual(@as(f64, 10.0), def_node.params[1].default_value.?.kind.number);
}

test "KupCAD Parser: Multiline Command Arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\translate x: 10,
        \\          y: 20 do
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    const call = stmt.kind.method_call;
    try testing.expectEqualStrings("translate", call.method_name);
    try testing.expectEqual(@as(usize, 2), call.args.len);
    try testing.expectEqualStrings("y", call.args[1].name);
}

test "KupCAD Parser: Error Recovery (synchronize)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Two distinct statements with syntax errors.
    const source =
        \\x = 10 + }
        \\y = 20 * ]
        \\z = 30
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // The program block will return successfully without throwing an error!
    const result = try parser.parseProgram();

    // We expect exactly 1 successful statement (z = 30)
    try testing.expectEqual(@as(usize, 1), result.kind.block.stmts.len);
    try testing.expectEqualStrings("z", result.kind.block.stmts[0].kind.assignment.name);

    // And diagnostics should contain BOTH errors from the skipped lines!
    try testing.expectEqual(@as(usize, 2), parser.diagnostics.list.items.len);
}

test "KupCAD Parser: Nested String Interpolation AST" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "\"Outer #{ \"Inner #{1 + 2}\" } end\"";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseExpression(.none);

    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    const outer_parts = stmt.kind.interpolated_string;

    try testing.expectEqualStrings("Outer ", outer_parts[0].kind.string);

    const inner_node = outer_parts[1];
    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), inner_node.kind));
    const inner_parts = inner_node.kind.interpolated_string;

    try testing.expectEqualStrings("Inner ", inner_parts[0].kind.string);
    try testing.expectEqual(ast.BinaryOp.add, inner_parts[1].kind.binary_op.op);
    try testing.expectEqualStrings("", inner_parts[2].kind.string);

    try testing.expectEqualStrings(" end", outer_parts[2].kind.string);
}

test "KupCAD Parser: Begin Block as Expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\val = begin
        \\  calc()
        \\rescue
        \\  0
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    try testing.expectEqualStrings("val", stmt.kind.assignment.name);

    const begin_expr = stmt.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), begin_expr.kind));
    try testing.expectEqual(@as(usize, 1), begin_expr.kind.begin_stmt.rescues.len);
}

test "KupCAD Parser: Single-line Case When with 'then'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\case type
        \\when 1 then cube()
        \\when 2 then sphere()
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    const branches = stmt.kind.case_stmt.when_branches;
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expectEqualStrings("cube", branches[0].body.kind.block.stmts[0].kind.method_call.method_name);
    try testing.expectEqualStrings("sphere", branches[1].body.kind.block.stmts[0].kind.method_call.method_name);
}

test "KupCAD Parser: Top-Level Method Call with Parens and Block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\grid(2, 2) do |x, y|
        \\  cube()
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("grid", stmt.kind.method_call.method_name);
    try testing.expectEqual(@as(usize, 2), stmt.kind.method_call.args.len);

    // Ensure the block was NOT discarded!
    const block = stmt.kind.method_call.block.?;
    try testing.expectEqual(@as(usize, 2), block.kind.block.params.len);
    try testing.expectEqualStrings("x", block.kind.block.params[0].kind.identifier);
}

test "KupCAD Parser: Multi-Assignment with Raw Comma Values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Ensures `x, y = 1, 2` wraps the RHS in an implicit array literal correctly
    const source = "x, y = 10, 20";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.multiple_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const rhs_array = stmt.kind.multiple_assignment.value.kind.array_literal;
    try testing.expectEqual(@as(usize, 2), rhs_array.len);
    try testing.expectEqual(@as(f64, 10.0), rhs_array[0].kind.number);
    try testing.expectEqual(@as(f64, 20.0), rhs_array[1].kind.number);
}

test "KupCAD Parser: Implicit RHS Array on Single Assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\coords = 10, 20, 30
        \\points[0] = 5, 5
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // Verify `coords = 10, 20, 30`
    const stmt1 = try parser.parseStatement();
    const rhs_arr1 = stmt1.kind.assignment.value.kind.array_literal;
    try testing.expectEqual(@as(usize, 3), rhs_arr1.len);
    try testing.expectEqual(@as(f64, 30.0), rhs_arr1[2].kind.number);

    // Verify `points[0] = 5, 5`
    const stmt2 = try parser.parseStatement();
    const rhs_arr2 = stmt2.kind.index_assignment.value.kind.array_literal;
    try testing.expectEqual(@as(usize, 2), rhs_arr2.len);
    try testing.expectEqual(@as(f64, 5.0), rhs_arr2[1].kind.number);
}

test "KupCAD Parser: Multi-Dimensional Array Indexing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = matrix[x, y]";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    const index_node = stmt.kind.assignment.value;

    try testing.expectEqual(ast.NodeKind.index_access, @as(std.meta.Tag(ast.NodeKind), index_node.kind));

    // The inner index should automatically be grouped into an array literal
    const index_args = index_node.kind.index_access.index.kind.array_literal;
    try testing.expectEqual(@as(usize, 2), index_args.len);
    try testing.expectEqualStrings("x", index_args[0].kind.identifier);
    try testing.expectEqualStrings("y", index_args[1].kind.identifier);
}

test "KupCAD Parser: Empty Parentheses evaluate to Nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "call() do\n ()\nend";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    const block_stmt = stmt.kind.method_call.block.?.kind.block.stmts[0];

    // Ensure `()` was gracefully converted to a `.nil` semantic node
    try testing.expectEqual(ast.NodeKind.nil, @as(std.meta.Tag(ast.NodeKind), block_stmt.kind));
}

test "KupCAD Parser: Chained and Compound Assignment Right-Associativity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Chained assignment: a = b = c = 10
    const source1 = "a = b = c = 10";
    var lexer1 = Lexer.init(source1, 0);
    var parser1 = Parser.init(&lexer1, arena.allocator());
    const stmt1 = try parser1.parseStatement();

    try testing.expectEqualStrings("a", stmt1.kind.assignment.name);
    const assign_b = stmt1.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), assign_b.kind));
    try testing.expectEqualStrings("b", assign_b.kind.assignment.name);

    const assign_c = assign_b.kind.assignment.value;
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), assign_c.kind));
    try testing.expectEqualStrings("c", assign_c.kind.assignment.name);
    try testing.expectEqual(@as(f64, 10.0), assign_c.kind.assignment.value.kind.number);

    // Chained compound assignment: x += y += 5
    const source2 = "x += y += 5";
    var lexer2 = Lexer.init(source2, 0);
    var parser2 = Parser.init(&lexer2, arena.allocator());
    const stmt2 = try parser2.parseStatement();

    try testing.expectEqualStrings("x", stmt2.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.add, stmt2.kind.assignment.op.?);
    const assign_y = stmt2.kind.assignment.value;
    try testing.expectEqual(ast.BinaryOp.add, assign_y.kind.assignment.op.?);
    try testing.expectEqualStrings("y", assign_y.kind.assignment.name);
    try testing.expectEqual(@as(f64, 5.0), assign_y.kind.assignment.value.kind.number);
}

test "KupCAD Parser: Nested Ternary Right-Associativity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "a ? b : c ? d : e";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const expr = try parser.parseExpression(.none);

    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), expr.kind));
    try testing.expectEqualStrings("a", expr.kind.ternary_op.condition.kind.identifier);
    try testing.expectEqualStrings("b", expr.kind.ternary_op.then_branch.kind.identifier);

    const else_ternary = expr.kind.ternary_op.else_branch;
    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), else_ternary.kind));
    try testing.expectEqualStrings("c", else_ternary.kind.ternary_op.condition.kind.identifier);
    try testing.expectEqualStrings("d", else_ternary.kind.ternary_op.then_branch.kind.identifier);
    try testing.expectEqualStrings("e", else_ternary.kind.ternary_op.else_branch.kind.identifier);
}

test "KupCAD Parser: Multiple Unary Prefix Right-Associativity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "!!true";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const expr = try parser.parseExpression(.none);

    try testing.expectEqual(ast.UnaryOp.not, expr.kind.unary_op.op);
    const inner_not = expr.kind.unary_op.operand;
    try testing.expectEqual(ast.UnaryOp.not, inner_not.kind.unary_op.op);
    try testing.expectEqual(true, inner_not.kind.unary_op.operand.kind.boolean);
}

test "KupCAD Parser: Ruby 3.1 Shorthand Hash Syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "opts = { width:, height: }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt = try parser.parseStatement();

    const hash = stmt.kind.assignment.value.kind.hash_literal;
    try testing.expectEqual(@as(usize, 2), hash.len);

    try testing.expectEqualStrings("width", hash[0].key.kind.symbol);
    try testing.expectEqualStrings("width", hash[0].value.kind.identifier);

    try testing.expectEqualStrings("height", hash[1].key.kind.symbol);
    try testing.expectEqualStrings("height", hash[1].value.kind.identifier);
}

test "KupCAD Parser: Multi-line Indented Docstring Tag Node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\# @deprecated Use {#my_new_method} instead of this method because
        \\#   it uses a library that is no longer supported.
        \\def mymethod
        \\end
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // Statement 0: The multi-line docstring annotation AST node
    const doc_stmt1 = try parser.parseStatement();
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).param_doc, std.meta.activeTag(doc_stmt1.kind));
    const doc = doc_stmt1.kind.param_doc;

    try testing.expectEqualStrings("deprecated", doc.tag_name);
    try testing.expectEqual(@as(?[]const u8, null), doc.target_name);
    try testing.expectEqual(@as(?[]const u8, null), doc.type_name);
    try testing.expectEqualStrings("Use {#my_new_method} instead of this method because\nit uses a library that is no longer supported.", doc.description);

    // Statement 1: The target function definition `def mymethod`
    const def_stmt = try parser.parseStatement();
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).def_stmt, std.meta.activeTag(def_stmt.kind));
    try testing.expectEqualStrings("mymethod", def_stmt.kind.def_stmt.name);
}

test "KupCAD Parser: AST Node offset and length calculation for LSP" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // String byte-indices mapped out for clarity:
    // 01234567890123456789012
    // val = 10 + 200
    const source = "val = 10 + 200";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    // 1. Check the Root Assignment Node (`val = 10 + 200`)
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).assignment, std.meta.activeTag(stmt.kind));
    try testing.expectEqual(@as(u32, 0), stmt.loc.offset);
    try testing.expectEqual(@as(u32, 14), stmt.loc.length); // Spans exactly characters 0 through 14

    // 2. Check the Binary Expression RHS (`10 + 200`)
    const bin_expr = stmt.kind.assignment.value;
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).binary_op, std.meta.activeTag(bin_expr.kind));
    try testing.expectEqual(@as(u32, 6), bin_expr.loc.offset); // Starts at '1'
    try testing.expectEqual(@as(u32, 8), bin_expr.loc.length); // Spans "10 + 200" (length 8)

    // 3. Check the Left Number Leaf (`10`)
    const left_num = bin_expr.kind.binary_op.left;
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).number, std.meta.activeTag(left_num.kind));
    try testing.expectEqual(@as(u32, 6), left_num.loc.offset);
    try testing.expectEqual(@as(u32, 2), left_num.loc.length);

    // 4. Check the Right Number Leaf (`200`)
    const right_num = bin_expr.kind.binary_op.right;
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).number, std.meta.activeTag(right_num.kind));
    try testing.expectEqual(@as(u32, 11), right_num.loc.offset); // Starts at '2'
    try testing.expectEqual(@as(u32, 3), right_num.loc.length); // Spans "200" (length 3)
}

test "KupCAD Parser: Compound Node Spans and Comment Side-Table Extraction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Let's mathematically map out the exact byte offsets:
    // "def calculate(a)\n"  --> Length 17 (Offsets 0 to 16)
    // "  # a comment\n"     --> Length 14 (Offsets 17 to 30) The '#' is at offset 19.
    // "  a * 2\n"           --> Length 8  (Offsets 31 to 38) The 'a' is at offset 33.
    // "end"                 --> Length 3  (Offsets 39 to 41)
    // Total File Length: 42 bytes.
    const source =
        "def calculate(a)\n" ++
        "  # a comment\n" ++
        "  a * 2\n" ++
        "end";

    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    // Verify the Root Node (def_stmt) covers the entire block perfectly.
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).def_stmt, std.meta.activeTag(stmt.kind));
    try testing.expectEqual(@as(u32, 0), stmt.loc.offset);
    try testing.expectEqual(@as(u32, 42), stmt.loc.length);

    // Verify the Inner Math Node (binary_op) didn't accidentally consume the \n
    const body_block = stmt.kind.def_stmt.body.kind.block.stmts;
    try testing.expectEqual(@as(usize, 1), body_block.len); // Comment should be ignored in AST

    const math_expr = body_block[0];
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).binary_op, std.meta.activeTag(math_expr.kind));
    try testing.expectEqual(@as(u32, 33), math_expr.loc.offset); // Exactly at the 'a'
    try testing.expectEqual(@as(u32, 5), math_expr.loc.length); // Spans "a * 2" (length 5)

    // Verify the Comment was captured in the side-table perfectly
    try testing.expectEqual(@as(usize, 1), parser.comments.items.len);
    const captured_comment = parser.comments.items[0];
    try testing.expectEqualStrings("# a comment", captured_comment.lexeme);
    try testing.expectEqual(@as(u32, 2), captured_comment.loc.line);
    try testing.expectEqual(@as(u32, 19), captured_comment.loc.offset);
}

test "KupCAD Parser: Standard Block While and Until Loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\while x < 10
        \\  x += 1
        \\end
        \\until y > 10
        \\  y -= 1
        \\end
    ;

    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // Check `while`
    const while_stmt = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), while_stmt.kind));
    try testing.expectEqual(false, while_stmt.kind.while_stmt.is_until);
    try testing.expectEqual(ast.BinaryOp.add, while_stmt.kind.while_stmt.body.kind.block.stmts[0].kind.assignment.op.?);

    // Check `until`
    const until_stmt = try parser.parseStatement();
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), until_stmt.kind));
    try testing.expectEqual(true, until_stmt.kind.while_stmt.is_until);
    try testing.expectEqual(ast.BinaryOp.subtract, until_stmt.kind.while_stmt.body.kind.block.stmts[0].kind.assignment.op.?);
}

test "KupCAD Parser: Index Compound Assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "arr[0] *= 5";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.index_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("arr", stmt.kind.index_assignment.target.kind.identifier);
    try testing.expectEqual(@as(f64, 0.0), stmt.kind.index_assignment.index.kind.number);
    try testing.expectEqual(ast.BinaryOp.multiply, stmt.kind.index_assignment.op.?);
    try testing.expectEqual(@as(f64, 5.0), stmt.kind.index_assignment.value.kind.number);
}

test "KupCAD Parser: Property Compound Assignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "obj.x += 10";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("obj", stmt.kind.property_assignment.target.kind.identifier);
    try testing.expectEqualStrings("x", stmt.kind.property_assignment.property);
    try testing.expectEqual(ast.BinaryOp.add, stmt.kind.property_assignment.op.?);
    try testing.expectEqual(@as(f64, 10.0), stmt.kind.property_assignment.value.kind.number);
}

test "KupCAD Parser: Strict Index Assignment Rejects Spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Because of the space, `arr [ 0 ]` parses as a method call `arr([0])`.
    // When it hits `*=`, `parseAssignmentExpr` strictly rejects assigning to a method call with args.
    const source = "arr [ 0 ] *= 5";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const result = parser.parseStatement();

    // Assert that the parser threw an error instead of returning an AST node
    try testing.expectError(error.InvalidExpression, result);

    // Assert that a diagnostic was generated for the language server
    try testing.expectEqual(@as(usize, 1), parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Invalid expression starting with '*='", parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Ignore trailing comments on binary operations and calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\part - part # Should trigger CSG self-subtraction warning
        \\cube() # Trailing comment on method call
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const p1 = try parser.parseStatement();
    try testing.expectEqual(ast.BinaryOp.subtract, p1.kind.binary_op.op);
    try testing.expectEqualStrings("part", p1.kind.binary_op.left.kind.identifier);
    try testing.expectEqualStrings("part", p1.kind.binary_op.right.kind.identifier);

    const p2 = try parser.parseStatement();
    try testing.expectEqualStrings("cube", p2.kind.method_call.method_name);

    // Verify 0 syntax diagnostics were generated
    try testing.expectEqual(@as(usize, 0), parser.diagnostics.list.items.len);
}
