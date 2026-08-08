const std = @import("std");
const testing = std.testing;
const ast = @import("../../core/ast.zig");
const ParserTest = @import("../test_utils.zig").ParserTest;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const KTest = ParserTest(Lexer, Parser);

test "AST Node Memory Size Optimization" {
    try testing.expect(@sizeOf(ast.NodeKind) <= 40);
}

test "AST Builder: String Interning Memory Optimization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var builder = ast.Builder.init(arena.allocator());
    defer builder.deinit();
    const str1 = try builder.intern("duplicate_key");
    const str2 = try builder.intern("duplicate_key");
    try testing.expectEqual(str1, str2);
    try testing.expectEqualStrings("duplicate_key", builder.tree.getString(str1));
}

test "KupCAD Parser: Operator Precedence (* vs +)" {
    var pt = try KTest.init("1 + 2 * 3");
    defer pt.deinit();
    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.BinaryOp.add, stmt.kind.binary_op.op);
    const left = pt.getNode(stmt.kind.binary_op.left);
    try testing.expectEqual(@as(f64, 1.0), left.kind.number);
    const right = pt.getNode(stmt.kind.binary_op.right);
    try testing.expectEqual(ast.BinaryOp.multiply, right.kind.binary_op.op);
    const r_left = pt.getNode(right.kind.binary_op.left);
    try testing.expectEqual(@as(f64, 2.0), r_left.kind.number);
    const r_right = pt.getNode(right.kind.binary_op.right);
    try testing.expectEqual(@as(f64, 3.0), r_right.kind.number);
}

test "KupCAD Parser: Right Associativity for Exponentiation (**)" {
    var pt = try KTest.init("2 ** 3 ** 4");
    defer pt.deinit();
    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.BinaryOp.exponent, stmt.kind.binary_op.op);
    const left = pt.getNode(stmt.kind.binary_op.left);
    try testing.expectEqual(@as(f64, 2.0), left.kind.number);
    const right = pt.getNode(stmt.kind.binary_op.right);
    try testing.expectEqual(ast.BinaryOp.exponent, right.kind.binary_op.op);
    const r_left = pt.getNode(right.kind.binary_op.left);
    try testing.expectEqual(@as(f64, 3.0), r_left.kind.number);
}

test "KupCAD Parser: Method Chaining with Named Args" {
    var pt = try KTest.init("Box.new(x: 50).translate(z: 10)");
    defer pt.deinit();
    const tree = &pt.parser.b.tree;
    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("translate", tree.getString(stmt.kind.method_call.method_name));
    const args = tree.getNamedArgs(stmt.kind.method_call.args);
    try testing.expectEqualStrings("z", tree.getString(args[0].name));
    const arg_val = pt.getNode(args[0].value);
    try testing.expectEqual(@as(f64, 10.0), arg_val.kind.number);
    const receiver = pt.getNode(stmt.kind.method_call.receiver);
    try testing.expectEqualStrings("new", tree.getString(receiver.kind.method_call.method_name));
    const base_receiver = pt.getNode(receiver.kind.method_call.receiver);
    try testing.expectEqualStrings("Box", tree.getString(base_receiver.kind.identifier));
}

test "KupCAD Parser: Import Statement" {
    const source = "import { ThreadedInsert, Screw } from \"./hardware.kup\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;
    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("./hardware.kup", tree.getString(stmt.kind.import_stmt.path));
    const symbols = tree.getStringLists(stmt.kind.import_stmt.symbols);
    try testing.expectEqual(@as(usize, 2), symbols.len);
    try testing.expectEqualStrings("ThreadedInsert", tree.getString(symbols[0]));
    try testing.expectEqualStrings("Screw", tree.getString(symbols[1]));
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
    const tree = &pt.parser.b.tree;
    const if_idx = try pt.parser.parseStatement();
    const if_node = pt.getNode(if_idx);
    const cond = pt.getNode(if_node.kind.if_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.greater, cond.kind.binary_op.op);

    const then_branch = pt.getNode(if_node.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const then_stmt = pt.getNode(then_stmts[0]);
    try testing.expectEqualStrings("a", tree.getString(then_stmt.kind.assignment.name));

    const elsif_node = pt.getNode(if_node.kind.if_stmt.else_branch);
    const elsif_cond = pt.getNode(elsif_node.kind.if_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.equal, elsif_cond.kind.binary_op.op);

    const else_block = pt.getNode(elsif_node.kind.if_stmt.else_branch);
    const else_stmts = tree.getNodes(else_block.kind.block.stmts);
    const else_stmt = pt.getNode(else_stmts[0]);
    try testing.expectEqualStrings("a", tree.getString(else_stmt.kind.assignment.name));
}

test "KupCAD Parser: Method Call with Do Block and Parameters" {
    const source =
        \\base.on_face(:top) do |face, idx|
        \\  c1 + c2
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;
    const stmt_index = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_index);
    try testing.expectEqualStrings("on_face", tree.getString(stmt.kind.method_call.method_name));

    const block = pt.getNode(stmt.kind.method_call.block);
    const params = tree.getNodes(block.kind.block.params);
    try testing.expectEqual(@as(usize, 2), params.len);

    try testing.expectEqualStrings("face", tree.getString(pt.getNode(params[0]).kind.identifier));
    try testing.expectEqualStrings("idx", tree.getString(pt.getNode(params[1]).kind.identifier));

    const block_stmts = tree.getNodes(block.kind.block.stmts);
    const stmt2 = pt.getNode(block_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.add, stmt2.kind.binary_op.op);
}

test "KupCAD Parser: Statement Modifiers (Yield Unless)" {
    const source = "yield unless 10 % 3 == 0";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;
    const stmt_index = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_index);
    try testing.expectEqual(true, stmt.kind.if_stmt.is_unless);

    const cond = pt.getNode(stmt.kind.if_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.equal, cond.kind.binary_op.op);

    const then_branch = pt.getNode(stmt.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const inner_yield = pt.getNode(then_stmts[0]);
    const yield_args = tree.getNodes(inner_yield.kind.yield_stmt);
    try testing.expectEqual(@as(usize, 0), yield_args.len);
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
    const tree = &pt.parser.b.tree;

    const class_stmt_index = try pt.parser.parseStatement();
    const class_stmt = pt.getNode(class_stmt_index);
    try testing.expectEqualStrings("MyPart", tree.getString(pt.getNode(class_stmt.kind.class_stmt.name).kind.identifier));
    try testing.expectEqualStrings("Base", tree.getString(pt.getNode(class_stmt.kind.class_stmt.super_class).kind.identifier));

    const class_body = pt.getNode(class_stmt.kind.class_stmt.body);
    const class_stmts = tree.getNodes(class_body.kind.block.stmts);
    const def_node = pt.getNode(class_stmts[0]);
    try testing.expectEqualStrings("is_valid?", tree.getString(def_node.kind.def_stmt.name));

    const def_params = tree.getParams(def_node.kind.def_stmt.params);
    try testing.expectEqualStrings("x", tree.getString(def_params[0].name));

    const default_val = pt.getNode(def_params[0].default_value);
    try testing.expectEqual(@as(f64, 10.0), default_val.kind.number);

    const def_body = pt.getNode(def_node.kind.def_stmt.body);
    const body_stmts = tree.getNodes(def_body.kind.block.stmts);

    const stmt0 = pt.getNode(body_stmts[0]);
    const range_node = pt.getNode(stmt0.kind.assignment.value);
    try testing.expectEqual(@as(f64, 20.0), pt.getNode(range_node.kind.range.start).kind.number);
    try testing.expectEqual(@as(f64, 100.0), pt.getNode(range_node.kind.range.end).kind.number);

    const stmt1 = pt.getNode(body_stmts[1]);
    const array_node = pt.getNode(stmt1.kind.assignment.value);
    const array_elements = tree.getNodes(array_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), array_elements.len);

    const stmt2 = pt.getNode(body_stmts[2]);
    const ret_node = pt.getNode(stmt2.kind.return_stmt);
    try testing.expectEqualStrings("x", tree.getString(pt.getNode(ret_node.kind.ternary_op.condition).kind.identifier));
    try testing.expectEqual(true, pt.getNode(ret_node.kind.ternary_op.then_branch).kind.boolean);
    try testing.expectEqual(false, pt.getNode(ret_node.kind.ternary_op.else_branch).kind.boolean);
}

test "KupCAD Parser: Shorthand Assignment and Hash Rocket" {
    const source =
        \\w += 10
        \\map = { "key" => w }
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const add_assign_index = try pt.parser.parseStatement();
    const add_assign = pt.getNode(add_assign_index);
    try testing.expectEqualStrings("w", tree.getString(add_assign.kind.assignment.name));
    try testing.expectEqual(ast.BinaryOp.add, add_assign.kind.assignment.op.?);

    const hash_assign_index = try pt.parser.parseStatement();
    const hash_assign = pt.getNode(hash_assign_index);
    const hash_node = pt.getNode(hash_assign.kind.assignment.value);
    const hash_entries = tree.getHashEntries(hash_node.kind.hash_literal);
    const key_node = pt.getNode(hash_entries[0].key);
    try testing.expectEqualStrings("key", tree.getString(key_node.kind.string));
}

test "KupCAD Parser: String Interpolation" {
    const source = "echo(\"Value: #{x + 10} mm\")";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const echo_call_index = try pt.parser.parseStatement();
    const echo_call = pt.getNode(echo_call_index);
    const args = tree.getNamedArgs(echo_call.kind.method_call.args);

    const interp_node = pt.getNode(args[0].value);
    const parts = tree.getNodes(interp_node.kind.interpolated_string);
    try testing.expectEqual(@as(usize, 3), parts.len);

    const part0 = pt.getNode(parts[0]);
    try testing.expectEqualStrings("Value: ", tree.getString(part0.kind.string));

    const part1 = pt.getNode(parts[1]);
    try testing.expectEqual(ast.BinaryOp.add, part1.kind.binary_op.op);

    const part2 = pt.getNode(parts[2]);
    try testing.expectEqualStrings(" mm", tree.getString(part2.kind.string));
}

test "KupCAD Parser: Exponentiation vs Unary Precedence" {
    const source = "-2 ** 2";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).unary_op, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(ast.UnaryOp.negate, stmt.kind.unary_op.op);
    const right_node = pt.getNode(stmt.kind.unary_op.operand);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).binary_op, @as(std.meta.Tag(ast.NodeKind), right_node.kind));
    try testing.expectEqual(ast.BinaryOp.exponent, right_node.kind.binary_op.op);
}

test "KupCAD Parser: Parenthesis-less Method Calls (Command Syntax)" {
    const source = "cube x: 10, y: 20";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("cube", tree.getString(stmt.kind.method_call.method_name));

    const args = tree.getNamedArgs(stmt.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));
}

test "KupCAD Parser BUG: Empty String Interpolation" {
    const source = "\"Empty: #{}\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
}

test "KupCAD Parser: Namespace Resolution (Scope Operator ::)" {
    const source = "part = Hardware::Fasteners::M3_Bolt.new(length: 12)";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const call_node = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqualStrings("new", tree.getString(call_node.kind.method_call.method_name));

    const receiver = pt.getNode(call_node.kind.method_call.receiver);
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), receiver.kind));

    const path = tree.getStringLists(receiver.kind.namespace_access);
    try testing.expectEqualStrings("Hardware", tree.getString(path[0]));
    try testing.expectEqualStrings("Fasteners", tree.getString(path[1]));
    try testing.expectEqualStrings("M3_Bolt", tree.getString(path[2]));
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
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.case_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const condition = pt.getNode(stmt.kind.case_stmt.condition);
    try testing.expectEqualStrings("part_type", tree.getString(condition.kind.identifier));

    const branches = tree.getWhenBranches(stmt.kind.case_stmt.when_branches);
    try testing.expectEqual(@as(usize, 2), branches.len);

    const conds0 = tree.getNodes(branches[0].conditions);
    const branch0_cond = pt.getNode(conds0[0]);
    try testing.expectEqualStrings("screw", tree.getString(branch0_cond.kind.symbol));

    const conds1 = tree.getNodes(branches[1].conditions);
    const branch1_cond = pt.getNode(conds1[0]);
    try testing.expectEqualStrings("nut", tree.getString(branch1_cond.kind.symbol));

    const else_branch = pt.getNode(stmt.kind.case_stmt.else_branch);
    const else_stmts = tree.getNodes(else_branch.kind.block.stmts);
    const else_stmt = pt.getNode(else_stmts[0]);
    try testing.expectEqualStrings("new", tree.getString(else_stmt.kind.method_call.method_name));
}

test "KupCAD Parser: Multiple Assignment" {
    const source = "x, y, z = get_coordinates()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.multiple_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const lhs = tree.getLhsExprs(stmt.kind.multiple_assignment.lhs);
    try testing.expectEqual(@as(usize, 3), lhs.len);
    try testing.expectEqualStrings("x", tree.getString(lhs[0].name));
    try testing.expectEqualStrings("y", tree.getString(lhs[1].name));
    try testing.expectEqualStrings("z", tree.getString(lhs[2].name));
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
    const tree = &pt.parser.b.tree;

    const def_node_idx = try pt.parser.parseStatement();
    const def_node = pt.getNode(def_node_idx);
    const body_node = pt.getNode(def_node.kind.def_stmt.body);

    const stmts = tree.getNodes(body_node.kind.block.stmts);
    const stmt0 = pt.getNode(stmts[0]);
    try testing.expectEqual(ast.NodeKind.super_call, @as(std.meta.Tag(ast.NodeKind), stmt0.kind));

    const args = tree.getNamedArgs(stmt0.kind.super_call.args);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));

    const stmt1 = pt.getNode(stmts[1]);
    try testing.expectEqual(ast.NodeKind.self_expr, @as(std.meta.Tag(ast.NodeKind), stmt1.kind));
}

test "KupCAD Parser: Stabby Lambda (Anonymous Function)" {
    const source = "my_lambda = ->(x, y) { x + y }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const lambda = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.lambda_expr, @as(std.meta.Tag(ast.NodeKind), lambda.kind));

    const params = tree.getParams(lambda.kind.lambda_expr.params);
    try testing.expectEqualStrings("x", tree.getString(params[0].name));
    try testing.expectEqualStrings("y", tree.getString(params[1].name));

    const body_node = pt.getNode(lambda.kind.lambda_expr.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.add, stmt0.kind.binary_op.op);
}

test "KupCAD Parser: Exclusive Range (...)" {
    const source = "1...5";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.range, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.range.is_exclusive);

    const end_node = pt.getNode(stmt.kind.range.end);
    try testing.expectEqual(@as(f64, 5.0), end_node.kind.number);
}

test "KupCAD Parser: Statement Modifiers (Trailing if)" {
    const source = "box.chamfer() if render_chamfer";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const cond = pt.getNode(stmt.kind.if_stmt.condition);
    try testing.expectEqualStrings("render_chamfer", tree.getString(cond.kind.identifier));

    const then_branch = pt.getNode(stmt.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const then_stmt0 = pt.getNode(then_stmts[0]);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), then_stmt0.kind));
}

test "KupCAD Parser: Unary Plus Support" {
    const source = "val = +10";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const assign_node_idx = try pt.parser.parseStatement();
    const assign_node = pt.getNode(assign_node_idx);
    try testing.expectEqualStrings("val", tree.getString(assign_node.kind.assignment.name));

    const value_node = pt.getNode(assign_node.kind.assignment.value);
    try testing.expectEqual(ast.UnaryOp.positive, value_node.kind.unary_op.op);
}

test "KupCAD Parser: Splats and Block Forwarding" {
    const source =
        \\def wrapper(*args, **kwargs, &block)
        \\  target.call(*args, **kwargs, &block)
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const def_node_idx = try pt.parser.parseStatement();
    const def_node = pt.getNode(def_node_idx);

    const params = tree.getParams(def_node.kind.def_stmt.params);
    try testing.expectEqual(ast.ArgModifier.splat, params[0].modifier.?);
    try testing.expectEqualStrings("args", tree.getString(params[0].name));
    try testing.expectEqual(ast.ArgModifier.double_splat, params[1].modifier.?);
    try testing.expectEqualStrings("kwargs", tree.getString(params[1].name));
    try testing.expectEqual(ast.ArgModifier.block, params[2].modifier.?);
    try testing.expectEqualStrings("block", tree.getString(params[2].name));

    const body_node = pt.getNode(def_node.kind.def_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const call_node = pt.getNode(body_stmts[0]);

    const args = tree.getNamedArgs(call_node.kind.method_call.args);
    try testing.expectEqual(ast.ArgModifier.splat, args[0].modifier.?);
    try testing.expectEqual(ast.ArgModifier.double_splat, args[1].modifier.?);
    try testing.expectEqual(ast.ArgModifier.block, args[2].modifier.?);
}

test "KupCAD Parser: Shift/Append (<<) and Safe Navigation (&.)" {
    const source = "arr << 5\npart&.cut()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const shift_node_idx = try pt.parser.parseStatement();
    const shift_node = pt.getNode(shift_node_idx);
    try testing.expectEqual(ast.BinaryOp.shift_left, shift_node.kind.binary_op.op);
    try testing.expectEqualStrings("arr", tree.getString(pt.getNode(shift_node.kind.binary_op.left).kind.identifier));
    try testing.expectEqual(@as(f64, 5.0), pt.getNode(shift_node.kind.binary_op.right).kind.number);

    const safe_call_idx = try pt.parser.parseStatement();
    const safe_call = pt.getNode(safe_call_idx);
    try testing.expectEqualStrings("cut", tree.getString(safe_call.kind.method_call.method_name));
    try testing.expectEqual(true, safe_call.kind.method_call.is_safe);
}

test "KupCAD Parser: CSG Intersections and Bitwise Operators" {
    const source = "result = ~part1 & part2 | part3 ^ part4";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("result", tree.getString(stmt.kind.assignment.name));

    const xor_node = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(ast.BinaryOp.bitwise_xor, xor_node.kind.binary_op.op);
    try testing.expectEqualStrings("part4", tree.getString(pt.getNode(xor_node.kind.binary_op.right).kind.identifier));

    const or_node = pt.getNode(xor_node.kind.binary_op.left);
    try testing.expectEqual(ast.BinaryOp.bitwise_or, or_node.kind.binary_op.op);
    try testing.expectEqualStrings("part3", tree.getString(pt.getNode(or_node.kind.binary_op.right).kind.identifier));

    const and_node = pt.getNode(or_node.kind.binary_op.left);
    try testing.expectEqual(ast.BinaryOp.bitwise_and, and_node.kind.binary_op.op);
    try testing.expectEqualStrings("part2", tree.getString(pt.getNode(and_node.kind.binary_op.right).kind.identifier));

    const not_node = pt.getNode(and_node.kind.binary_op.left);
    try testing.expectEqual(ast.UnaryOp.bitwise_not, not_node.kind.unary_op.op);
    try testing.expectEqualStrings("part1", tree.getString(pt.getNode(not_node.kind.unary_op.operand).kind.identifier));
}

test "KupCAD Parser: Curly Brace Method Blocks" {
    const source = "faces.each { |f| f.fillet(2) }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("each", tree.getString(stmt.kind.method_call.method_name));

    const block = pt.getNode(stmt.kind.method_call.block);
    const params = tree.getNodes(block.kind.block.params);
    try testing.expectEqualStrings("f", tree.getString(pt.getNode(params[0]).kind.identifier));

    const block_stmts = tree.getNodes(block.kind.block.stmts);
    const inner_call = pt.getNode(block_stmts[0]);
    try testing.expectEqualStrings("fillet", tree.getString(inner_call.kind.method_call.method_name));
}

test "KupCAD Parser: Next Statement and Until/While Modifiers" {
    const source = "next 10 until x == 5";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.while_stmt.is_until);

    const body_node = pt.getNode(stmt.kind.while_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const inner_next = pt.getNode(body_stmts[0]);
    try testing.expectEqual(ast.NodeKind.next_stmt, @as(std.meta.Tag(ast.NodeKind), inner_next.kind));

    const next_val = pt.getNode(inner_next.kind.next_stmt);
    try testing.expectEqual(@as(f64, 10.0), next_val.kind.number);
}

test "KupCAD Parser: LHS Splats and Multiple Assignment" {
    const source = "first, *rest = get_faces()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    const lhs = tree.getLhsExprs(stmt.kind.multiple_assignment.lhs);
    try testing.expectEqual(@as(usize, 2), lhs.len);
    try testing.expectEqualStrings("first", tree.getString(lhs[0].name));
    try testing.expectEqual(ast.ArgModifier.splat, lhs[1].modifier.?);
    try testing.expectEqualStrings("rest", tree.getString(lhs[1].name));
}

test "KupCAD Parser: Keyword Arguments in Definitions" {
    const source = "def build(width:, height: 10)\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    const params = tree.getParams(stmt.kind.def_stmt.params);
    try testing.expectEqual(true, params[0].is_keyword);
    try testing.expectEqualStrings("width", tree.getString(params[0].name));

    try testing.expectEqual(true, params[1].is_keyword);
    try testing.expectEqualStrings("height", tree.getString(params[1].name));

    const default_val = pt.getNode(params[1].default_value);
    try testing.expectEqual(@as(f64, 10.0), default_val.kind.number);
}

test "KupCAD Parser: Begin / Rescue / Ensure" {
    const source = "begin\n  build()\nrescue => e\n  log()\nensure\n  clean()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const body_block = pt.getNode(stmt.kind.begin_stmt.body);
    const body_stmts = tree.getNodes(body_block.kind.block.stmts);
    const body_stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqualStrings("build", tree.getString(body_stmt0.kind.method_call.method_name));

    const rescues = tree.getRescueClauses(stmt.kind.begin_stmt.rescues);
    const rescue_body = pt.getNode(rescues[0].body);
    const rescue_stmts = tree.getNodes(rescue_body.kind.block.stmts);
    const rescue_stmt0 = pt.getNode(rescue_stmts[0]);
    try testing.expectEqualStrings("log", tree.getString(rescue_stmt0.kind.method_call.method_name));

    const ensure_body = pt.getNode(stmt.kind.begin_stmt.ensure_body);
    const ensure_stmts = tree.getNodes(ensure_body.kind.block.stmts);
    const ensure_stmt0 = pt.getNode(ensure_stmts[0]);
    try testing.expectEqualStrings("clean", tree.getString(ensure_stmt0.kind.method_call.method_name));
}

test "KupCAD Parser: Object Property Assignment" {
    const source = "box.width = 100";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("box", tree.getString(pt.getNode(stmt.kind.property_assignment.target).kind.identifier));
    try testing.expectEqualStrings("width", tree.getString(stmt.kind.property_assignment.property));
    try testing.expectEqual(@as(f64, 100.0), pt.getNode(stmt.kind.property_assignment.value).kind.number);
}

test "KupCAD Parser: Receiver Command Syntax" {
    const source = "box.translate x: 10, y: 20 do\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("translate", tree.getString(stmt.kind.method_call.method_name));
    try testing.expectEqualStrings("box", tree.getString(pt.getNode(stmt.kind.method_call.receiver).kind.identifier));

    const args = tree.getNamedArgs(stmt.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));
    try testing.expectEqualStrings("y", tree.getString(args[1].name));
    try testing.expect(stmt.kind.method_call.block != .none);
}

test "KupCAD Parser: Begin / Rescue / Ensure with Classes" {
    const source = "begin\n  build()\nrescue IOError, KeyError => e\n  log()\nensure\n  clean()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const body_node = pt.getNode(stmt.kind.begin_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const body_stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqualStrings("build", tree.getString(body_stmt0.kind.method_call.method_name));

    const rescues = tree.getRescueClauses(stmt.kind.begin_stmt.rescues);
    const rescue_clause = rescues[0];
    const errors = tree.getStringLists(rescue_clause.errors);
    try testing.expectEqual(@as(usize, 2), errors.len);
    try testing.expectEqualStrings("IOError", tree.getString(errors[0]));
    try testing.expectEqualStrings("KeyError", tree.getString(errors[1]));
    try testing.expectEqualStrings("e", tree.getString(rescue_clause.variable));

    const rescue_body = pt.getNode(rescue_clause.body);
    const rescue_stmts = tree.getNodes(rescue_body.kind.block.stmts);
    const rescue_stmt0 = pt.getNode(rescue_stmts[0]);
    try testing.expectEqualStrings("log", tree.getString(rescue_stmt0.kind.method_call.method_name));

    const ensure_node = pt.getNode(stmt.kind.begin_stmt.ensure_body);
    const ensure_stmts = tree.getNodes(ensure_node.kind.block.stmts);
    const ensure_stmt0 = pt.getNode(ensure_stmts[0]);
    try testing.expectEqualStrings("clean", tree.getString(ensure_stmt0.kind.method_call.method_name));
}

test "KupCAD Parser: Inline Rescue Modifier" {
    const source = "val = dangerous() rescue 0";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const res_mod = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.rescue_modifier, @as(std.meta.Tag(ast.NodeKind), res_mod.kind));

    const expr = pt.getNode(res_mod.kind.rescue_modifier.expr);
    try testing.expectEqualStrings("dangerous", tree.getString(expr.kind.method_call.method_name));

    const rescue_expr = pt.getNode(res_mod.kind.rescue_modifier.rescue_expr);
    try testing.expectEqual(@as(f64, 0.0), rescue_expr.kind.number);
}

test "KupCAD Lexer and Parser: Percent Literals (%w, %i)" {
    const source = "list = %w[gear shaft motor]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const arr_node = pt.getNode(stmt.kind.assignment.value);
    const arr = tree.getNodes(arr_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), arr.len);

    try testing.expectEqualStrings("gear", tree.getString(pt.getNode(arr[0]).kind.string));
    try testing.expectEqualStrings("shaft", tree.getString(pt.getNode(arr[1]).kind.string));
    try testing.expectEqualStrings("motor", tree.getString(pt.getNode(arr[2]).kind.string));
}

test "KupCAD Parser: Class Methods and Namespaced Inheritance" {
    const source = "class Hardware::Screw < Base::Part\n  def self.build()\n  end\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const class_stmt_idx = try pt.parser.parseStatement();
    const class_stmt = pt.getNode(class_stmt_idx);

    const name_node = pt.getNode(class_stmt.kind.class_stmt.name);
    const name_path = tree.getStringLists(name_node.kind.namespace_access);
    try testing.expectEqualStrings("Hardware", tree.getString(name_path[0]));

    const super_node = pt.getNode(class_stmt.kind.class_stmt.super_class);
    const super_path = tree.getStringLists(super_node.kind.namespace_access);
    try testing.expectEqualStrings("Base", tree.getString(super_path[0]));

    const body_node = pt.getNode(class_stmt.kind.class_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const def_node = pt.getNode(body_stmts[0]);
    try testing.expectEqual(true, def_node.kind.def_stmt.is_class_method);
    try testing.expectEqualStrings("build", tree.getString(def_node.kind.def_stmt.name));
}

test "KupCAD Parser: Implicit RHS Tuples and Array/Hash Splats" {
    const source = "x, y = 10, 20\narr = [1, *other]\nopts = {a: 1, **kwargs}";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const multi_assign_idx = try pt.parser.parseStatement();
    const multi_assign = pt.getNode(multi_assign_idx);
    const multi_val = pt.getNode(multi_assign.kind.multiple_assignment.value);
    const multi_arr = tree.getNodes(multi_val.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), multi_arr.len);

    const arr_assign_idx = try pt.parser.parseStatement();
    const arr_assign = pt.getNode(arr_assign_idx);
    const arr_node = pt.getNode(arr_assign.kind.assignment.value);
    const arr_lit = tree.getNodes(arr_node.kind.array_literal);
    const splat_node = pt.getNode(arr_lit[1]);
    try testing.expectEqual(ast.NodeKind.splat_expr, @as(std.meta.Tag(ast.NodeKind), splat_node.kind));

    const hash_assign_idx = try pt.parser.parseStatement();
    const hash_assign = pt.getNode(hash_assign_idx);
    const hash_node = pt.getNode(hash_assign.kind.assignment.value);
    const hash_lit = tree.getHashEntries(hash_node.kind.hash_literal);
    const double_splat_node = pt.getNode(hash_lit[1].key);
    try testing.expectEqual(ast.NodeKind.double_splat_expr, @as(std.meta.Tag(ast.NodeKind), double_splat_node.kind));
}

test "KupCAD Parser: Quoted Symbols, Single Quotes, Destructuring" {
    const source = "map.each(:'key name') do |(x, y), val|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const args = tree.getNamedArgs(stmt.kind.method_call.args);
    const arg0 = pt.getNode(args[0].value);
    try testing.expectEqualStrings("key name", tree.getString(arg0.kind.symbol));

    const block = pt.getNode(stmt.kind.method_call.block);
    const params = tree.getNodes(block.kind.block.params);

    const param0 = pt.getNode(params[0]);
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), param0.kind));

    const param0_elems = tree.getNodes(param0.kind.array_literal);
    try testing.expectEqualStrings("x", tree.getString(pt.getNode(param0_elems[0]).kind.identifier));
    try testing.expectEqualStrings("y", tree.getString(pt.getNode(param0_elems[1]).kind.identifier));

    const param1 = pt.getNode(params[1]);
    try testing.expectEqualStrings("val", tree.getString(param1.kind.identifier));
}

test "KupCAD Parser: Super with Command Syntax and Blocks" {
    const source = "super x: 10 do\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.super_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const args = tree.getNamedArgs(stmt.kind.super_call.args);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));
    try testing.expect(stmt.kind.super_call.block != .none);
}

test "KupCAD Parser: Optional 'then' Keyword" {
    const source = "if x > 5 then a = 1 end";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const then_branch = pt.getNode(stmt.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const then_stmt0 = pt.getNode(then_stmts[0]);
    try testing.expectEqualStrings("a", tree.getString(then_stmt0.kind.assignment.name));
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
    const tree = &pt.parser.b.tree;

    const def_node_idx = try pt.parser.parseStatement();
    const def_node = pt.getNode(def_node_idx);
    try testing.expectEqualStrings("process", tree.getString(def_node.kind.def_stmt.name));

    const begin_node = pt.getNode(def_node.kind.def_stmt.body);
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), begin_node.kind));

    const body_node = pt.getNode(begin_node.kind.begin_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const body_stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqualStrings("run_step", tree.getString(body_stmt0.kind.method_call.method_name));

    const rescues = tree.getRescueClauses(begin_node.kind.begin_stmt.rescues);
    const rescue_clause = rescues[0];
    try testing.expectEqualStrings("err", tree.getString(rescue_clause.variable));

    const rescue_body = pt.getNode(rescue_clause.body);
    const rescue_stmts = tree.getNodes(rescue_body.kind.block.stmts);
    const rescue_stmt0 = pt.getNode(rescue_stmts[0]);
    try testing.expectEqualStrings("handle_error", tree.getString(rescue_stmt0.kind.method_call.method_name));

    const ensure_node = pt.getNode(begin_node.kind.begin_stmt.ensure_body);
    const ensure_stmts = tree.getNodes(ensure_node.kind.block.stmts);
    const ensure_stmt0 = pt.getNode(ensure_stmts[0]);
    try testing.expectEqualStrings("cleanup", tree.getString(ensure_stmt0.kind.method_call.method_name));
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

    const n1 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 31.0), pt.getNode(n1.kind.assignment.value).kind.number);

    const n2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(n2.kind.assignment.value).kind.number);

    const n3 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 493.0), pt.getNode(n3.kind.assignment.value).kind.number);

    const n4 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 1500.0), pt.getNode(n4.kind.assignment.value).kind.number);

    const n5 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 1000000.0), pt.getNode(n5.kind.assignment.value).kind.number);

    const n6 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 0.56), pt.getNode(n6.kind.assignment.value).kind.number);
}

test "KupCAD Parser: Multi-line Method Chaining (Fluent API)" {
    const source =
        \\Box.new(10)
        \\  .chamfer(2)
        \\  .translate(x: 5)
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("translate", tree.getString(stmt.kind.method_call.method_name));

    const chamfer_node = pt.getNode(stmt.kind.method_call.receiver);
    try testing.expectEqualStrings("chamfer", tree.getString(chamfer_node.kind.method_call.method_name));

    const new_node = pt.getNode(chamfer_node.kind.method_call.receiver);
    try testing.expectEqualStrings("new", tree.getString(new_node.kind.method_call.method_name));
}

test "KupCAD Parser: Import / Export with Attributes (with {})" {
    const source =
        \\import { names } from "module-name" with { key: "data", key2: "data2" }
        \\export { names } from "module-name" with {}
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const imp_node_idx = try pt.parser.parseStatement();
    const imp_node = pt.getNode(imp_node_idx);
    try testing.expectEqual(ast.NodeKind.import_stmt, @as(std.meta.Tag(ast.NodeKind), imp_node.kind));
    try testing.expectEqualStrings("module-name", tree.getString(imp_node.kind.import_stmt.path));

    const imp_symbols = tree.getStringLists(imp_node.kind.import_stmt.symbols);
    try testing.expectEqualStrings("names", tree.getString(imp_symbols[0]));

    const attrs = pt.getNode(imp_node.kind.import_stmt.attributes);
    const hash_entries = tree.getHashEntries(attrs.kind.hash_literal);
    try testing.expectEqual(@as(usize, 2), hash_entries.len);
    try testing.expectEqualStrings("key", tree.getString(pt.getNode(hash_entries[0].key).kind.symbol));

    const exp_node_idx = try pt.parser.parseStatement();
    const exp_node = pt.getNode(exp_node_idx);
    try testing.expectEqual(ast.NodeKind.export_stmt, @as(std.meta.Tag(ast.NodeKind), exp_node.kind));
    try testing.expectEqualStrings("module-name", tree.getString(exp_node.kind.export_stmt.path));

    const exp_attrs = pt.getNode(exp_node.kind.export_stmt.attributes);
    const exp_hash_entries = tree.getHashEntries(exp_attrs.kind.hash_literal);
    try testing.expectEqual(@as(usize, 0), exp_hash_entries.len);
}

test "KupCAD Parser: Optional Imports and Trailing Call Commas" {
    const source =
        \\import "global_config.kup"
        \\import Hardware from "hardware.kup"
        \\cube(10, 20, )
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const imp_node_1 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("global_config.kup", tree.getString(imp_node_1.kind.import_stmt.path));
    const symbols1 = tree.getStringLists(imp_node_1.kind.import_stmt.symbols);
    try testing.expectEqual(@as(usize, 0), symbols1.len);

    const imp_node_2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("hardware.kup", tree.getString(imp_node_2.kind.import_stmt.path));
    const symbols2 = tree.getStringLists(imp_node_2.kind.import_stmt.symbols);
    try testing.expectEqualStrings("Hardware", tree.getString(symbols2[0]));

    const call_node = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("cube", tree.getString(call_node.kind.method_call.method_name));
    const args = tree.getNamedArgs(call_node.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), args.len);
}

test "KupCAD Parser: Diagnostics for Unexpected Token" {
    const source = "(x + 1 ]";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const result = pt.parser.parseExpression(.none);
    try testing.expectError(error.UnexpectedToken, result);
    try testing.expectEqual(@as(usize, 1), pt.parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Expected 'r_paren', but found ']'", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Diagnostics for Invalid Expression" {
    const source = "val = }";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const result = pt.parser.parseStatement();
    try testing.expectError(error.InvalidExpression, result);
    try testing.expectEqual(@as(usize, 1), pt.parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Invalid expression starting with '}'", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Combinators and Trailing Commas" {
    const source =
        \\arr = [1, 2, ]
        \\map = {a: 1, b: 2, }
        \\obj.each do |x, y, |
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const n1 = pt.getNode(try pt.parser.parseStatement());
    const arr_elems = tree.getNodes(pt.getNode(n1.kind.assignment.value).kind.array_literal);
    try testing.expectEqual(@as(usize, 2), arr_elems.len);

    const n2 = pt.getNode(try pt.parser.parseStatement());
    const hash_entries = tree.getHashEntries(pt.getNode(n2.kind.assignment.value).kind.hash_literal);
    try testing.expectEqual(@as(usize, 2), hash_entries.len);

    const n3 = pt.getNode(try pt.parser.parseStatement());
    const block = pt.getNode(n3.kind.method_call.block);
    const params = tree.getNodes(block.kind.block.params);
    try testing.expectEqual(@as(usize, 2), params.len);
}

test "KupCAD Parser: Index Access and Index Compound Assignment" {
    const source = "points[0] += offset * 2";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.index_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("points", tree.getString(pt.getNode(stmt.kind.index_assignment.target).kind.identifier));
    try testing.expectEqual(@as(f64, 0.0), pt.getNode(stmt.kind.index_assignment.index).kind.number);
    try testing.expectEqual(ast.BinaryOp.add, stmt.kind.index_assignment.op.?);

    const val_node = pt.getNode(stmt.kind.index_assignment.value);
    try testing.expectEqual(ast.BinaryOp.multiply, val_node.kind.binary_op.op);
}

test "KupCAD Parser: Nested Module Definitions and Export Statements" {
    const source =
        \\export { Enclosure, Mount } from "./housing.kup" with { version: 2 }
        \\module Hardware
        \\  class Screw < Base
        \\  end
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const export_node = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.NodeKind.export_stmt, @as(std.meta.Tag(ast.NodeKind), export_node.kind));
    try testing.expectEqualStrings("./housing.kup", tree.getString(export_node.kind.export_stmt.path));

    const export_symbols = tree.getStringLists(export_node.kind.export_stmt.symbols);
    try testing.expectEqualStrings("Enclosure", tree.getString(export_symbols[0]));
    try testing.expectEqualStrings("Mount", tree.getString(export_symbols[1]));

    const mod_node = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.NodeKind.module_stmt, @as(std.meta.Tag(ast.NodeKind), mod_node.kind));
    try testing.expectEqualStrings("Hardware", tree.getString(mod_node.kind.module_stmt.name));

    const body_node = pt.getNode(mod_node.kind.module_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const inner_class = pt.getNode(body_stmts[0]);
    const class_name = pt.getNode(inner_class.kind.class_stmt.name);
    try testing.expectEqualStrings("Screw", tree.getString(class_name.kind.identifier));
}

test "KupCAD Parser: Multi-line Arrays with Interspersed Comments" {
    const source =
        \\pts = [
        \\  # start point
        \\  10,
        \\  # mid point
        \\  20,
        \\  30
        \\]
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const arr_node = pt.getNode(stmt.kind.assignment.value);
    const arr = tree.getNodes(arr_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), arr.len);

    try testing.expectEqual(@as(f64, 10.0), pt.getNode(arr[0]).kind.number);
    try testing.expectEqual(@as(f64, 20.0), pt.getNode(arr[1]).kind.number);
    try testing.expectEqual(@as(f64, 30.0), pt.getNode(arr[2]).kind.number);
}

test "KupCAD Parser: Safe Navigation Multi-line Fluent API" {
    const source =
        \\part
        \\  &.cut(hole)
        \\  &.chamfer(radius: 1.5)
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("chamfer", tree.getString(stmt.kind.method_call.method_name));
    try testing.expectEqual(true, stmt.kind.method_call.is_safe);

    const prev_call = pt.getNode(stmt.kind.method_call.receiver);
    try testing.expectEqualStrings("cut", tree.getString(prev_call.kind.method_call.method_name));
    try testing.expectEqual(true, prev_call.kind.method_call.is_safe);
}

test "KupCAD Parser: Parametric Doc Comments Parsing" {
    const source = "# @param length [Length] Screw length { min: 10, max: 20 }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).param_doc, std.meta.activeTag(stmt.kind));

    const doc = tree.param_docs.items[stmt.kind.param_doc];
    try testing.expectEqualStrings("param", tree.getString(doc.tag_name));
    try testing.expectEqualStrings("length", tree.getString(doc.target_name));
    try testing.expectEqualStrings("Length", tree.getString(doc.type_name));
    try testing.expectEqualStrings("Screw length", tree.getString(doc.description));

    const options_hash_node = pt.getNode(doc.options_expr);
    const options_hash = tree.getHashEntries(options_hash_node.kind.hash_literal);
    try testing.expectEqual(@as(usize, 2), options_hash.len);
    try testing.expectEqualStrings("min", tree.getString(pt.getNode(options_hash[0].key).kind.symbol));
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(options_hash[0].value).kind.number);
}

test "KupCAD Parser: Diagnostics for Malformed Class Declaration" {
    const source = "class Box < 123\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const result = pt.parser.parseStatement();
    try testing.expectError(error.UnexpectedToken, result);
    try testing.expectEqual(@as(usize, 1), pt.parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Expected 'constant', but found '123'", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: CSG Math Chains with Mixed Arithmetic and Set Operators" {
    const source = "base_mesh + (cover - cylinder(r: 2)) & boundary";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.BinaryOp.bitwise_and, stmt.kind.binary_op.op);
    try testing.expectEqualStrings("boundary", tree.getString(pt.getNode(stmt.kind.binary_op.right).kind.identifier));

    const left_expr = pt.getNode(stmt.kind.binary_op.left);
    try testing.expectEqual(ast.BinaryOp.add, left_expr.kind.binary_op.op);
    try testing.expectEqualStrings("base_mesh", tree.getString(pt.getNode(left_expr.kind.binary_op.left).kind.identifier));

    const paren_expr = pt.getNode(left_expr.kind.binary_op.right);
    try testing.expectEqual(ast.BinaryOp.subtract, paren_expr.kind.binary_op.op);
    try testing.expectEqualStrings("cover", tree.getString(pt.getNode(paren_expr.kind.binary_op.left).kind.identifier));
    try testing.expectEqualStrings("cylinder", tree.getString(pt.getNode(paren_expr.kind.binary_op.right).kind.method_call.method_name));
}

test "KupCAD Parser: Nested Command Syntax Transforms with Blocks" {
    const source =
        \\translate x: 10, y: 20 do
        \\  rotate z: 45 do
        \\    cube size: 10
        \\  end
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const top_call_idx = try pt.parser.parseStatement();
    const top_call = pt.getNode(top_call_idx);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), top_call.kind));
    try testing.expectEqualStrings("translate", tree.getString(top_call.kind.method_call.method_name));

    const top_args = tree.getNamedArgs(top_call.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), top_args.len);

    const top_block = pt.getNode(top_call.kind.method_call.block);
    const top_stmts = tree.getNodes(top_block.kind.block.stmts);
    const rotate_call = pt.getNode(top_stmts[0]);
    try testing.expectEqualStrings("rotate", tree.getString(rotate_call.kind.method_call.method_name));

    const rotate_block = pt.getNode(rotate_call.kind.method_call.block);
    const rotate_stmts = tree.getNodes(rotate_block.kind.block.stmts);
    const cube_call = pt.getNode(rotate_stmts[0]);
    try testing.expectEqualStrings("cube", tree.getString(cube_call.kind.method_call.method_name));

    const cube_args = tree.getNamedArgs(cube_call.kind.method_call.args);
    try testing.expectEqualStrings("size", tree.getString(cube_args[0].name));
}

test "KupCAD Parser: Range Slicing inside Indexing Operations" {
    const source = "subset = vertices[1..4]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("subset", tree.getString(stmt.kind.assignment.name));

    const index_access = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.index_access, @as(std.meta.Tag(ast.NodeKind), index_access.kind));
    try testing.expectEqualStrings("vertices", tree.getString(pt.getNode(index_access.kind.index_access.target).kind.identifier));

    const range_node = pt.getNode(index_access.kind.index_access.index);
    try testing.expectEqual(ast.NodeKind.range, @as(std.meta.Tag(ast.NodeKind), range_node.kind));
    try testing.expectEqual(@as(f64, 1.0), pt.getNode(range_node.kind.range.start).kind.number);
    try testing.expectEqual(@as(f64, 4.0), pt.getNode(range_node.kind.range.end).kind.number);
    try testing.expectEqual(false, range_node.kind.range.is_exclusive);
}

test "KupCAD Parser: Complex Nested Hashes with Symbol Arrays (%i)" {
    const source = "options = { style: :fillet, keys: %i[r h d], inner: { depth: 5 } }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const hash_node = pt.getNode(stmt.kind.assignment.value);
    const hash = tree.getHashEntries(hash_node.kind.hash_literal);
    try testing.expectEqual(@as(usize, 3), hash.len);

    try testing.expectEqualStrings("style", tree.getString(pt.getNode(hash[0].key).kind.symbol));
    try testing.expectEqualStrings("fillet", tree.getString(pt.getNode(hash[0].value).kind.symbol));

    try testing.expectEqualStrings("keys", tree.getString(pt.getNode(hash[1].key).kind.symbol));
    const sym_array_node = pt.getNode(hash[1].value);
    const sym_array = tree.getNodes(sym_array_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), sym_array.len);
    try testing.expectEqualStrings("r", tree.getString(pt.getNode(sym_array[0]).kind.symbol));

    try testing.expectEqualStrings("inner", tree.getString(pt.getNode(hash[2].key).kind.symbol));
    const nested_hash_node = pt.getNode(hash[2].value);
    const nested_hash = tree.getHashEntries(nested_hash_node.kind.hash_literal);
    try testing.expectEqualStrings("depth", tree.getString(pt.getNode(nested_hash[0].key).kind.symbol));
    try testing.expectEqual(@as(f64, 5.0), pt.getNode(nested_hash[0].value).kind.number);
}

test "KupCAD Parser: Multiple Destructuring Assignment with Splats" {
    const source = "a, *middle, z = [1, 2, 3, 4, 5]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.multiple_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const lhs = tree.getLhsExprs(stmt.kind.multiple_assignment.lhs);
    try testing.expectEqual(@as(usize, 3), lhs.len);

    try testing.expectEqualStrings("a", tree.getString(lhs[0].name));
    try testing.expectEqual(@as(?ast.ArgModifier, null), lhs[0].modifier);

    try testing.expectEqualStrings("middle", tree.getString(lhs[1].name));
    try testing.expectEqual(ast.ArgModifier.splat, lhs[1].modifier.?);

    try testing.expectEqualStrings("z", tree.getString(lhs[2].name));
    try testing.expectEqual(@as(?ast.ArgModifier, null), lhs[2].modifier);
}

test "KupCAD Parser: Hexadecimal, Scientific, and Negative Math Operations" {
    const source = "val = -0x1F + .5 * 1.5e2 - 0b10";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const math_node = pt.getNode(stmt.kind.assignment.value);

    // Root is subtraction `- 0b10`
    try testing.expectEqual(ast.BinaryOp.subtract, math_node.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 2.0), pt.getNode(math_node.kind.binary_op.right).kind.number); // 0b10 = 2

    // Left is `-0x1F + (.5 * 1.5e2)`
    const add_node = pt.getNode(math_node.kind.binary_op.left);
    try testing.expectEqual(ast.BinaryOp.add, add_node.kind.binary_op.op);

    // Negated Hex: -0x1F (-31)
    const neg_hex = pt.getNode(add_node.kind.binary_op.left);
    try testing.expectEqual(ast.UnaryOp.negate, neg_hex.kind.unary_op.op);
    try testing.expectEqual(@as(f64, 31.0), pt.getNode(neg_hex.kind.unary_op.operand).kind.number);

    // Multiplication: .5 * 150.0 = 75.0
    const mult_node = pt.getNode(add_node.kind.binary_op.right);
    try testing.expectEqual(ast.BinaryOp.multiply, mult_node.kind.binary_op.op);
    try testing.expectEqual(@as(f64, 0.5), pt.getNode(mult_node.kind.binary_op.left).kind.number);
    try testing.expectEqual(@as(f64, 150.0), pt.getNode(mult_node.kind.binary_op.right).kind.number);
}

test "KupCAD Parser: Class Inheritance with Scope Resolution and Class Methods" {
    const source =
        \\class CAD::Fastener::Bolt < Hardware::Base
        \\  def self.m3(length: 10)
        \\    new(diameter: 3, length: length)
        \\  end
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const class_stmt_idx = try pt.parser.parseStatement();
    const class_stmt = pt.getNode(class_stmt_idx);
    try testing.expectEqual(ast.NodeKind.class_stmt, @as(std.meta.Tag(ast.NodeKind), class_stmt.kind));

    // Name: CAD::Fastener::Bolt
    const name_node = pt.getNode(class_stmt.kind.class_stmt.name);
    const name_ns = tree.getStringLists(name_node.kind.namespace_access);
    try testing.expectEqual(@as(usize, 3), name_ns.len);
    try testing.expectEqualStrings("CAD", tree.getString(name_ns[0]));
    try testing.expectEqualStrings("Fastener", tree.getString(name_ns[1]));
    try testing.expectEqualStrings("Bolt", tree.getString(name_ns[2]));

    // Super: Hardware::Base
    const super_node = pt.getNode(class_stmt.kind.class_stmt.super_class);
    const super_ns = tree.getStringLists(super_node.kind.namespace_access);
    try testing.expectEqual(@as(usize, 2), super_ns.len);
    try testing.expectEqualStrings("Hardware", tree.getString(super_ns[0]));
    try testing.expectEqualStrings("Base", tree.getString(super_ns[1]));

    // Class Method: def self.m3
    const body_node = pt.getNode(class_stmt.kind.class_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const def_node = pt.getNode(body_stmts[0]);
    try testing.expectEqual(true, def_node.kind.def_stmt.is_class_method);
    try testing.expectEqualStrings("m3", tree.getString(def_node.kind.def_stmt.name));

    const params = tree.getParams(def_node.kind.def_stmt.params);
    try testing.expectEqualStrings("length", tree.getString(params[0].name));
}

test "KupCAD Parser: Top-Level Scope Resolution with Chained Calls" {
    const source = "part = ::Hardware::Fastener::Screw.build(length: 20)";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const call_node = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqualStrings("build", tree.getString(call_node.kind.method_call.method_name));

    const ns_access = pt.getNode(call_node.kind.method_call.receiver);
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), ns_access.kind));

    const path = tree.getStringLists(ns_access.kind.namespace_access);
    try testing.expectEqual(@as(usize, 3), path.len);
    try testing.expectEqualStrings("Hardware", tree.getString(path[0]));
    try testing.expectEqualStrings("Fastener", tree.getString(path[1]));
    try testing.expectEqualStrings("Screw", tree.getString(path[2]));
}

test "KupCAD Parser: Bitwise and Logical Shorthand Compound Assignments" {
    const source =
        \\mask &= 0xFF
        \\flags |= 0b100
        \\key ^= 0x01
        \\buf <<= 8
        \\val ||= default_val
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    // mask &= 0xFF
    const s1 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("mask", tree.getString(s1.kind.assignment.name));
    try testing.expectEqual(ast.BinaryOp.bitwise_and, s1.kind.assignment.op.?);

    // flags |= 0b100
    const s2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("flags", tree.getString(s2.kind.assignment.name));
    try testing.expectEqual(ast.BinaryOp.bitwise_or, s2.kind.assignment.op.?);

    // key ^= 0x01
    const s3 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("key", tree.getString(s3.kind.assignment.name));
    try testing.expectEqual(ast.BinaryOp.bitwise_xor, s3.kind.assignment.op.?);

    // buf <<= 8
    const s4 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("buf", tree.getString(s4.kind.assignment.name));
    try testing.expectEqual(ast.BinaryOp.shift_left, s4.kind.assignment.op.?);

    // val ||= default_val
    const s5 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("val", tree.getString(s5.kind.assignment.name));
    try testing.expectEqual(ast.BinaryOp.logical_or, s5.kind.assignment.op.?);
}

test "KupCAD Parser: Keyword Logical Operators (and, or, not) Precedence" {
    const source = "valid and ready or not disabled";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);

    // Logical OR has lower precedence than AND, so OR is root
    try testing.expectEqual(ast.BinaryOp.logical_or, expr.kind.binary_op.op);

    // Right of OR is `not disabled`
    const not_node = pt.getNode(expr.kind.binary_op.right);
    try testing.expectEqual(ast.UnaryOp.not, not_node.kind.unary_op.op);
    try testing.expectEqualStrings("disabled", tree.getString(pt.getNode(not_node.kind.unary_op.operand).kind.identifier));

    // Left of OR is `valid and ready`
    const and_node = pt.getNode(expr.kind.binary_op.left);
    try testing.expectEqual(ast.BinaryOp.logical_and, and_node.kind.binary_op.op);
    try testing.expectEqualStrings("valid", tree.getString(pt.getNode(and_node.kind.binary_op.left).kind.identifier));
    try testing.expectEqualStrings("ready", tree.getString(pt.getNode(and_node.kind.binary_op.right).kind.identifier));
}

test "KupCAD Parser: Control Flow Statements with Payloads and Modifiers" {
    const source =
        \\break 42 if finished?
        \\return x, y unless error?
        \\next val until done?
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    // break 42 if finished?
    const s1 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), s1.kind));
    try testing.expectEqualStrings("finished?", tree.getString(pt.getNode(s1.kind.if_stmt.condition).kind.identifier));

    const then1_block = pt.getNode(s1.kind.if_stmt.then_branch);
    const then1_stmts = tree.getNodes(then1_block.kind.block.stmts);
    const break_node = pt.getNode(then1_stmts[0]);
    try testing.expectEqual(@as(f64, 42.0), pt.getNode(break_node.kind.break_stmt).kind.number);

    // return x, y unless error?
    const s2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), s2.kind));
    try testing.expectEqual(true, s2.kind.if_stmt.is_unless);

    const then2_block = pt.getNode(s2.kind.if_stmt.then_branch);
    const then2_stmts = tree.getNodes(then2_block.kind.block.stmts);
    const ret_node = pt.getNode(then2_stmts[0]);
    const ret_val_node = pt.getNode(ret_node.kind.return_stmt);
    const ret_arr = tree.getNodes(ret_val_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), ret_arr.len);

    // next val until done?
    const s3 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), s3.kind));
    try testing.expectEqual(true, s3.kind.while_stmt.is_until);

    const while3_body = pt.getNode(s3.kind.while_stmt.body);
    const while3_stmts = tree.getNodes(while3_body.kind.block.stmts);
    const next_node = pt.getNode(while3_stmts[0]);
    try testing.expectEqualStrings("val", tree.getString(pt.getNode(next_node.kind.next_stmt).kind.identifier));
}

test "KupCAD Parser: Multi-Interpolation String with Expressions and Method Calls" {
    const source = "\"Part: #{part.name} at X:#{part.x + 10}, Y:#{part.y}\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);
    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), expr.kind));

    const parts = tree.getNodes(expr.kind.interpolated_string);
    try testing.expectEqual(@as(usize, 7), parts.len);

    try testing.expectEqualStrings("Part: ", tree.getString(pt.getNode(parts[0]).kind.string));
    try testing.expectEqualStrings("name", tree.getString(pt.getNode(parts[1]).kind.method_call.method_name));
    try testing.expectEqualStrings(" at X:", tree.getString(pt.getNode(parts[2]).kind.string));
    try testing.expectEqual(ast.BinaryOp.add, pt.getNode(parts[3]).kind.binary_op.op);
    try testing.expectEqualStrings(", Y:", tree.getString(pt.getNode(parts[4]).kind.string));
    try testing.expectEqualStrings("y", tree.getString(pt.getNode(parts[5]).kind.method_call.method_name));
    try testing.expectEqualStrings("", tree.getString(pt.getNode(parts[6]).kind.string));
}

test "KupCAD Parser: Module Namespaces with Doc Comments and Class Constructors" {
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
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const mod_node_idx = try pt.parser.parseStatement();
    const mod_node = pt.getNode(mod_node_idx);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).module_stmt, std.meta.activeTag(mod_node.kind));
    try testing.expectEqualStrings("Enclosures", tree.getString(mod_node.kind.module_stmt.name));

    const body_node = pt.getNode(mod_node.kind.module_stmt.body);
    const block_stmts = tree.getNodes(body_node.kind.block.stmts);
    try testing.expectEqual(@as(usize, 2), block_stmts.len);

    // Statement 0: Doc Comment
    const doc_node = pt.getNode(block_stmts[0]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).param_doc, std.meta.activeTag(doc_node.kind));
    const doc = tree.param_docs.items[doc_node.kind.param_doc];
    try testing.expectEqualStrings("param", tree.getString(doc.tag_name));
    try testing.expectEqualStrings("wall_thickness", tree.getString(doc.target_name));
    try testing.expectEqualStrings("Length", tree.getString(doc.type_name));
    try testing.expectEqualStrings("Thickness of enclosure walls", tree.getString(doc.description));

    // Statement 1: Class Statement
    const class_stmt = pt.getNode(block_stmts[1]);
    try testing.expectEqualStrings("Box", tree.getString(pt.getNode(class_stmt.kind.class_stmt.name).kind.identifier));
    try testing.expectEqualStrings("Base", tree.getString(pt.getNode(class_stmt.kind.class_stmt.super_class).kind.identifier));

    const class_body = pt.getNode(class_stmt.kind.class_stmt.body);
    const class_stmts = tree.getNodes(class_body.kind.block.stmts);
    const init_def = pt.getNode(class_stmts[0]);
    try testing.expectEqualStrings("initialize", tree.getString(init_def.kind.def_stmt.name));

    const init_params = tree.getParams(init_def.kind.def_stmt.params);
    try testing.expectEqualStrings("w", tree.getString(init_params[0].name));
    try testing.expectEqual(@as(f64, 100.0), pt.getNode(init_params[0].default_value).kind.number);
}

test "KupCAD Parser: Command-Syntax Calls with Trailing Statement Modifiers" {
    const source = "cube x: 10, y: 20 unless draft_mode?";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.if_stmt.is_unless);
    try testing.expectEqualStrings("draft_mode?", tree.getString(pt.getNode(stmt.kind.if_stmt.condition).kind.identifier));

    const then_branch = pt.getNode(stmt.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const inner_stmt = pt.getNode(then_stmts[0]);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), inner_stmt.kind));
    try testing.expectEqualStrings("cube", tree.getString(inner_stmt.kind.method_call.method_name));

    const args = tree.getNamedArgs(inner_stmt.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), args.len);
}

test "KupCAD Parser: Safe Navigation inside Ternary Conditions and Global Scope Resolution" {
    const source = "target = part&.is_valid? ? part.build() : ::CAD::Default.build()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("target", tree.getString(stmt.kind.assignment.name));

    const ternary = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), ternary.kind));

    // Condition: part&.is_valid?
    const cond = pt.getNode(ternary.kind.ternary_op.condition);
    try testing.expectEqualStrings("is_valid?", tree.getString(cond.kind.method_call.method_name));
    try testing.expectEqual(true, cond.kind.method_call.is_safe);

    // Else branch: ::CAD::Default.build()
    const else_branch = pt.getNode(ternary.kind.ternary_op.else_branch);
    try testing.expectEqualStrings("build", tree.getString(else_branch.kind.method_call.method_name));

    const receiver_ns = pt.getNode(else_branch.kind.method_call.receiver);
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), receiver_ns.kind));

    const path = tree.getStringLists(receiver_ns.kind.namespace_access);
    try testing.expectEqualStrings("CAD", tree.getString(path[0]));
    try testing.expectEqualStrings("Default", tree.getString(path[1]));
}

test "KupCAD Parser: Class Method Definitions with Rescue Blocks" {
    const source =
        \\def self.create(opts = {})
        \\  build(opts)
        \\rescue StandardError => err
        \\  handle_error(err)
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const def_node_idx = try pt.parser.parseStatement();
    const def_node = pt.getNode(def_node_idx);
    try testing.expectEqual(ast.NodeKind.def_stmt, @as(std.meta.Tag(ast.NodeKind), def_node.kind));
    try testing.expectEqual(true, def_node.kind.def_stmt.is_class_method);
    try testing.expectEqualStrings("create", tree.getString(def_node.kind.def_stmt.name));

    // Def body wrapped in begin_stmt due to rescue clause
    const begin_node = pt.getNode(def_node.kind.def_stmt.body);
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), begin_node.kind));

    const rescues = tree.getRescueClauses(begin_node.kind.begin_stmt.rescues);
    const rescue = rescues[0];
    const errors = tree.getStringLists(rescue.errors);
    try testing.expectEqualStrings("StandardError", tree.getString(errors[0]));
    try testing.expectEqualStrings("err", tree.getString(rescue.variable));
}

test "KupCAD Parser: Multi-line Array Destructuring in Method Arguments" {
    const source = "mesh.transform([x, y, z], [10, 20, 30])";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("transform", tree.getString(stmt.kind.method_call.method_name));

    const args = tree.getNamedArgs(stmt.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), args.len);

    const arg0 = pt.getNode(args[0].value);
    const arr1 = tree.getNodes(arg0.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), arr1.len);
    try testing.expectEqualStrings("x", tree.getString(pt.getNode(arr1[0]).kind.identifier));

    const arg1 = pt.getNode(args[1].value);
    const arr2 = tree.getNodes(arg1.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), arr2.len);
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(arr2[0]).kind.number);
}

test "KupCAD Parser: Destructuring with Nested Tuple Patterns" {
    const source = "points.each do |(x, y), index|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const block = pt.getNode(stmt.kind.method_call.block);
    const params = tree.getNodes(block.kind.block.params);
    try testing.expectEqual(@as(usize, 2), params.len);

    const param0 = pt.getNode(params[0]);
    const tuple_param = tree.getNodes(param0.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), tuple_param.len);
    try testing.expectEqualStrings("x", tree.getString(pt.getNode(tuple_param[0]).kind.identifier));
    try testing.expectEqualStrings("y", tree.getString(pt.getNode(tuple_param[1]).kind.identifier));
    try testing.expectEqualStrings("index", tree.getString(pt.getNode(params[1]).kind.identifier));
}

test "KupCAD Parser: Complex Nested Modifier Precedence" {
    const source = "x = y ? true : false unless z == 1";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const root_idx = try pt.parser.parseStatement();
    const root = pt.getNode(root_idx);

    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), root.kind));
    try testing.expectEqual(true, root.kind.if_stmt.is_unless);

    const cond = pt.getNode(root.kind.if_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.equal, cond.kind.binary_op.op);
    try testing.expectEqualStrings("z", tree.getString(pt.getNode(cond.kind.binary_op.left).kind.identifier));

    const then_branch = pt.getNode(root.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const assign = pt.getNode(then_stmts[0]);
    try testing.expectEqualStrings("x", tree.getString(assign.kind.assignment.name));
    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), pt.getNode(assign.kind.assignment.value).kind));
}

test "KupCAD Parser: Global Namespace Property Assignment" {
    const source = "::App::Config.debug_mode = true";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("debug_mode", tree.getString(stmt.kind.property_assignment.property));
    try testing.expectEqual(true, pt.getNode(stmt.kind.property_assignment.value).kind.boolean);

    const target_ns = pt.getNode(stmt.kind.property_assignment.target);
    try testing.expectEqual(ast.NodeKind.namespace_access, @as(std.meta.Tag(ast.NodeKind), target_ns.kind));
    const path = tree.getStringLists(target_ns.kind.namespace_access);
    try testing.expectEqual(@as(usize, 2), path.len);
    try testing.expectEqualStrings("App", tree.getString(path[0]));
    try testing.expectEqualStrings("Config", tree.getString(path[1]));
}

test "KupCAD Parser: Multiple Trailing Safe Navigation Calls" {
    const source = "part&.cut(hole)&.translate(x: 10)&.chamfer()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("chamfer", tree.getString(stmt.kind.method_call.method_name));
    try testing.expectEqual(true, stmt.kind.method_call.is_safe);

    const translate_call = pt.getNode(stmt.kind.method_call.receiver);
    try testing.expectEqualStrings("translate", tree.getString(translate_call.kind.method_call.method_name));
    try testing.expectEqual(true, translate_call.kind.method_call.is_safe);

    const cut_call = pt.getNode(translate_call.kind.method_call.receiver);
    try testing.expectEqualStrings("cut", tree.getString(cut_call.kind.method_call.method_name));
    try testing.expectEqual(true, cut_call.kind.method_call.is_safe);

    const part_ident = pt.getNode(cut_call.kind.method_call.receiver);
    try testing.expectEqualStrings("part", tree.getString(part_ident.kind.identifier));
}

test "KupCAD Parser: Multi-Line Nested Array and Range Expressions" {
    const source =
        \\points = [
        \\  [10, 20],
        \\  0...5,
        \\  [x, y, z]
        \\]
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const arr_node = pt.getNode(stmt.kind.assignment.value);
    const arr = tree.getNodes(arr_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), arr.len);

    const item0 = pt.getNode(arr[0]);
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), item0.kind));
    const item0_elems = tree.getNodes(item0.kind.array_literal);
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(item0_elems[0]).kind.number);

    const item1 = pt.getNode(arr[1]);
    try testing.expectEqual(ast.NodeKind.range, @as(std.meta.Tag(ast.NodeKind), item1.kind));
    try testing.expectEqual(true, item1.kind.range.is_exclusive);

    const item2 = pt.getNode(arr[2]);
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), item2.kind));
    const item2_elems = tree.getNodes(item2.kind.array_literal);
    try testing.expectEqualStrings("x", tree.getString(pt.getNode(item2_elems[0]).kind.identifier));
}

test "KupCAD Parser: Chained Comparisons (Ruby-style Equality)" {
    const source = "a == b and c != d or e >= f";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.BinaryOp.logical_or, stmt.kind.binary_op.op);

    const r_expr = pt.getNode(stmt.kind.binary_op.right);
    try testing.expectEqual(ast.BinaryOp.greater_equal, r_expr.kind.binary_op.op);
    try testing.expectEqualStrings("e", tree.getString(pt.getNode(r_expr.kind.binary_op.left).kind.identifier));
    try testing.expectEqualStrings("f", tree.getString(pt.getNode(r_expr.kind.binary_op.right).kind.identifier));

    const l_expr = pt.getNode(stmt.kind.binary_op.left);
    try testing.expectEqual(ast.BinaryOp.logical_and, l_expr.kind.binary_op.op);
    const l_left = pt.getNode(l_expr.kind.binary_op.left);
    try testing.expectEqual(ast.BinaryOp.equal, l_left.kind.binary_op.op);
    const l_right = pt.getNode(l_expr.kind.binary_op.right);
    try testing.expectEqual(ast.BinaryOp.not_equal, l_right.kind.binary_op.op);
}

test "KupCAD Parser: Return and Next with Multi-value Tuples" {
    const source =
        \\def process
        \\  next 1, 2, 3 if skip?
        \\  return true, "done"
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const def_node_idx = try pt.parser.parseStatement();
    const def_node = pt.getNode(def_node_idx);
    const body_node = pt.getNode(def_node.kind.def_stmt.body);
    const stmts = tree.getNodes(body_node.kind.block.stmts);

    const if_node = pt.getNode(stmts[0]);
    try testing.expectEqualStrings("skip?", tree.getString(pt.getNode(if_node.kind.if_stmt.condition).kind.identifier));

    const then_branch = pt.getNode(if_node.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const next_node = pt.getNode(then_stmts[0]);

    const next_vals_node = pt.getNode(next_node.kind.next_stmt);
    const next_vals = tree.getNodes(next_vals_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), next_vals.len);
    try testing.expectEqual(@as(f64, 2.0), pt.getNode(next_vals[1]).kind.number);

    const ret_node = pt.getNode(stmts[1]);
    const ret_vals_node = pt.getNode(ret_node.kind.return_stmt);
    const ret_vals = tree.getNodes(ret_vals_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), ret_vals.len);
    try testing.expectEqual(true, pt.getNode(ret_vals[0]).kind.boolean);
    try testing.expectEqualStrings("done", tree.getString(pt.getNode(ret_vals[1]).kind.string));
}

test "KupCAD Parser: Property and Index Assignment Interactions" {
    const source = "config.sections[0].name = \"Top\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("name", tree.getString(stmt.kind.property_assignment.property));
    try testing.expectEqualStrings("Top", tree.getString(pt.getNode(stmt.kind.property_assignment.value).kind.string));

    const target = pt.getNode(stmt.kind.property_assignment.target);
    try testing.expectEqual(ast.NodeKind.index_access, @as(std.meta.Tag(ast.NodeKind), target.kind));
    try testing.expectEqual(@as(f64, 0.0), pt.getNode(target.kind.index_access.index).kind.number);

    const access_target = pt.getNode(target.kind.index_access.target);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), access_target.kind));
    try testing.expectEqualStrings("sections", tree.getString(access_target.kind.method_call.method_name));
    try testing.expectEqualStrings("config", tree.getString(pt.getNode(access_target.kind.method_call.receiver).kind.identifier));
}

test "KupCAD Parser: Multiple Sequential Rescue Clauses" {
    const source =
        \\begin
        \\  calc()
        \\rescue MathError, DivByZero => e
        \\  1
        \\rescue => fallback
        \\  2
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const node_idx = try pt.parser.parseStatement();
    const node = pt.getNode(node_idx);
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), node.kind));

    const rescues = tree.getRescueClauses(node.kind.begin_stmt.rescues);
    try testing.expectEqual(@as(usize, 2), rescues.len);

    // First rescue
    const r0_errors = tree.getStringLists(rescues[0].errors);
    try testing.expectEqual(@as(usize, 2), r0_errors.len);
    try testing.expectEqualStrings("MathError", tree.getString(r0_errors[0]));
    try testing.expectEqualStrings("DivByZero", tree.getString(r0_errors[1]));
    try testing.expectEqualStrings("e", tree.getString(rescues[0].variable));

    const r0_body = pt.getNode(rescues[0].body);
    const r0_stmts = tree.getNodes(r0_body.kind.block.stmts);
    try testing.expectEqual(@as(f64, 1.0), pt.getNode(r0_stmts[0]).kind.number);

    // Second rescue (catch-all)
    const r1_errors = tree.getStringLists(rescues[1].errors);
    try testing.expectEqual(@as(usize, 0), r1_errors.len);
    try testing.expectEqualStrings("fallback", tree.getString(rescues[1].variable));

    const r1_body = pt.getNode(rescues[1].body);
    const r1_stmts = tree.getNodes(r1_body.kind.block.stmts);
    try testing.expectEqual(@as(f64, 2.0), pt.getNode(r1_stmts[0]).kind.number);
}

test "KupCAD Parser: Trailing Modifiers on Compound Begin/End Blocks" {
    const source =
        \\begin
        \\  step()
        \\end until done?
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqual(true, stmt.kind.while_stmt.is_until);
    try testing.expectEqualStrings("done?", tree.getString(pt.getNode(stmt.kind.while_stmt.condition).kind.identifier));

    const body_node = pt.getNode(stmt.kind.while_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    const wrapped_begin = pt.getNode(body_stmts[0]);
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), wrapped_begin.kind));

    const begin_body = pt.getNode(wrapped_begin.kind.begin_stmt.body);
    const begin_stmts = tree.getNodes(begin_body.kind.block.stmts);
    try testing.expectEqualStrings("step", tree.getString(pt.getNode(begin_stmts[0]).kind.method_call.method_name));
}

test "KupCAD Parser: Global and Instance Variable Assignments" {
    const source =
        \\@width = 10
        \\$offset = @width * 2
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const s1_idx = try pt.parser.parseStatement();
    const s1 = pt.getNode(s1_idx);
    try testing.expectEqualStrings("@width", tree.getString(s1.kind.assignment.name));

    const s2_idx = try pt.parser.parseStatement();
    const s2 = pt.getNode(s2_idx);
    try testing.expectEqualStrings("$offset", tree.getString(s2.kind.assignment.name));

    const s2_val = pt.getNode(s2.kind.assignment.value);
    try testing.expectEqualStrings("@width", tree.getString(pt.getNode(s2_val.kind.binary_op.left).kind.identifier));
}

test "KupCAD Parser: Empty Literals and Blocks" {
    const source =
        \\arr = []
        \\obj = {}
        \\run do
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const s1_idx = try pt.parser.parseStatement();
    const s1 = pt.getNode(s1_idx);
    const arr_node = pt.getNode(s1.kind.assignment.value);
    const arr_elems = tree.getNodes(arr_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 0), arr_elems.len);

    const s2_idx = try pt.parser.parseStatement();
    const s2 = pt.getNode(s2_idx);
    const hash_node = pt.getNode(s2.kind.assignment.value);
    const hash_entries = tree.getHashEntries(hash_node.kind.hash_literal);
    try testing.expectEqual(@as(usize, 0), hash_entries.len);

    const s3_idx = try pt.parser.parseStatement();
    const s3 = pt.getNode(s3_idx);
    try testing.expectEqualStrings("run", tree.getString(s3.kind.method_call.method_name));

    const block = pt.getNode(s3.kind.method_call.block);
    const block_stmts = tree.getNodes(block.kind.block.stmts);
    try testing.expectEqual(@as(usize, 0), block_stmts.len);
}

test "KupCAD Parser: Method Calls on Array and Hash Literals" {
    const source =
        \\arr_max = [1, 2, 3].max
        \\hash_keys = { a: 1 }.keys()
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    // arr_max = [1, 2, 3].max
    const stmt1_idx = try pt.parser.parseStatement();
    const stmt1 = pt.getNode(stmt1_idx);
    try testing.expectEqualStrings("arr_max", tree.getString(stmt1.kind.assignment.name));

    const call1 = pt.getNode(stmt1.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), call1.kind));
    try testing.expectEqualStrings("max", tree.getString(call1.kind.method_call.method_name));

    const receiver1 = pt.getNode(call1.kind.method_call.receiver);
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), receiver1.kind));
    const rec1_elems = tree.getNodes(receiver1.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), rec1_elems.len);
    try testing.expectEqual(@as(f64, 1.0), pt.getNode(rec1_elems[0]).kind.number);

    // hash_keys = { a: 1 }.keys()
    const stmt2_idx = try pt.parser.parseStatement();
    const stmt2 = pt.getNode(stmt2_idx);
    try testing.expectEqualStrings("hash_keys", tree.getString(stmt2.kind.assignment.name));

    const call2 = pt.getNode(stmt2.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), call2.kind));
    try testing.expectEqualStrings("keys", tree.getString(call2.kind.method_call.method_name));

    const receiver2 = pt.getNode(call2.kind.method_call.receiver);
    try testing.expectEqual(ast.NodeKind.hash_literal, @as(std.meta.Tag(ast.NodeKind), receiver2.kind));
    const rec2_entries = tree.getHashEntries(receiver2.kind.hash_literal);
    try testing.expectEqual(@as(usize, 1), rec2_entries.len);
    try testing.expectEqualStrings("a", tree.getString(pt.getNode(rec2_entries[0].key).kind.symbol));
}

test "KupCAD Parser: Diagnostics Line and Column Tracking" {
    const source =
        \\def build()
        \\  x = 10 + }
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    _ = try pt.parser.parseStatement();
    try testing.expectEqual(@as(usize, 1), pt.parser.diagnostics.list.items.len);
    const diag = pt.parser.diagnostics.list.items[0];

    try testing.expectEqualStrings("Invalid expression starting with '}'", diag.message);
    try testing.expectEqual(@as(u32, 2), diag.loc.line);
    try testing.expectEqual(@as(u32, 12), diag.loc.col);
}

test "KupCAD Parser: Empty Class and Module Declarations" {
    const source =
        \\module Math
        \\end
        \\class Vector
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const mod_stmt_idx = try pt.parser.parseStatement();
    const mod_stmt = pt.getNode(mod_stmt_idx);
    try testing.expectEqual(ast.NodeKind.module_stmt, @as(std.meta.Tag(ast.NodeKind), mod_stmt.kind));
    try testing.expectEqualStrings("Math", tree.getString(mod_stmt.kind.module_stmt.name));

    const mod_body = pt.getNode(mod_stmt.kind.module_stmt.body);
    const mod_stmts = tree.getNodes(mod_body.kind.block.stmts);
    try testing.expectEqual(@as(usize, 0), mod_stmts.len);

    const class_stmt_idx = try pt.parser.parseStatement();
    const class_stmt = pt.getNode(class_stmt_idx);
    try testing.expectEqual(ast.NodeKind.class_stmt, @as(std.meta.Tag(ast.NodeKind), class_stmt.kind));
    try testing.expectEqualStrings("Vector", tree.getString(pt.getNode(class_stmt.kind.class_stmt.name).kind.identifier));

    const class_body = pt.getNode(class_stmt.kind.class_stmt.body);
    const class_stmts = tree.getNodes(class_body.kind.block.stmts);
    try testing.expectEqual(@as(usize, 0), class_stmts.len);
}

test "KupCAD Parser: Block Passing in Property Assignment" {
    const source =
        \\model.callback = ->(event) do
        \\  log(event)
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("callback", tree.getString(stmt.kind.property_assignment.property));

    const lambda = pt.getNode(stmt.kind.property_assignment.value);
    try testing.expectEqual(ast.NodeKind.lambda_expr, @as(std.meta.Tag(ast.NodeKind), lambda.kind));

    const params = tree.getParams(lambda.kind.lambda_expr.params);
    try testing.expectEqualStrings("event", tree.getString(params[0].name));

    const lambda_body = pt.getNode(lambda.kind.lambda_expr.body);
    const lambda_stmts = tree.getNodes(lambda_body.kind.block.stmts);
    const call_node = pt.getNode(lambda_stmts[0]);
    try testing.expectEqualStrings("log", tree.getString(call_node.kind.method_call.method_name));
}

test "KupCAD Parser: Naked Return Statement (No Arguments)" {
    const source =
        \\def validate
        \\  return if !ready
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    const def_body = pt.getNode(stmt.kind.def_stmt.body);
    const def_stmts = tree.getNodes(def_body.kind.block.stmts);
    const body_stmt = pt.getNode(def_stmts[0]);
    try testing.expectEqual(ast.NodeKind.if_stmt, @as(std.meta.Tag(ast.NodeKind), body_stmt.kind));

    const then_branch = pt.getNode(body_stmt.kind.if_stmt.then_branch);
    const then_stmts = tree.getNodes(then_branch.kind.block.stmts);
    const ret_stmt = pt.getNode(then_stmts[0]);
    try testing.expectEqual(ast.NodeKind.return_stmt, @as(std.meta.Tag(ast.NodeKind), ret_stmt.kind));
    try testing.expectEqual(ast.NodeIndex.none, ret_stmt.kind.return_stmt);
}

test "KupCAD Parser: Inline Array/Hash Creation within Command Arguments" {
    const source = "extrude [0, 0, 10], opts: { twist: 360 }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("extrude", tree.getString(stmt.kind.method_call.method_name));

    const args = tree.getNamedArgs(stmt.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), args.len);

    // Arg 1 is Array
    const arg0 = pt.getNode(args[0].value);
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), arg0.kind));
    const arg0_elems = tree.getNodes(arg0.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), arg0_elems.len);

    // Arg 2 is Hash
    try testing.expectEqualStrings("opts", tree.getString(args[1].name));
    const arg1 = pt.getNode(args[1].value);
    try testing.expectEqual(ast.NodeKind.hash_literal, @as(std.meta.Tag(ast.NodeKind), arg1.kind));
    const arg1_entries = tree.getHashEntries(arg1.kind.hash_literal);
    try testing.expectEqualStrings("twist", tree.getString(pt.getNode(arg1_entries[0].key).kind.symbol));
}

test "KupCAD Parser: Multiple Comma-Separated Conditions in 'When' Clauses" {
    const source =
        \\case type
        \\when :hex, :square, :round
        \\  extrude(5)
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const branches = tree.getWhenBranches(stmt.kind.case_stmt.when_branches);
    try testing.expectEqual(@as(usize, 1), branches.len);

    const conditions = tree.getNodes(branches[0].conditions);
    try testing.expectEqual(@as(usize, 3), conditions.len);
    try testing.expectEqualStrings("hex", tree.getString(pt.getNode(conditions[0]).kind.symbol));
    try testing.expectEqualStrings("square", tree.getString(pt.getNode(conditions[1]).kind.symbol));
    try testing.expectEqualStrings("round", tree.getString(pt.getNode(conditions[2]).kind.symbol));
}

test "KupCAD Parser: Parenthesis-less Method Definitions" {
    const source =
        \\def build width, height: 10
        \\  cube()
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const def_node = stmt.kind.def_stmt;
    try testing.expectEqualStrings("build", tree.getString(def_node.name));

    const params = tree.getParams(def_node.params);
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("width", tree.getString(params[0].name));
    try testing.expectEqualStrings("height", tree.getString(params[1].name));
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(params[1].default_value).kind.number);
}

test "KupCAD Parser: Multiline Command Arguments" {
    const source =
        \\translate x: 10,
        \\          y: 20 do
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const call = stmt.kind.method_call;
    try testing.expectEqualStrings("translate", tree.getString(call.method_name));

    const args = tree.getNamedArgs(call.args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("y", tree.getString(args[1].name));
}

test "KupCAD Parser: Error Recovery (synchronize)" {
    const source =
        \\x = 10 + }
        \\y = 20 * ]
        \\z = 30
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const result_idx = try pt.parser.parseProgram();
    const result = pt.getNode(result_idx);
    const stmts = tree.getNodes(result.kind.block.stmts);
    try testing.expectEqual(@as(usize, 1), stmts.len);

    const valid_stmt = pt.getNode(stmts[0]);
    try testing.expectEqualStrings("z", tree.getString(valid_stmt.kind.assignment.name));
    try testing.expectEqual(@as(usize, 2), pt.parser.diagnostics.list.items.len);
}

test "KupCAD Parser: Nested String Interpolation AST" {
    const source = "\"Outer #{ \"Inner #{1 + 2}\" } end\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const outer_parts = tree.getNodes(stmt.kind.interpolated_string);
    try testing.expectEqualStrings("Outer ", tree.getString(pt.getNode(outer_parts[0]).kind.string));

    const inner_node = pt.getNode(outer_parts[1]);
    try testing.expectEqual(ast.NodeKind.interpolated_string, @as(std.meta.Tag(ast.NodeKind), inner_node.kind));

    const inner_parts = tree.getNodes(inner_node.kind.interpolated_string);
    try testing.expectEqualStrings("Inner ", tree.getString(pt.getNode(inner_parts[0]).kind.string));
    try testing.expectEqual(ast.BinaryOp.add, pt.getNode(inner_parts[1]).kind.binary_op.op);
    try testing.expectEqualStrings("", tree.getString(pt.getNode(inner_parts[2]).kind.string));
    try testing.expectEqualStrings(" end", tree.getString(pt.getNode(outer_parts[2]).kind.string));
}

test "KupCAD Parser: Begin Block as Expression" {
    const source =
        \\val = begin
        \\  calc()
        \\rescue
        \\  0
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("val", tree.getString(stmt.kind.assignment.name));

    const begin_expr = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.begin_stmt, @as(std.meta.Tag(ast.NodeKind), begin_expr.kind));

    const rescues = tree.getRescueClauses(begin_expr.kind.begin_stmt.rescues);
    try testing.expectEqual(@as(usize, 1), rescues.len);
}

test "KupCAD Parser: Single-line Case When with 'then'" {
    const source =
        \\case type
        \\when 1 then cube()
        \\when 2 then sphere()
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const branches = tree.getWhenBranches(stmt.kind.case_stmt.when_branches);
    try testing.expectEqual(@as(usize, 2), branches.len);

    const branch0_body = pt.getNode(branches[0].body);
    const b0_stmts = tree.getNodes(branch0_body.kind.block.stmts);
    const call0 = pt.getNode(b0_stmts[0]);
    try testing.expectEqualStrings("cube", tree.getString(call0.kind.method_call.method_name));

    const branch1_body = pt.getNode(branches[1].body);
    const b1_stmts = tree.getNodes(branch1_body.kind.block.stmts);
    const call1 = pt.getNode(b1_stmts[0]);
    try testing.expectEqualStrings("sphere", tree.getString(call1.kind.method_call.method_name));
}

test "KupCAD Parser: Top-Level Method Call with Parens and Block" {
    const source =
        \\grid(2, 2) do |x, y|
        \\  cube()
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.method_call, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("grid", tree.getString(stmt.kind.method_call.method_name));

    const args = tree.getNamedArgs(stmt.kind.method_call.args);
    try testing.expectEqual(@as(usize, 2), args.len);

    const block = pt.getNode(stmt.kind.method_call.block);
    const params = tree.getNodes(block.kind.block.params);
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("x", tree.getString(pt.getNode(params[0]).kind.identifier));
}

test "KupCAD Parser: Multi-Assignment with Raw Comma Values" {
    const source = "x, y = 10, 20";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.NodeKind.multiple_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));

    const val_node = pt.getNode(stmt.kind.multiple_assignment.value);
    const rhs_array = tree.getNodes(val_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), rhs_array.len);
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(rhs_array[0]).kind.number);
    try testing.expectEqual(@as(f64, 20.0), pt.getNode(rhs_array[1]).kind.number);
}

test "KupCAD Parser: Implicit RHS Array on Single Assignment" {
    const source =
        \\coords = 10, 20, 30
        \\points[0] = 5, 5
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    // Verify `coords = 10, 20, 30`
    const stmt1_idx = try pt.parser.parseStatement();
    const stmt1 = pt.getNode(stmt1_idx);
    const rhs_arr1_node = pt.getNode(stmt1.kind.assignment.value);
    const rhs_arr1 = tree.getNodes(rhs_arr1_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), rhs_arr1.len);
    try testing.expectEqual(@as(f64, 30.0), pt.getNode(rhs_arr1[2]).kind.number);

    // Verify `points[0] = 5, 5`
    const stmt2_idx = try pt.parser.parseStatement();
    const stmt2 = pt.getNode(stmt2_idx);
    const rhs_arr2_node = pt.getNode(stmt2.kind.index_assignment.value);
    const rhs_arr2 = tree.getNodes(rhs_arr2_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), rhs_arr2.len);
    try testing.expectEqual(@as(f64, 5.0), pt.getNode(rhs_arr2[1]).kind.number);
}

test "KupCAD Parser: Multi-Dimensional Array Indexing" {
    const source = "val = matrix[x, y]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const index_node = pt.getNode(stmt.kind.assignment.value);

    try testing.expectEqual(ast.NodeKind.index_access, @as(std.meta.Tag(ast.NodeKind), index_node.kind));

    const index_args_node = pt.getNode(index_node.kind.index_access.index);
    const index_args = tree.getNodes(index_args_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), index_args.len);
    try testing.expectEqualStrings("x", tree.getString(pt.getNode(index_args[0]).kind.identifier));
    try testing.expectEqualStrings("y", tree.getString(pt.getNode(index_args[1]).kind.identifier));
}

test "KupCAD Parser: Empty Parentheses evaluate to Nil" {
    const source = "call() do\n ()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    const block_node = pt.getNode(stmt.kind.method_call.block);
    const block_stmts = tree.getNodes(block_node.kind.block.stmts);
    const block_stmt = pt.getNode(block_stmts[0]);

    try testing.expectEqual(ast.NodeKind.nil, @as(std.meta.Tag(ast.NodeKind), block_stmt.kind));
}

test "KupCAD Parser: Chained and Compound Assignment Right-Associativity" {
    const source1 = "a = b = c = 10";
    var pt1 = try KTest.init(source1);
    defer pt1.deinit();
    const tree1 = &pt1.parser.b.tree;

    const stmt1_idx = try pt1.parser.parseStatement();
    const stmt1 = pt1.getNode(stmt1_idx);

    try testing.expectEqualStrings("a", tree1.getString(stmt1.kind.assignment.name));
    const assign_b = pt1.getNode(stmt1.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), assign_b.kind));
    try testing.expectEqualStrings("b", tree1.getString(assign_b.kind.assignment.name));

    const assign_c = pt1.getNode(assign_b.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), assign_c.kind));
    try testing.expectEqualStrings("c", tree1.getString(assign_c.kind.assignment.name));
    try testing.expectEqual(@as(f64, 10.0), pt1.getNode(assign_c.kind.assignment.value).kind.number);

    const source2 = "x += y += 5";
    var pt2 = try KTest.init(source2);
    defer pt2.deinit();
    const tree2 = &pt2.parser.b.tree;

    const stmt2_idx = try pt2.parser.parseStatement();
    const stmt2 = pt2.getNode(stmt2_idx);

    try testing.expectEqualStrings("x", tree2.getString(stmt2.kind.assignment.name));
    try testing.expectEqual(ast.BinaryOp.add, stmt2.kind.assignment.op.?);

    const assign_y = pt2.getNode(stmt2.kind.assignment.value);
    try testing.expectEqual(ast.BinaryOp.add, assign_y.kind.assignment.op.?);
    try testing.expectEqualStrings("y", tree2.getString(assign_y.kind.assignment.name));
    try testing.expectEqual(@as(f64, 5.0), pt2.getNode(assign_y.kind.assignment.value).kind.number);
}

test "KupCAD Parser: Nested Ternary Right-Associativity" {
    const source = "a ? b : c ? d : e";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);

    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), expr.kind));
    try testing.expectEqualStrings("a", tree.getString(pt.getNode(expr.kind.ternary_op.condition).kind.identifier));
    try testing.expectEqualStrings("b", tree.getString(pt.getNode(expr.kind.ternary_op.then_branch).kind.identifier));

    const else_ternary = pt.getNode(expr.kind.ternary_op.else_branch);
    try testing.expectEqual(ast.NodeKind.ternary_op, @as(std.meta.Tag(ast.NodeKind), else_ternary.kind));
    try testing.expectEqualStrings("c", tree.getString(pt.getNode(else_ternary.kind.ternary_op.condition).kind.identifier));
    try testing.expectEqualStrings("d", tree.getString(pt.getNode(else_ternary.kind.ternary_op.then_branch).kind.identifier));
    try testing.expectEqualStrings("e", tree.getString(pt.getNode(else_ternary.kind.ternary_op.else_branch).kind.identifier));
}

test "KupCAD Parser: Multiple Unary Prefix Right-Associativity" {
    const source = "!!true";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);

    try testing.expectEqual(ast.UnaryOp.not, expr.kind.unary_op.op);
    const inner_not = pt.getNode(expr.kind.unary_op.operand);
    try testing.expectEqual(ast.UnaryOp.not, inner_not.kind.unary_op.op);
    try testing.expectEqual(true, pt.getNode(inner_not.kind.unary_op.operand).kind.boolean);
}

test "KupCAD Parser: Ruby 3.1 Shorthand Hash Syntax" {
    const source = "opts = { width:, height: }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    const hash_node = pt.getNode(stmt.kind.assignment.value);
    const hash = tree.getHashEntries(hash_node.kind.hash_literal);
    try testing.expectEqual(@as(usize, 2), hash.len);

    try testing.expectEqualStrings("width", tree.getString(pt.getNode(hash[0].key).kind.symbol));
    try testing.expectEqualStrings("width", tree.getString(pt.getNode(hash[0].value).kind.identifier));

    try testing.expectEqualStrings("height", tree.getString(pt.getNode(hash[1].key).kind.symbol));
    try testing.expectEqualStrings("height", tree.getString(pt.getNode(hash[1].value).kind.identifier));
}

test "KupCAD Parser: Multi-line Indented Docstring Tag Node" {
    const source =
        \\# @deprecated Use {#my_new_method} instead of this method because
        \\#   it uses a library that is no longer supported.
        \\def mymethod
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const doc_stmt1_idx = try pt.parser.parseStatement();
    const doc_stmt1 = pt.getNode(doc_stmt1_idx);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).param_doc, std.meta.activeTag(doc_stmt1.kind));
    const doc = tree.param_docs.items[doc_stmt1.kind.param_doc];

    try testing.expectEqualStrings("deprecated", tree.getString(doc.tag_name));
    try testing.expectEqual(ast.StringId.none, doc.target_name);
    try testing.expectEqual(ast.StringId.none, doc.type_name);
    try testing.expectEqualStrings("Use {#my_new_method} instead of this method because\nit uses a library that is no longer supported.", tree.getString(doc.description));

    const def_stmt_idx = try pt.parser.parseStatement();
    const def_stmt = pt.getNode(def_stmt_idx);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).def_stmt, std.meta.activeTag(def_stmt.kind));
    try testing.expectEqualStrings("mymethod", tree.getString(def_stmt.kind.def_stmt.name));
}

test "KupCAD Parser: AST Node offset and length calculation for LSP" {
    const source = "val = 10 + 200";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(std.meta.Tag(ast.NodeKind).assignment, std.meta.activeTag(stmt.kind));
    try testing.expectEqual(@as(u32, 0), stmt.loc.offset);
    try testing.expectEqual(@as(u32, 14), stmt.loc.length);

    const bin_expr = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).binary_op, std.meta.activeTag(bin_expr.kind));
    try testing.expectEqual(@as(u32, 6), bin_expr.loc.offset);
    try testing.expectEqual(@as(u32, 8), bin_expr.loc.length);

    const left_num = pt.getNode(bin_expr.kind.binary_op.left);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).number, std.meta.activeTag(left_num.kind));
    try testing.expectEqual(@as(u32, 6), left_num.loc.offset);
    try testing.expectEqual(@as(u32, 2), left_num.loc.length);

    const right_num = pt.getNode(bin_expr.kind.binary_op.right);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).number, std.meta.activeTag(right_num.kind));
    try testing.expectEqual(@as(u32, 11), right_num.loc.offset);
    try testing.expectEqual(@as(u32, 3), right_num.loc.length);
}

test "KupCAD Parser: Compound Node Spans and Comment Side-Table Extraction" {
    const source =
        "def calculate(a)\n" ++
        "  # a comment\n" ++
        "  a * 2\n" ++
        "end";

    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(std.meta.Tag(ast.NodeKind).def_stmt, std.meta.activeTag(stmt.kind));
    try testing.expectEqual(@as(u32, 0), stmt.loc.offset);
    try testing.expectEqual(@as(u32, 42), stmt.loc.length);

    const body_node = pt.getNode(stmt.kind.def_stmt.body);
    const body_stmts = tree.getNodes(body_node.kind.block.stmts);
    try testing.expectEqual(@as(usize, 1), body_stmts.len);

    const math_expr = pt.getNode(body_stmts[0]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).binary_op, std.meta.activeTag(math_expr.kind));
    try testing.expectEqual(@as(u32, 33), math_expr.loc.offset);
    try testing.expectEqual(@as(u32, 5), math_expr.loc.length);

    try testing.expectEqual(@as(usize, 1), pt.parser.comments.items.len);
    const captured_comment = pt.parser.comments.items[0];
    try testing.expectEqualStrings("# a comment", captured_comment.lexeme);
    try testing.expectEqual(@as(u32, 2), captured_comment.loc.line);
    try testing.expectEqual(@as(u32, 19), captured_comment.loc.offset);
}

test "KupCAD Parser: Standard Block While and Until Loops" {
    const source =
        \\while x < 10
        \\  x += 1
        \\end
        \\until y > 10
        \\  y -= 1
        \\end
    ;

    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const while_stmt_idx = try pt.parser.parseStatement();
    const while_stmt = pt.getNode(while_stmt_idx);
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), while_stmt.kind));
    try testing.expectEqual(false, while_stmt.kind.while_stmt.is_until);

    const while_body = pt.getNode(while_stmt.kind.while_stmt.body);
    const while_stmts = tree.getNodes(while_body.kind.block.stmts);
    const while_assign = pt.getNode(while_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.add, while_assign.kind.assignment.op.?);

    const until_stmt_idx = try pt.parser.parseStatement();
    const until_stmt = pt.getNode(until_stmt_idx);
    try testing.expectEqual(ast.NodeKind.while_stmt, @as(std.meta.Tag(ast.NodeKind), until_stmt.kind));
    try testing.expectEqual(true, until_stmt.kind.while_stmt.is_until);

    const until_body = pt.getNode(until_stmt.kind.while_stmt.body);
    const until_stmts = tree.getNodes(until_body.kind.block.stmts);
    const until_assign = pt.getNode(until_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.subtract, until_assign.kind.assignment.op.?);
}

test "KupCAD Parser: Index Compound Assignment" {
    const source = "arr[0] *= 5";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.NodeKind.index_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("arr", tree.getString(pt.getNode(stmt.kind.index_assignment.target).kind.identifier));
    try testing.expectEqual(@as(f64, 0.0), pt.getNode(stmt.kind.index_assignment.index).kind.number);
    try testing.expectEqual(ast.BinaryOp.multiply, stmt.kind.index_assignment.op.?);
    try testing.expectEqual(@as(f64, 5.0), pt.getNode(stmt.kind.index_assignment.value).kind.number);
}

test "KupCAD Parser: Property Compound Assignment" {
    const source = "obj.x += 10";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.NodeKind.property_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("obj", tree.getString(pt.getNode(stmt.kind.property_assignment.target).kind.identifier));
    try testing.expectEqualStrings("x", tree.getString(stmt.kind.property_assignment.property));
    try testing.expectEqual(ast.BinaryOp.add, stmt.kind.property_assignment.op.?);
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(stmt.kind.property_assignment.value).kind.number);
}

test "KupCAD Parser: Strict Index Assignment Rejects Spaces" {
    const source = "arr [ 0 ] *= 5";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const result = pt.parser.parseStatement();

    try testing.expectError(error.InvalidExpression, result);
    try testing.expectEqual(@as(usize, 1), pt.parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Invalid expression starting with '*='", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Ignore trailing comments on binary operations and calls" {
    const source =
        \\part - part # Should trigger CSG self-subtraction warning
        \\cube() # Trailing comment on method call
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const p1 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.BinaryOp.subtract, p1.kind.binary_op.op);
    try testing.expectEqualStrings("part", tree.getString(pt.getNode(p1.kind.binary_op.left).kind.identifier));
    try testing.expectEqualStrings("part", tree.getString(pt.getNode(p1.kind.binary_op.right).kind.identifier));

    const p2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("cube", tree.getString(p2.kind.method_call.method_name));

    try testing.expectEqual(@as(usize, 0), pt.parser.diagnostics.list.items.len);
}

test "KupCAD Parser: Deeply Nested String Interpolation gracefully fails" {
    const source = "\"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"deep\" }\" }\" }\" }\" }\" }\" }\" }\" }\"";

    var pt = try KTest.init(source);
    defer pt.deinit();

    const result = pt.parser.parseExpression(.none);

    try testing.expectError(error.InvalidExpression, result);
    try testing.expect(pt.parser.diagnostics.list.items.len > 0);
    try testing.expectEqualStrings("Invalid expression starting with 'Interpolation depth exceeded'", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Trailing commas in multiple assignment" {
    const source = "x, y, = 10, 20";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.NodeKind.multiple_assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    const lhs = tree.getLhsExprs(stmt.kind.multiple_assignment.lhs);

    try testing.expectEqual(@as(usize, 2), lhs.len);
    try testing.expectEqualStrings("x", tree.getString(lhs[0].name));
    try testing.expectEqualStrings("y", tree.getString(lhs[1].name));

    const rhs_val = pt.getNode(stmt.kind.multiple_assignment.value);
    const rhs_array = tree.getNodes(rhs_val.kind.array_literal);
    try testing.expectEqual(@as(usize, 2), rhs_array.len);
    try testing.expectEqual(@as(f64, 10.0), pt.getNode(rhs_array[0]).kind.number);
    try testing.expectEqual(@as(f64, 20.0), pt.getNode(rhs_array[1]).kind.number);
}

test "KupCAD Parser: Deep recursion safety (Stack Overflow Prevention)" {
    const depth: usize = 200;
    var source_buf = std.ArrayListUnmanaged(u8).empty;
    defer source_buf.deinit(testing.allocator);

    for (0..depth) |_| try source_buf.append(testing.allocator, '(');
    try source_buf.appendSlice(testing.allocator, "1");
    for (0..depth) |_| try source_buf.append(testing.allocator, ')');

    var pt = try KTest.init(source_buf.items);
    defer pt.deinit();

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);

    try testing.expectEqual(std.meta.Tag(ast.NodeKind).number, std.meta.activeTag(expr.kind));
    try testing.expectEqual(@as(f64, 1.0), expr.kind.number);
}

test "KupCAD Parser: Right-Associative Assignment Chaining" {
    var pt = try KTest.init("a = b = c = 1");
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), stmt.kind));
    try testing.expectEqualStrings("a", tree.getString(stmt.kind.assignment.name));

    const b_assign = pt.getNode(stmt.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), b_assign.kind));
    try testing.expectEqualStrings("b", tree.getString(b_assign.kind.assignment.name));

    const c_assign = pt.getNode(b_assign.kind.assignment.value);
    try testing.expectEqual(ast.NodeKind.assignment, @as(std.meta.Tag(ast.NodeKind), c_assign.kind));
    try testing.expectEqualStrings("c", tree.getString(c_assign.kind.assignment.name));

    try testing.expectEqual(@as(f64, 1.0), pt.getNode(c_assign.kind.assignment.value).kind.number);
}

test "KupCAD Parser: Empty Arrays and Hashes" {
    var pt = try KTest.init("[]\n{}");
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const arr_idx = try pt.parser.parseStatement();
    const arr = pt.getNode(arr_idx);
    try testing.expectEqual(ast.NodeKind.array_literal, @as(std.meta.Tag(ast.NodeKind), arr.kind));
    try testing.expectEqual(@as(usize, 0), tree.getNodes(arr.kind.array_literal).len);

    const hash_idx = try pt.parser.parseStatement();
    const hash = pt.getNode(hash_idx);
    try testing.expectEqual(ast.NodeKind.hash_literal, @as(std.meta.Tag(ast.NodeKind), hash.kind));
    try testing.expectEqual(@as(usize, 0), tree.getHashEntries(hash.kind.hash_literal).len);
}
