const std = @import("std");
const testing = std.testing;
const ast = @import("../../core/ast.zig");
const ParserTest = @import("../test_utils.zig").ParserTest;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const KTest = ParserTest(Lexer, Parser);

test "AST Node Memory Size Optimization" {
    // Ensures the Node stays at exactly 8 bytes for cache locality
    try testing.expectEqual(@as(usize, 8), @sizeOf(ast.Node));
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
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    const bin_stmt = tree.binaryExpr(stmt);

    try testing.expectEqual(ast.BinaryOp.add, bin_stmt.op);
    const left = pt.getNode(bin_stmt.left);
    try testing.expectEqual(@as(f64, 1.0), tree.number(left));

    const right = pt.getNode(bin_stmt.right);
    const bin_right = tree.binaryExpr(right);
    try testing.expectEqual(ast.BinaryOp.multiply, bin_right.op);

    const r_left = pt.getNode(bin_right.left);
    try testing.expectEqual(@as(f64, 2.0), tree.number(r_left));

    const r_right = pt.getNode(bin_right.right);
    try testing.expectEqual(@as(f64, 3.0), tree.number(r_right));
}

test "KupCAD Parser: Right Associativity for Exponentiation (**)" {
    var pt = try KTest.init("2 ** 3 ** 4");
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    const bin_stmt = tree.binaryExpr(stmt);

    try testing.expectEqual(ast.BinaryOp.exponent, bin_stmt.op);
    const left = pt.getNode(bin_stmt.left);
    try testing.expectEqual(@as(f64, 2.0), tree.number(left));

    const right = pt.getNode(bin_stmt.right);
    const bin_right = tree.binaryExpr(right);
    try testing.expectEqual(ast.BinaryOp.exponent, bin_right.op);

    const r_left = pt.getNode(bin_right.left);
    try testing.expectEqual(@as(f64, 3.0), tree.number(r_left));
}

test "KupCAD Parser: Method Chaining with Named Args" {
    var pt = try KTest.init("Box.new(x: 50).translate(z: 10)");
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    try testing.expectEqualStrings("translate", tree.getString(mc.method_name));
    const args = tree.getNamedArgs(mc.args);
    try testing.expectEqualStrings("z", tree.getString(args[0].name));

    const arg_val = pt.getNode(args[0].value);
    try testing.expectEqual(@as(f64, 10.0), tree.number(arg_val));

    const receiver = pt.getNode(mc.receiver);
    const rec_mc = tree.methodCall(receiver);
    try testing.expectEqualStrings("new", tree.getString(rec_mc.method_name));

    const base_receiver = pt.getNode(rec_mc.receiver);
    try testing.expectEqualStrings("Box", tree.getString(@as(ast.StringId, @enumFromInt(base_receiver.data))));
}

test "KupCAD Parser: Import Statement" {
    const source = "import { ThreadedInsert, Screw } from \"./hardware.kup\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const import_stmt = tree.importStmt(stmt);

    try testing.expectEqualStrings("./hardware.kup", tree.getString(import_stmt.path));
    const symbols = tree.getStringLists(import_stmt.symbols);
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
    const if_stmt = tree.ifStmt(if_node);

    const cond = pt.getNode(if_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.greater, tree.binaryExpr(cond).op);

    const then_branch = pt.getNode(if_stmt.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const then_stmt = pt.getNode(then_stmts[0]);
    try testing.expectEqualStrings("a", tree.getString(tree.assignment(then_stmt).name));

    const elsif_node = pt.getNode(if_stmt.else_branch);
    const elsif_stmt = tree.ifStmt(elsif_node);

    const elsif_cond = pt.getNode(elsif_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.equal, tree.binaryExpr(elsif_cond).op);

    const else_block = pt.getNode(elsif_stmt.else_branch);
    const else_stmts = tree.getNodes(tree.block(else_block).stmts);
    const else_stmt = pt.getNode(else_stmts[0]);
    try testing.expectEqualStrings("a", tree.getString(tree.assignment(else_stmt).name));
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
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("on_face", tree.getString(mc.method_name));

    const block = pt.getNode(mc.block);
    const block_payload = tree.block(block);
    const params = tree.getNodes(block_payload.params);
    try testing.expectEqual(@as(usize, 2), params.len);

    try testing.expectEqualStrings("face", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(params[0]).data))));
    try testing.expectEqualStrings("idx", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(params[1]).data))));

    const block_stmts = tree.getNodes(block_payload.stmts);
    const stmt2 = pt.getNode(block_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.add, tree.binaryExpr(stmt2).op);
}

test "KupCAD Parser: Statement Modifiers (Yield Unless)" {
    const source = "yield unless 10 % 3 == 0";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_index = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_index);
    const if_stmt = tree.ifStmt(stmt);
    try testing.expectEqual(true, if_stmt.is_unless);

    const cond = pt.getNode(if_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.equal, tree.binaryExpr(cond).op);

    const then_branch = pt.getNode(if_stmt.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const inner_yield = pt.getNode(then_stmts[0]);
    const yield_args = tree.getNodes(tree.nodeSpan(inner_yield));
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
    const class_payload = tree.classStmt(class_stmt);

    try testing.expectEqualStrings("MyPart", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(class_payload.name).data))));
    try testing.expectEqualStrings("Base", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(class_payload.super_class).data))));

    const class_body = pt.getNode(class_payload.body);
    const class_stmts = tree.getNodes(tree.block(class_body).stmts);
    const def_node = pt.getNode(class_stmts[0]);
    const def_payload = tree.defStmt(def_node);
    try testing.expectEqualStrings("is_valid?", tree.getString(def_payload.name));

    const def_params = tree.getParams(def_payload.params);
    try testing.expectEqualStrings("x", tree.getString(def_params[0].name));

    const default_val = pt.getNode(def_params[0].default_value);
    try testing.expectEqual(@as(f64, 10.0), tree.number(default_val));

    const def_body = pt.getNode(def_payload.body);
    const body_stmts = tree.getNodes(tree.block(def_body).stmts);

    const stmt0 = pt.getNode(body_stmts[0]);
    const range_node = pt.getNode(tree.assignment(stmt0).value);
    const range_payload = tree.range(range_node);
    try testing.expectEqual(@as(f64, 20.0), tree.number(pt.getNode(range_payload.start)));
    try testing.expectEqual(@as(f64, 100.0), tree.number(pt.getNode(range_payload.end)));

    const stmt1 = pt.getNode(body_stmts[1]);
    const array_node = pt.getNode(tree.assignment(stmt1).value);
    const array_elements = tree.getNodes(tree.nodeSpan(array_node));
    try testing.expectEqual(@as(usize, 2), array_elements.len);

    const stmt2 = pt.getNode(body_stmts[2]);
    const ret_val_node = pt.getNode(tree.nodeIndex(stmt2));
    const ternary_payload = tree.ternaryExpr(ret_val_node);

    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ternary_payload.condition).data))));
    try testing.expectEqual(true, tree.boolean(pt.getNode(ternary_payload.then_branch)));
    try testing.expectEqual(false, tree.boolean(pt.getNode(ternary_payload.else_branch)));
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
    const add_payload = tree.assignment(add_assign);
    try testing.expectEqualStrings("w", tree.getString(add_payload.name));
    try testing.expectEqual(ast.BinaryOp.add, add_payload.op.?);

    const hash_assign_index = try pt.parser.parseStatement();
    const hash_assign = pt.getNode(hash_assign_index);
    const hash_node = pt.getNode(tree.assignment(hash_assign).value);
    const hash_entries = tree.getHashEntries(tree.nodeSpan(hash_node));
    const key_node = pt.getNode(hash_entries[0].key);
    try testing.expectEqualStrings("key", tree.getString(@as(ast.StringId, @enumFromInt(key_node.data))));
}

test "KupCAD Parser: String Interpolation" {
    const source = "echo(\"Value: #{x + 10} mm\")";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const echo_call_index = try pt.parser.parseStatement();
    const echo_call = pt.getNode(echo_call_index);
    const args = tree.getNamedArgs(tree.methodCall(echo_call).args);

    const interp_node = pt.getNode(args[0].value);
    const parts = tree.getNodes(tree.nodeSpan(interp_node));
    try testing.expectEqual(@as(usize, 3), parts.len);

    const part0 = pt.getNode(parts[0]);
    try testing.expectEqualStrings("Value: ", tree.getString(@as(ast.StringId, @enumFromInt(part0.data))));

    const part1 = pt.getNode(parts[1]);
    try testing.expectEqual(ast.BinaryOp.add, tree.binaryExpr(part1).op);

    const part2 = pt.getNode(parts[2]);
    try testing.expectEqualStrings(" mm", tree.getString(@as(ast.StringId, @enumFromInt(part2.data))));
}

test "KupCAD Parser: Exponentiation vs Unary Precedence" {
    const source = "-2 ** 2";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.unary_op, stmt.tag);
    try testing.expectEqual(ast.UnaryOp.negate, tree.unaryExpr(stmt).op);

    const right_node = pt.getNode(tree.unaryExpr(stmt).operand);
    try testing.expectEqual(ast.Tag.binary_op, right_node.tag);
    try testing.expectEqual(ast.BinaryOp.exponent, tree.binaryExpr(right_node).op);
}

test "KupCAD Parser: Parenthesis-less Method Calls (Command Syntax)" {
    const source = "cube x: 10, y: 20";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.method_call, stmt.tag);
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("cube", tree.getString(mc.method_name));

    const args = tree.getNamedArgs(mc.args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));
}

test "KupCAD Parser BUG: Empty String Interpolation" {
    const source = "\"Empty: #{}\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.interpolated_string, stmt.tag);
}

test "KupCAD Parser: Namespace Resolution (Scope Operator ::)" {
    const source = "part = Hardware::Fasteners::M3_Bolt.new(length: 12)";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.assignment, stmt.tag);

    const call_node = pt.getNode(tree.assignment(stmt).value);
    try testing.expectEqualStrings("new", tree.getString(tree.methodCall(call_node).method_name));

    const receiver = pt.getNode(tree.methodCall(call_node).receiver);
    try testing.expectEqual(ast.Tag.namespace_access, receiver.tag);

    const path = tree.getStringLists(tree.nodeSpan(receiver));
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
    try testing.expectEqual(ast.Tag.case_stmt, stmt.tag);
    const case_stmt = tree.caseStmt(stmt);

    const condition = pt.getNode(case_stmt.condition);
    try testing.expectEqualStrings("part_type", tree.getString(@as(ast.StringId, @enumFromInt(condition.data))));

    const branches = tree.getWhenBranches(case_stmt.when_branches);
    try testing.expectEqual(@as(usize, 2), branches.len);

    const conds0 = tree.getNodes(branches[0].conditions);
    const branch0_cond = pt.getNode(conds0[0]);
    try testing.expectEqualStrings("screw", tree.getString(@as(ast.StringId, @enumFromInt(branch0_cond.data))));

    const conds1 = tree.getNodes(branches[1].conditions);
    const branch1_cond = pt.getNode(conds1[0]);
    try testing.expectEqualStrings("nut", tree.getString(@as(ast.StringId, @enumFromInt(branch1_cond.data))));

    const else_branch = pt.getNode(case_stmt.else_branch);
    const else_stmts = tree.getNodes(tree.block(else_branch).stmts);
    const else_stmt = pt.getNode(else_stmts[0]);
    try testing.expectEqualStrings("new", tree.getString(tree.methodCall(else_stmt).method_name));
}

test "KupCAD Parser: Multiple Assignment" {
    const source = "x, y, z = get_coordinates()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.multiple_assignment, stmt.tag);

    const ma = tree.multipleAssignment(stmt);
    const lhs = tree.getLhsExprs(ma.lhs);
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
    const body_node = pt.getNode(tree.defStmt(def_node).body);

    const stmts = tree.getNodes(tree.block(body_node).stmts);
    const stmt0 = pt.getNode(stmts[0]);
    try testing.expectEqual(ast.Tag.super_call, stmt0.tag);

    const sc = tree.superCall(stmt0);
    const args = tree.getNamedArgs(sc.args);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));

    const stmt1 = pt.getNode(stmts[1]);
    try testing.expectEqual(ast.Tag.self_expr, stmt1.tag);
}

test "KupCAD Parser: Stabby Lambda (Anonymous Function)" {
    const source = "my_lambda = ->(x, y) { x + y }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.assignment, stmt.tag);

    const lambda = pt.getNode(tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.lambda_expr, lambda.tag);

    const le = tree.lambdaExpr(lambda);
    const params = tree.getParams(le.params);
    try testing.expectEqualStrings("x", tree.getString(params[0].name));
    try testing.expectEqualStrings("y", tree.getString(params[1].name));

    const body_node = pt.getNode(le.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.add, tree.binaryExpr(stmt0).op);
}

test "KupCAD Parser: Exclusive Range (...)" {
    const source = "1...5";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.range, stmt.tag);

    const r = tree.range(stmt);
    try testing.expectEqual(true, r.is_exclusive);

    const end_node = pt.getNode(r.end);
    try testing.expectEqual(@as(f64, 5.0), tree.number(end_node));
}

test "KupCAD Parser: Statement Modifiers (Trailing if)" {
    const source = "box.chamfer() if render_chamfer";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.if_stmt, stmt.tag);

    const ifs = tree.ifStmt(stmt);
    const cond = pt.getNode(ifs.condition);
    try testing.expectEqualStrings("render_chamfer", tree.getString(@as(ast.StringId, @enumFromInt(cond.data))));

    const then_branch = pt.getNode(ifs.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const then_stmt0 = pt.getNode(then_stmts[0]);
    try testing.expectEqual(ast.Tag.method_call, then_stmt0.tag);
}

test "KupCAD Parser: Unary Plus Support" {
    const source = "val = +10";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const assign_node_idx = try pt.parser.parseStatement();
    const assign_node = pt.getNode(assign_node_idx);
    const a = tree.assignment(assign_node);
    try testing.expectEqualStrings("val", tree.getString(a.name));

    const value_node = pt.getNode(a.value);
    try testing.expectEqual(ast.UnaryOp.positive, tree.unaryExpr(value_node).op);
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
    const ds = tree.defStmt(def_node);

    const params = tree.getParams(ds.params);
    try testing.expectEqual(ast.ArgModifier.splat, params[0].modifier.?);
    try testing.expectEqualStrings("args", tree.getString(params[0].name));
    try testing.expectEqual(ast.ArgModifier.double_splat, params[1].modifier.?);
    try testing.expectEqualStrings("kwargs", tree.getString(params[1].name));
    try testing.expectEqual(ast.ArgModifier.block, params[2].modifier.?);
    try testing.expectEqualStrings("block", tree.getString(params[2].name));

    const body_node = pt.getNode(ds.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const call_node = pt.getNode(body_stmts[0]);

    const args = tree.getNamedArgs(tree.methodCall(call_node).args);
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
    const bin_shift = tree.binaryExpr(shift_node);
    try testing.expectEqual(ast.BinaryOp.shift_left, bin_shift.op);
    try testing.expectEqualStrings("arr", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_shift.left).data))));
    try testing.expectEqual(@as(f64, 5.0), tree.number(pt.getNode(bin_shift.right)));

    const safe_call_idx = try pt.parser.parseStatement();
    const safe_call = pt.getNode(safe_call_idx);
    const mc = tree.methodCall(safe_call);
    try testing.expectEqualStrings("cut", tree.getString(mc.method_name));
    try testing.expectEqual(true, mc.is_safe);
}

test "KupCAD Parser: CSG Intersections and Bitwise Operators" {
    const source = "result = ~part1 & part2 | part3 ^ part4";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const a = tree.assignment(stmt);
    try testing.expectEqualStrings("result", tree.getString(a.name));

    const xor_node = pt.getNode(a.value);
    const bin_xor = tree.binaryExpr(xor_node);
    try testing.expectEqual(ast.BinaryOp.bitwise_xor, bin_xor.op);
    try testing.expectEqualStrings("part4", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_xor.right).data))));

    const or_node = pt.getNode(bin_xor.left);
    const bin_or = tree.binaryExpr(or_node);
    try testing.expectEqual(ast.BinaryOp.bitwise_or, bin_or.op);
    try testing.expectEqualStrings("part3", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_or.right).data))));

    const and_node = pt.getNode(bin_or.left);
    const bin_and = tree.binaryExpr(and_node);
    try testing.expectEqual(ast.BinaryOp.bitwise_and, bin_and.op);
    try testing.expectEqualStrings("part2", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_and.right).data))));

    const not_node = pt.getNode(bin_and.left);
    const un_not = tree.unaryExpr(not_node);
    try testing.expectEqual(ast.UnaryOp.bitwise_not, un_not.op);
    try testing.expectEqualStrings("part1", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(un_not.operand).data))));
}

test "KupCAD Parser: Curly Brace Method Blocks" {
    const source = "faces.each { |f| f.fillet(2) }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("each", tree.getString(mc.method_name));

    const block = pt.getNode(mc.block);
    const block_payload = tree.block(block);
    const params = tree.getNodes(block_payload.params);
    try testing.expectEqualStrings("f", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(params[0]).data))));

    const block_stmts = tree.getNodes(block_payload.stmts);
    const inner_call = pt.getNode(block_stmts[0]);
    try testing.expectEqualStrings("fillet", tree.getString(tree.methodCall(inner_call).method_name));
}

test "KupCAD Parser: Next Statement and Until/While Modifiers" {
    const source = "next 10 until x == 5";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.while_stmt, stmt.tag);
    const ws = tree.whileStmt(stmt);
    try testing.expectEqual(true, ws.is_until);

    const body_node = pt.getNode(ws.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const inner_next = pt.getNode(body_stmts[0]);
    try testing.expectEqual(ast.Tag.next_stmt, inner_next.tag);

    const next_val = pt.getNode(tree.nodeIndex(inner_next));
    try testing.expectEqual(@as(f64, 10.0), tree.number(next_val));
}

test "KupCAD Parser: LHS Splats and Multiple Assignment" {
    const source = "first, *rest = get_faces()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const ma = tree.multipleAssignment(stmt);

    const lhs = tree.getLhsExprs(ma.lhs);
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
    const ds = tree.defStmt(stmt);

    const params = tree.getParams(ds.params);
    try testing.expectEqual(true, params[0].is_keyword);
    try testing.expectEqualStrings("width", tree.getString(params[0].name));

    try testing.expectEqual(true, params[1].is_keyword);
    try testing.expectEqualStrings("height", tree.getString(params[1].name));

    const default_val = pt.getNode(params[1].default_value);
    try testing.expectEqual(@as(f64, 10.0), tree.number(default_val));
}

test "KupCAD Parser: Begin / Rescue / Ensure" {
    const source = "begin\n  build()\nrescue => e\n  log()\nensure\n  clean()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.begin_stmt, stmt.tag);
    const bs = tree.beginStmt(stmt);

    const body_node = pt.getNode(bs.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const body_stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqualStrings("build", tree.getString(tree.methodCall(body_stmt0).method_name));

    const rescues = tree.getRescueClauses(bs.rescues);
    const rescue_body = pt.getNode(rescues[0].body);
    const rescue_stmts = tree.getNodes(tree.block(rescue_body).stmts);
    const rescue_stmt0 = pt.getNode(rescue_stmts[0]);
    try testing.expectEqualStrings("log", tree.getString(tree.methodCall(rescue_stmt0).method_name));

    const ensure_body = pt.getNode(bs.ensure_body);
    const ensure_stmts = tree.getNodes(tree.block(ensure_body).stmts);
    const ensure_stmt0 = pt.getNode(ensure_stmts[0]);
    try testing.expectEqualStrings("clean", tree.getString(tree.methodCall(ensure_stmt0).method_name));
}

test "KupCAD Parser: Object Property Assignment" {
    const source = "box.width = 100";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.property_assignment, stmt.tag);
    const pa = tree.propertyAssignment(stmt);

    try testing.expectEqualStrings("box", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(pa.target).data))));
    try testing.expectEqualStrings("width", tree.getString(pa.property));
    try testing.expectEqual(@as(f64, 100.0), tree.number(pt.getNode(pa.value)));
}

test "KupCAD Parser: Receiver Command Syntax" {
    const source = "box.translate x: 10, y: 20 do\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.method_call, stmt.tag);
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("translate", tree.getString(mc.method_name));
    try testing.expectEqualStrings("box", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(mc.receiver).data))));

    const args = tree.getNamedArgs(mc.args);
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));
    try testing.expectEqualStrings("y", tree.getString(args[1].name));
    try testing.expect(mc.block != .none);
}

test "KupCAD Parser: Begin / Rescue / Ensure with Classes" {
    const source = "begin\n  build()\nrescue IOError, KeyError => e\n  log()\nensure\n  clean()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.begin_stmt, stmt.tag);
    const bs = tree.beginStmt(stmt);

    const body_node = pt.getNode(bs.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const body_stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqualStrings("build", tree.getString(tree.methodCall(body_stmt0).method_name));

    const rescues = tree.getRescueClauses(bs.rescues);
    const rescue_clause = rescues[0];
    const errors = tree.getStringLists(rescue_clause.errors);
    try testing.expectEqual(@as(usize, 2), errors.len);
    try testing.expectEqualStrings("IOError", tree.getString(errors[0]));
    try testing.expectEqualStrings("KeyError", tree.getString(errors[1]));
    try testing.expectEqualStrings("e", tree.getString(rescue_clause.variable));

    const rescue_body = pt.getNode(rescue_clause.body);
    const rescue_stmts = tree.getNodes(tree.block(rescue_body).stmts);
    const rescue_stmt0 = pt.getNode(rescue_stmts[0]);
    try testing.expectEqualStrings("log", tree.getString(tree.methodCall(rescue_stmt0).method_name));

    const ensure_node = pt.getNode(bs.ensure_body);
    const ensure_stmts = tree.getNodes(tree.block(ensure_node).stmts);
    const ensure_stmt0 = pt.getNode(ensure_stmts[0]);
    try testing.expectEqualStrings("clean", tree.getString(tree.methodCall(ensure_stmt0).method_name));
}

test "KupCAD Parser: Inline Rescue Modifier" {
    const source = "val = dangerous() rescue 0";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const res_mod = pt.getNode(tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.rescue_modifier, res_mod.tag);
    const rm = tree.rescueModifier(res_mod);

    const expr = pt.getNode(rm.expr);
    try testing.expectEqualStrings("dangerous", tree.getString(tree.methodCall(expr).method_name));

    const rescue_expr = pt.getNode(rm.rescue_expr);
    try testing.expectEqual(@as(f64, 0.0), tree.number(rescue_expr));
}

test "KupCAD Lexer and Parser: Percent Literals (%w, %i)" {
    const source = "list = %w[gear shaft motor]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const arr_node = pt.getNode(tree.assignment(stmt).value);
    const arr = tree.getNodes(tree.nodeSpan(arr_node));
    try testing.expectEqual(@as(usize, 3), arr.len);

    try testing.expectEqualStrings("gear", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(arr[0]).data))));
    try testing.expectEqualStrings("shaft", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(arr[1]).data))));
    try testing.expectEqualStrings("motor", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(arr[2]).data))));
}

test "KupCAD Parser: Class Methods and Namespaced Inheritance" {
    const source = "class Hardware::Screw < Base::Part\n  def self.build()\n  end\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const class_stmt_idx = try pt.parser.parseStatement();
    const class_stmt = pt.getNode(class_stmt_idx);
    const cs = tree.classStmt(class_stmt);

    const name_node = pt.getNode(cs.name);
    const name_path = tree.getStringLists(tree.nodeSpan(name_node));
    try testing.expectEqualStrings("Hardware", tree.getString(name_path[0]));

    const super_node = pt.getNode(cs.super_class);
    const super_path = tree.getStringLists(tree.nodeSpan(super_node));
    try testing.expectEqualStrings("Base", tree.getString(super_path[0]));

    const body_node = pt.getNode(cs.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const def_node = pt.getNode(body_stmts[0]);
    const ds = tree.defStmt(def_node);
    try testing.expectEqual(true, ds.is_class_method);
    try testing.expectEqualStrings("build", tree.getString(ds.name));
}

test "KupCAD Parser: Implicit RHS Tuples and Array/Hash Splats" {
    const source = "x, y = 10, 20\narr = [1, *other]\nopts = {a: 1, **kwargs}";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const multi_assign_idx = try pt.parser.parseStatement();
    const multi_assign = pt.getNode(multi_assign_idx);
    const ma = tree.multipleAssignment(multi_assign);
    const multi_val = pt.getNode(ma.value);
    const multi_arr = tree.getNodes(tree.nodeSpan(multi_val));
    try testing.expectEqual(@as(usize, 2), multi_arr.len);

    const arr_assign_idx = try pt.parser.parseStatement();
    const arr_assign = pt.getNode(arr_assign_idx);
    const arr_node = pt.getNode(tree.assignment(arr_assign).value);
    const arr_lit = tree.getNodes(tree.nodeSpan(arr_node));
    const splat_node = pt.getNode(arr_lit[1]);
    try testing.expectEqual(ast.Tag.splat_expr, splat_node.tag);

    const hash_assign_idx = try pt.parser.parseStatement();
    const hash_assign = pt.getNode(hash_assign_idx);
    const hash_node = pt.getNode(tree.assignment(hash_assign).value);
    const hash_lit = tree.getHashEntries(tree.nodeSpan(hash_node));
    const double_splat_node = pt.getNode(hash_lit[1].key);
    try testing.expectEqual(ast.Tag.double_splat_expr, double_splat_node.tag);
}

test "KupCAD Parser: Quoted Symbols, Single Quotes, Destructuring" {
    const source = "map.each(:'key name') do |(x, y), val|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);
    const args = tree.getNamedArgs(mc.args);
    const arg0 = pt.getNode(args[0].value);
    try testing.expectEqualStrings("key name", tree.getString(@as(ast.StringId, @enumFromInt(arg0.data))));

    const block = pt.getNode(mc.block);
    const block_payload = tree.block(block);
    const params = tree.getNodes(block_payload.params);

    const param0 = pt.getNode(params[0]);
    try testing.expectEqual(ast.Tag.array_literal, param0.tag);

    const param0_elems = tree.getNodes(tree.nodeSpan(param0));
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(param0_elems[0]).data))));
    try testing.expectEqualStrings("y", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(param0_elems[1]).data))));

    const param1 = pt.getNode(params[1]);
    try testing.expectEqualStrings("val", tree.getString(@as(ast.StringId, @enumFromInt(param1.data))));
}

test "KupCAD Parser: Super with Command Syntax and Blocks" {
    const source = "super x: 10 do\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.super_call, stmt.tag);
    const sc = tree.superCall(stmt);

    const args = tree.getNamedArgs(sc.args);
    try testing.expectEqualStrings("x", tree.getString(args[0].name));
    try testing.expect(sc.block != .none);
}

test "KupCAD Parser: Optional 'then' Keyword" {
    const source = "if x > 5 then a = 1 end";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.if_stmt, stmt.tag);
    const ifs = tree.ifStmt(stmt);

    const then_branch = pt.getNode(ifs.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const then_stmt0 = pt.getNode(then_stmts[0]);
    try testing.expectEqualStrings("a", tree.getString(tree.assignment(then_stmt0).name));
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
    const ds = tree.defStmt(def_node);
    try testing.expectEqualStrings("process", tree.getString(ds.name));

    const begin_node = pt.getNode(ds.body);
    try testing.expectEqual(ast.Tag.begin_stmt, begin_node.tag);
    const bs = tree.beginStmt(begin_node);

    const body_node = pt.getNode(bs.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const body_stmt0 = pt.getNode(body_stmts[0]);
    try testing.expectEqualStrings("run_step", tree.getString(tree.methodCall(body_stmt0).method_name));

    const rescues = tree.getRescueClauses(bs.rescues);
    const rescue_clause = rescues[0];
    try testing.expectEqualStrings("err", tree.getString(rescue_clause.variable));

    const rescue_body = pt.getNode(rescue_clause.body);
    const rescue_stmts = tree.getNodes(tree.block(rescue_body).stmts);
    const rescue_stmt0 = pt.getNode(rescue_stmts[0]);
    try testing.expectEqualStrings("handle_error", tree.getString(tree.methodCall(rescue_stmt0).method_name));

    const ensure_node = pt.getNode(bs.ensure_body);
    const ensure_stmts = tree.getNodes(tree.block(ensure_node).stmts);
    const ensure_stmt0 = pt.getNode(ensure_stmts[0]);
    try testing.expectEqualStrings("cleanup", tree.getString(tree.methodCall(ensure_stmt0).method_name));
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
    const tree = &pt.parser.b.tree;

    const n1 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 31.0), tree.number(pt.getNode(tree.assignment(n1).value)));

    const n2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(tree.assignment(n2).value)));

    const n3 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 493.0), tree.number(pt.getNode(tree.assignment(n3).value)));

    const n4 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 1500.0), tree.number(pt.getNode(tree.assignment(n4).value)));

    const n5 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 1000000.0), tree.number(pt.getNode(tree.assignment(n5).value)));

    const n6 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(@as(f64, 0.56), tree.number(pt.getNode(tree.assignment(n6).value)));
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
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("translate", tree.getString(mc.method_name));

    const chamfer_node = pt.getNode(mc.receiver);
    const chamfer_mc = tree.methodCall(chamfer_node);
    try testing.expectEqualStrings("chamfer", tree.getString(chamfer_mc.method_name));

    const new_node = pt.getNode(chamfer_mc.receiver);
    const new_mc = tree.methodCall(new_node);
    try testing.expectEqualStrings("new", tree.getString(new_mc.method_name));
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
    try testing.expectEqual(ast.Tag.import_stmt, imp_node.tag);
    const is_stmt = tree.importStmt(imp_node);
    try testing.expectEqualStrings("module-name", tree.getString(is_stmt.path));

    const imp_symbols = tree.getStringLists(is_stmt.symbols);
    try testing.expectEqualStrings("names", tree.getString(imp_symbols[0]));

    const attrs = pt.getNode(is_stmt.attributes);
    const hash_entries = tree.getHashEntries(tree.nodeSpan(attrs));
    try testing.expectEqual(@as(usize, 2), hash_entries.len);
    try testing.expectEqualStrings("key", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash_entries[0].key).data))));

    const exp_node_idx = try pt.parser.parseStatement();
    const exp_node = pt.getNode(exp_node_idx);
    try testing.expectEqual(ast.Tag.export_stmt, exp_node.tag);
    const es_stmt = tree.exportStmt(exp_node);
    try testing.expectEqualStrings("module-name", tree.getString(es_stmt.path));

    const exp_attrs = pt.getNode(es_stmt.attributes);
    const exp_hash_entries = tree.getHashEntries(tree.nodeSpan(exp_attrs));
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
    const is1 = tree.importStmt(imp_node_1);
    try testing.expectEqualStrings("global_config.kup", tree.getString(is1.path));
    const symbols1 = tree.getStringLists(is1.symbols);
    try testing.expectEqual(@as(usize, 0), symbols1.len);

    const imp_node_2 = pt.getNode(try pt.parser.parseStatement());
    const is2 = tree.importStmt(imp_node_2);
    try testing.expectEqualStrings("hardware.kup", tree.getString(is2.path));
    const symbols2 = tree.getStringLists(is2.symbols);
    try testing.expectEqualStrings("Hardware", tree.getString(symbols2[0]));

    const call_node = pt.getNode(try pt.parser.parseStatement());
    const mc = tree.methodCall(call_node);
    try testing.expectEqualStrings("cube", tree.getString(mc.method_name));
    const args = tree.getNamedArgs(mc.args);
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

test "KupCAD Parser: Diagnostics for Invalid Expression (AST Poisoning)" {
    const source = "val = 10 + }";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    // The parser survived and generated an Assignment node!
    try testing.expectEqual(ast.Tag.assignment, stmt.tag);

    const bin_expr = pt.getNode(pt.parser.b.tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.binary_op, bin_expr.tag);

    // The right side of the binary op is POISONED, allowing the LSP to still see the `10 + `
    const right_side = pt.getNode(pt.parser.b.tree.binaryExpr(bin_expr).right);
    try testing.expectEqual(ast.Tag.invalid, right_side.tag);

    // The diagnostic was still safely captured
    try testing.expectEqual(@as(usize, 1), pt.parser.diagnostics.list.items.len);
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
    const arr_node = pt.getNode(tree.assignment(n1).value);
    const arr_elems = tree.getNodes(tree.nodeSpan(arr_node));
    try testing.expectEqual(@as(usize, 2), arr_elems.len);

    const n2 = pt.getNode(try pt.parser.parseStatement());
    const hash_node = pt.getNode(tree.assignment(n2).value);
    const hash_entries = tree.getHashEntries(tree.nodeSpan(hash_node));
    try testing.expectEqual(@as(usize, 2), hash_entries.len);

    const n3 = pt.getNode(try pt.parser.parseStatement());
    const block = pt.getNode(tree.methodCall(n3).block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 2), params.len);
}

test "KupCAD Parser: Index Access and Index Compound Assignment" {
    const source = "points[0] += offset * 2";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.index_assignment, stmt.tag);
    const ia = tree.indexAssignment(stmt);

    try testing.expectEqualStrings("points", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ia.target).data))));
    try testing.expectEqual(@as(f64, 0.0), tree.number(pt.getNode(ia.index)));
    try testing.expectEqual(ast.BinaryOp.add, ia.op.?);

    const val_node = pt.getNode(ia.value);
    try testing.expectEqual(ast.BinaryOp.multiply, tree.binaryExpr(val_node).op);
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
    try testing.expectEqual(ast.Tag.export_stmt, export_node.tag);
    const es = tree.exportStmt(export_node);
    try testing.expectEqualStrings("./housing.kup", tree.getString(es.path));

    const export_symbols = tree.getStringLists(es.symbols);
    try testing.expectEqualStrings("Enclosure", tree.getString(export_symbols[0]));
    try testing.expectEqualStrings("Mount", tree.getString(export_symbols[1]));

    const mod_node = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.Tag.module_stmt, mod_node.tag);
    const ms = tree.moduleStmt(mod_node);
    try testing.expectEqualStrings("Hardware", tree.getString(ms.name));

    const body_node = pt.getNode(ms.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const inner_class = pt.getNode(body_stmts[0]);
    const cs = tree.classStmt(inner_class);
    const class_name = pt.getNode(cs.name);
    try testing.expectEqualStrings("Screw", tree.getString(@as(ast.StringId, @enumFromInt(class_name.data))));
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
    const arr_node = pt.getNode(tree.assignment(stmt).value);
    const arr = tree.getNodes(tree.nodeSpan(arr_node));
    try testing.expectEqual(@as(usize, 3), arr.len);

    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(arr[0])));
    try testing.expectEqual(@as(f64, 20.0), tree.number(pt.getNode(arr[1])));
    try testing.expectEqual(@as(f64, 30.0), tree.number(pt.getNode(arr[2])));
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
    try testing.expectEqual(ast.Tag.method_call, stmt.tag);
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("chamfer", tree.getString(mc.method_name));
    try testing.expectEqual(true, mc.is_safe);

    const prev_call = pt.getNode(mc.receiver);
    const prev_mc = tree.methodCall(prev_call);
    try testing.expectEqualStrings("cut", tree.getString(prev_mc.method_name));
    try testing.expectEqual(true, prev_mc.is_safe);
}

test "KupCAD Parser: Generic Docstring Parsing" {
    const source = "# @label Bracket Width";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.docstring, stmt.tag);

    const doc = tree.docString(stmt);
    try testing.expectEqualStrings("label", tree.getString(doc.tag_name));
    try testing.expectEqualStrings("Bracket Width", tree.getString(doc.content));
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
    const bin = tree.binaryExpr(stmt);

    try testing.expectEqual(ast.BinaryOp.bitwise_and, bin.op);
    try testing.expectEqualStrings("boundary", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin.right).data))));

    const left_expr = pt.getNode(bin.left);
    const bin_left = tree.binaryExpr(left_expr);
    try testing.expectEqual(ast.BinaryOp.add, bin_left.op);
    try testing.expectEqualStrings("base_mesh", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_left.left).data))));

    const paren_expr = pt.getNode(bin_left.right);
    const bin_paren = tree.binaryExpr(paren_expr);
    try testing.expectEqual(ast.BinaryOp.subtract, bin_paren.op);
    try testing.expectEqualStrings("cover", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_paren.left).data))));
    try testing.expectEqualStrings("cylinder", tree.getString(tree.methodCall(pt.getNode(bin_paren.right)).method_name));
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
    try testing.expectEqual(ast.Tag.method_call, top_call.tag);
    const top_mc = tree.methodCall(top_call);
    try testing.expectEqualStrings("translate", tree.getString(top_mc.method_name));

    const top_args = tree.getNamedArgs(top_mc.args);
    try testing.expectEqual(@as(usize, 2), top_args.len);

    const top_block = pt.getNode(top_mc.block);
    const top_stmts = tree.getNodes(tree.block(top_block).stmts);
    const rotate_call = pt.getNode(top_stmts[0]);
    const rotate_mc = tree.methodCall(rotate_call);
    try testing.expectEqualStrings("rotate", tree.getString(rotate_mc.method_name));

    const rotate_block = pt.getNode(rotate_mc.block);
    const rotate_stmts = tree.getNodes(tree.block(rotate_block).stmts);
    const cube_call = pt.getNode(rotate_stmts[0]);
    const cube_mc = tree.methodCall(cube_call);
    try testing.expectEqualStrings("cube", tree.getString(cube_mc.method_name));

    const cube_args = tree.getNamedArgs(cube_mc.args);
    try testing.expectEqualStrings("size", tree.getString(cube_args[0].name));
}

test "KupCAD Parser: Range Slicing inside Indexing Operations" {
    const source = "subset = vertices[1..4]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqualStrings("subset", tree.getString(tree.assignment(stmt).name));

    const index_access = pt.getNode(tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.index_access, index_access.tag);
    const ia = tree.indexAccess(index_access);
    try testing.expectEqualStrings("vertices", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ia.target).data))));

    const range_node = pt.getNode(ia.index);
    try testing.expectEqual(ast.Tag.range, range_node.tag);
    const r = tree.range(range_node);
    try testing.expectEqual(@as(f64, 1.0), tree.number(pt.getNode(r.start)));
    try testing.expectEqual(@as(f64, 4.0), tree.number(pt.getNode(r.end)));
    try testing.expectEqual(false, r.is_exclusive);
}

test "KupCAD Parser: Complex Nested Hashes with Symbol Arrays (%i)" {
    const source = "options = { style: :fillet, keys: %i[r h d], inner: { depth: 5 } }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const hash_node = pt.getNode(tree.assignment(stmt).value);
    const hash = tree.getHashEntries(tree.nodeSpan(hash_node));
    try testing.expectEqual(@as(usize, 3), hash.len);

    try testing.expectEqualStrings("style", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[0].key).data))));
    try testing.expectEqualStrings("fillet", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[0].value).data))));

    try testing.expectEqualStrings("keys", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[1].key).data))));
    const sym_array_node = pt.getNode(hash[1].value);
    const sym_array = tree.getNodes(tree.nodeSpan(sym_array_node));
    try testing.expectEqual(@as(usize, 3), sym_array.len);
    try testing.expectEqualStrings("r", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(sym_array[0]).data))));

    try testing.expectEqualStrings("inner", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[2].key).data))));
    const nested_hash_node = pt.getNode(hash[2].value);
    const nested_hash = tree.getHashEntries(tree.nodeSpan(nested_hash_node));
    try testing.expectEqualStrings("depth", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(nested_hash[0].key).data))));
    try testing.expectEqual(@as(f64, 5.0), tree.number(pt.getNode(nested_hash[0].value)));
}

test "KupCAD Parser: Multiple Destructuring Assignment with Splats" {
    const source = "a, *middle, z = [1, 2, 3, 4, 5]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.multiple_assignment, stmt.tag);
    const ma = tree.multipleAssignment(stmt);

    const lhs = tree.getLhsExprs(ma.lhs);
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
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const math_node = pt.getNode(tree.assignment(stmt).value);
    const bin_math = tree.binaryExpr(math_node);

    // Root is subtraction `- 0b10`
    try testing.expectEqual(ast.BinaryOp.subtract, bin_math.op);
    try testing.expectEqual(@as(f64, 2.0), tree.number(pt.getNode(bin_math.right))); // 0b10 = 2

    // Left is `-0x1F + (.5 * 1.5e2)`
    const add_node = pt.getNode(bin_math.left);
    const bin_add = tree.binaryExpr(add_node);
    try testing.expectEqual(ast.BinaryOp.add, bin_add.op);

    // Negated Hex: -0x1F (-31)
    const neg_hex = pt.getNode(bin_add.left);
    const un_neg = tree.unaryExpr(neg_hex);
    try testing.expectEqual(ast.UnaryOp.negate, un_neg.op);
    try testing.expectEqual(@as(f64, 31.0), tree.number(pt.getNode(un_neg.operand)));

    // Multiplication: .5 * 150.0 = 75.0
    const mult_node = pt.getNode(bin_add.right);
    const bin_mult = tree.binaryExpr(mult_node);
    try testing.expectEqual(ast.BinaryOp.multiply, bin_mult.op);
    try testing.expectEqual(@as(f64, 0.5), tree.number(pt.getNode(bin_mult.left)));
    try testing.expectEqual(@as(f64, 150.0), tree.number(pt.getNode(bin_mult.right)));
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
    try testing.expectEqual(ast.Tag.class_stmt, class_stmt.tag);
    const cs = tree.classStmt(class_stmt);

    // Name: CAD::Fastener::Bolt
    const name_node = pt.getNode(cs.name);
    const name_ns = tree.getStringLists(tree.nodeSpan(name_node));
    try testing.expectEqual(@as(usize, 3), name_ns.len);
    try testing.expectEqualStrings("CAD", tree.getString(name_ns[0]));
    try testing.expectEqualStrings("Fastener", tree.getString(name_ns[1]));
    try testing.expectEqualStrings("Bolt", tree.getString(name_ns[2]));

    // Super: Hardware::Base
    const super_node = pt.getNode(cs.super_class);
    const super_ns = tree.getStringLists(tree.nodeSpan(super_node));
    try testing.expectEqual(@as(usize, 2), super_ns.len);
    try testing.expectEqualStrings("Hardware", tree.getString(super_ns[0]));
    try testing.expectEqualStrings("Base", tree.getString(super_ns[1]));

    // Class Method: def self.m3
    const body_node = pt.getNode(cs.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const def_node = pt.getNode(body_stmts[0]);
    const ds = tree.defStmt(def_node);
    try testing.expectEqual(true, ds.is_class_method);
    try testing.expectEqualStrings("m3", tree.getString(ds.name));

    const params = tree.getParams(ds.params);
    try testing.expectEqualStrings("length", tree.getString(params[0].name));
}

test "KupCAD Parser: Top-Level Scope Resolution with Chained Calls" {
    const source = "part = ::Hardware::Fastener::Screw.build(length: 20)";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.assignment, stmt.tag);

    const call_node = pt.getNode(tree.assignment(stmt).value);
    const mc = tree.methodCall(call_node);
    try testing.expectEqualStrings("build", tree.getString(mc.method_name));

    const ns_access = pt.getNode(mc.receiver);
    try testing.expectEqual(ast.Tag.namespace_access, ns_access.tag);

    const path = tree.getStringLists(tree.nodeSpan(ns_access));
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
    const a1 = tree.assignment(s1);
    try testing.expectEqualStrings("mask", tree.getString(a1.name));
    try testing.expectEqual(ast.BinaryOp.bitwise_and, a1.op.?);

    // flags |= 0b100
    const s2 = pt.getNode(try pt.parser.parseStatement());
    const a2 = tree.assignment(s2);
    try testing.expectEqualStrings("flags", tree.getString(a2.name));
    try testing.expectEqual(ast.BinaryOp.bitwise_or, a2.op.?);

    // key ^= 0x01
    const s3 = pt.getNode(try pt.parser.parseStatement());
    const a3 = tree.assignment(s3);
    try testing.expectEqualStrings("key", tree.getString(a3.name));
    try testing.expectEqual(ast.BinaryOp.bitwise_xor, a3.op.?);

    // buf <<= 8
    const s4 = pt.getNode(try pt.parser.parseStatement());
    const a4 = tree.assignment(s4);
    try testing.expectEqualStrings("buf", tree.getString(a4.name));
    try testing.expectEqual(ast.BinaryOp.shift_left, a4.op.?);

    // val ||= default_val
    const s5 = pt.getNode(try pt.parser.parseStatement());
    const a5 = tree.assignment(s5);
    try testing.expectEqualStrings("val", tree.getString(a5.name));
    try testing.expectEqual(ast.BinaryOp.logical_or, a5.op.?);
}

test "KupCAD Parser: Keyword Logical Operators (and, or, not) Precedence" {
    const source = "valid and ready or not disabled";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);
    const bin_or = tree.binaryExpr(expr);

    // Logical OR has lower precedence than AND, so OR is root
    try testing.expectEqual(ast.BinaryOp.logical_or, bin_or.op);

    // Right of OR is `not disabled`
    const not_node = pt.getNode(bin_or.right);
    const un_not = tree.unaryExpr(not_node);
    try testing.expectEqual(ast.UnaryOp.not, un_not.op);
    try testing.expectEqualStrings("disabled", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(un_not.operand).data))));

    // Left of OR is `valid and ready`
    const and_node = pt.getNode(bin_or.left);
    const bin_and = tree.binaryExpr(and_node);
    try testing.expectEqual(ast.BinaryOp.logical_and, bin_and.op);
    try testing.expectEqualStrings("valid", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_and.left).data))));
    try testing.expectEqualStrings("ready", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_and.right).data))));
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
    try testing.expectEqual(ast.Tag.if_stmt, s1.tag);
    const if1 = tree.ifStmt(s1);
    try testing.expectEqualStrings("finished?", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(if1.condition).data))));

    const then1_block = pt.getNode(if1.then_branch);
    const then1_stmts = tree.getNodes(tree.block(then1_block).stmts);
    const break_node = pt.getNode(then1_stmts[0]);
    const break_val = pt.getNode(tree.nodeIndex(break_node));
    try testing.expectEqual(@as(f64, 42.0), tree.number(break_val));

    // return x, y unless error?
    const s2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.Tag.if_stmt, s2.tag);
    const if2 = tree.ifStmt(s2);
    try testing.expectEqual(true, if2.is_unless);

    const then2_block = pt.getNode(if2.then_branch);
    const then2_stmts = tree.getNodes(tree.block(then2_block).stmts);
    const ret_node = pt.getNode(then2_stmts[0]);
    const ret_val_node = pt.getNode(tree.nodeIndex(ret_node));
    const ret_arr = tree.getNodes(tree.nodeSpan(ret_val_node));
    try testing.expectEqual(@as(usize, 2), ret_arr.len);

    // next val until done?
    const s3 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqual(ast.Tag.while_stmt, s3.tag);
    const ws3 = tree.whileStmt(s3);
    try testing.expectEqual(true, ws3.is_until);

    const while3_body = pt.getNode(ws3.body);
    const while3_stmts = tree.getNodes(tree.block(while3_body).stmts);
    const next_node = pt.getNode(while3_stmts[0]);
    const next_val = pt.getNode(tree.nodeIndex(next_node));
    try testing.expectEqualStrings("val", tree.getString(@as(ast.StringId, @enumFromInt(next_val.data))));
}

test "KupCAD Parser: Multi-Interpolation String with Expressions and Method Calls" {
    const source = "\"Part: #{part.name} at X:#{part.x + 10}, Y:#{part.y}\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);
    try testing.expectEqual(ast.Tag.interpolated_string, expr.tag);

    const parts = tree.getNodes(tree.nodeSpan(expr));
    try testing.expectEqual(@as(usize, 7), parts.len);

    try testing.expectEqualStrings("Part: ", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(parts[0]).data))));
    try testing.expectEqualStrings("name", tree.getString(tree.methodCall(pt.getNode(parts[1])).method_name));
    try testing.expectEqualStrings(" at X:", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(parts[2]).data))));
    try testing.expectEqual(ast.BinaryOp.add, tree.binaryExpr(pt.getNode(parts[3])).op);
    try testing.expectEqualStrings(", Y:", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(parts[4]).data))));
    try testing.expectEqualStrings("y", tree.getString(tree.methodCall(pt.getNode(parts[5])).method_name));
    try testing.expectEqualStrings("", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(parts[6]).data))));
}

test "KupCAD Parser: Module Namespaces with Doc Comments and Class Constructors" {
    const source =
        \\module Enclosures
        \\  # @label Thickness of enclosure walls
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
    try testing.expectEqual(ast.Tag.module_stmt, mod_node.tag);
    const ms = tree.moduleStmt(mod_node);
    try testing.expectEqualStrings("Enclosures", tree.getString(ms.name));

    const body_node = pt.getNode(ms.body);
    const block_stmts = tree.getNodes(tree.block(body_node).stmts);
    try testing.expectEqual(@as(usize, 2), block_stmts.len);

    // Statement 0: Doc Comment
    const doc_node = pt.getNode(block_stmts[0]);
    try testing.expectEqual(ast.Tag.docstring, doc_node.tag);
    const doc = tree.docString(doc_node);
    try testing.expectEqualStrings("label", tree.getString(doc.tag_name));
    try testing.expectEqualStrings("Thickness of enclosure walls", tree.getString(doc.content));

    // Statement 1: Class Statement
    const class_stmt = pt.getNode(block_stmts[1]);
    const cs = tree.classStmt(class_stmt);
    try testing.expectEqualStrings("Box", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(cs.name).data))));
    try testing.expectEqualStrings("Base", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(cs.super_class).data))));

    const class_body = pt.getNode(cs.body);
    const class_stmts = tree.getNodes(tree.block(class_body).stmts);
    const init_def = pt.getNode(class_stmts[0]);
    const init_ds = tree.defStmt(init_def);
    try testing.expectEqualStrings("initialize", tree.getString(init_ds.name));

    const init_params = tree.getParams(init_ds.params);
    try testing.expectEqualStrings("w", tree.getString(init_params[0].name));
    try testing.expectEqual(@as(f64, 100.0), tree.number(pt.getNode(init_params[0].default_value)));
}

test "KupCAD Parser: Command-Syntax Calls with Trailing Statement Modifiers" {
    const source = "cube x: 10, y: 20 unless draft_mode?";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.if_stmt, stmt.tag);
    const ifs = tree.ifStmt(stmt);
    try testing.expectEqual(true, ifs.is_unless);
    try testing.expectEqualStrings("draft_mode?", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ifs.condition).data))));

    const then_branch = pt.getNode(ifs.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const inner_stmt = pt.getNode(then_stmts[0]);
    try testing.expectEqual(ast.Tag.method_call, inner_stmt.tag);
    const mc = tree.methodCall(inner_stmt);
    try testing.expectEqualStrings("cube", tree.getString(mc.method_name));

    const args = tree.getNamedArgs(mc.args);
    try testing.expectEqual(@as(usize, 2), args.len);
}

test "KupCAD Parser: Safe Navigation inside Ternary Conditions and Global Scope Resolution" {
    const source = "target = part&.is_valid? ? part.build() : ::CAD::Default.build()";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const a = tree.assignment(stmt);
    try testing.expectEqualStrings("target", tree.getString(a.name));

    const ternary = pt.getNode(a.value);
    try testing.expectEqual(ast.Tag.ternary_op, ternary.tag);
    const t = tree.ternaryExpr(ternary);

    // Condition: part&.is_valid?
    const cond = pt.getNode(t.condition);
    const cond_mc = tree.methodCall(cond);
    try testing.expectEqualStrings("is_valid?", tree.getString(cond_mc.method_name));
    try testing.expectEqual(true, cond_mc.is_safe);

    // Else branch: ::CAD::Default.build()
    const else_branch = pt.getNode(t.else_branch);
    const else_mc = tree.methodCall(else_branch);
    try testing.expectEqualStrings("build", tree.getString(else_mc.method_name));

    const receiver_ns = pt.getNode(else_mc.receiver);
    try testing.expectEqual(ast.Tag.namespace_access, receiver_ns.tag);

    const path = tree.getStringLists(tree.nodeSpan(receiver_ns));
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
    try testing.expectEqual(ast.Tag.def_stmt, def_node.tag);
    const ds = tree.defStmt(def_node);
    try testing.expectEqual(true, ds.is_class_method);
    try testing.expectEqualStrings("create", tree.getString(ds.name));

    // Def body wrapped in begin_stmt due to rescue clause
    const begin_node = pt.getNode(ds.body);
    try testing.expectEqual(ast.Tag.begin_stmt, begin_node.tag);
    const bs = tree.beginStmt(begin_node);

    const rescues = tree.getRescueClauses(bs.rescues);
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
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("transform", tree.getString(mc.method_name));

    const args = tree.getNamedArgs(mc.args);
    try testing.expectEqual(@as(usize, 2), args.len);

    const arg0 = pt.getNode(args[0].value);
    const arr1 = tree.getNodes(tree.nodeSpan(arg0));
    try testing.expectEqual(@as(usize, 3), arr1.len);
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(arr1[0]).data))));

    const arg1 = pt.getNode(args[1].value);
    const arr2 = tree.getNodes(tree.nodeSpan(arg1));
    try testing.expectEqual(@as(usize, 3), arr2.len);
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(arr2[0])));
}

test "KupCAD Parser: Destructuring with Nested Tuple Patterns" {
    const source = "points.each do |(x, y), index|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);
    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 2), params.len);

    const param0 = pt.getNode(params[0]);
    const tuple_param = tree.getNodes(tree.nodeSpan(param0));
    try testing.expectEqual(@as(usize, 2), tuple_param.len);
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(tuple_param[0]).data))));
    try testing.expectEqualStrings("y", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(tuple_param[1]).data))));
    try testing.expectEqualStrings("index", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(params[1]).data))));
}

test "KupCAD Parser: Complex Nested Modifier Precedence" {
    const source = "x = y ? true : false unless z == 1";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const root_idx = try pt.parser.parseStatement();
    const root = pt.getNode(root_idx);

    try testing.expectEqual(ast.Tag.if_stmt, root.tag);
    const ifs = tree.ifStmt(root);
    try testing.expectEqual(true, ifs.is_unless);

    const cond = pt.getNode(ifs.condition);
    const bin_cond = tree.binaryExpr(cond);
    try testing.expectEqual(ast.BinaryOp.equal, bin_cond.op);
    try testing.expectEqualStrings("z", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_cond.left).data))));

    const then_branch = pt.getNode(ifs.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const assign = pt.getNode(then_stmts[0]);
    const a = tree.assignment(assign);
    try testing.expectEqualStrings("x", tree.getString(a.name));
    try testing.expectEqual(ast.Tag.ternary_op, pt.getNode(a.value).tag);
}

test "KupCAD Parser: Global Namespace Property Assignment" {
    const source = "::App::Config.debug_mode = true";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.property_assignment, stmt.tag);
    const pa = tree.propertyAssignment(stmt);
    try testing.expectEqualStrings("debug_mode", tree.getString(pa.property));
    try testing.expectEqual(true, tree.boolean(pt.getNode(pa.value)));

    const target_ns = pt.getNode(pa.target);
    try testing.expectEqual(ast.Tag.namespace_access, target_ns.tag);
    const path = tree.getStringLists(tree.nodeSpan(target_ns));
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
    const mc3 = tree.methodCall(stmt);
    try testing.expectEqualStrings("chamfer", tree.getString(mc3.method_name));
    try testing.expectEqual(true, mc3.is_safe);

    const translate_call = pt.getNode(mc3.receiver);
    const mc2 = tree.methodCall(translate_call);
    try testing.expectEqualStrings("translate", tree.getString(mc2.method_name));
    try testing.expectEqual(true, mc2.is_safe);

    const cut_call = pt.getNode(mc2.receiver);
    const mc1 = tree.methodCall(cut_call);
    try testing.expectEqualStrings("cut", tree.getString(mc1.method_name));
    try testing.expectEqual(true, mc1.is_safe);

    const part_ident = pt.getNode(mc1.receiver);
    try testing.expectEqualStrings("part", tree.getString(@as(ast.StringId, @enumFromInt(part_ident.data))));
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
    const arr_node = pt.getNode(tree.assignment(stmt).value);
    const arr = tree.getNodes(tree.nodeSpan(arr_node));
    try testing.expectEqual(@as(usize, 3), arr.len);

    const item0 = pt.getNode(arr[0]);
    try testing.expectEqual(ast.Tag.array_literal, item0.tag);
    const item0_elems = tree.getNodes(tree.nodeSpan(item0));
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(item0_elems[0])));

    const item1 = pt.getNode(arr[1]);
    try testing.expectEqual(ast.Tag.range, item1.tag);
    const r1 = tree.range(item1);
    try testing.expectEqual(true, r1.is_exclusive);

    const item2 = pt.getNode(arr[2]);
    try testing.expectEqual(ast.Tag.array_literal, item2.tag);
    const item2_elems = tree.getNodes(tree.nodeSpan(item2));
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(item2_elems[0]).data))));
}

test "KupCAD Parser: Chained Comparisons (Ruby-style Equality)" {
    const source = "a == b and c != d or e >= f";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const bin_or = tree.binaryExpr(stmt);

    try testing.expectEqual(ast.BinaryOp.logical_or, bin_or.op);

    const r_expr = pt.getNode(bin_or.right);
    const bin_r = tree.binaryExpr(r_expr);
    try testing.expectEqual(ast.BinaryOp.greater_equal, bin_r.op);
    try testing.expectEqualStrings("e", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_r.left).data))));
    try testing.expectEqualStrings("f", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin_r.right).data))));

    const l_expr = pt.getNode(bin_or.left);
    const bin_l = tree.binaryExpr(l_expr);
    try testing.expectEqual(ast.BinaryOp.logical_and, bin_l.op);
    const l_left = pt.getNode(bin_l.left);
    try testing.expectEqual(ast.BinaryOp.equal, tree.binaryExpr(l_left).op);
    const l_right = pt.getNode(bin_l.right);
    try testing.expectEqual(ast.BinaryOp.not_equal, tree.binaryExpr(l_right).op);
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
    const ds = tree.defStmt(def_node);
    const body_node = pt.getNode(ds.body);
    const stmts = tree.getNodes(tree.block(body_node).stmts);

    const if_node = pt.getNode(stmts[0]);
    const ifs = tree.ifStmt(if_node);
    try testing.expectEqualStrings("skip?", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ifs.condition).data))));

    const then_branch = pt.getNode(ifs.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const next_node = pt.getNode(then_stmts[0]);

    const next_vals_node = pt.getNode(tree.nodeIndex(next_node));
    const next_vals = tree.getNodes(tree.nodeSpan(next_vals_node));
    try testing.expectEqual(@as(usize, 3), next_vals.len);
    try testing.expectEqual(@as(f64, 2.0), tree.number(pt.getNode(next_vals[1])));

    const ret_node = pt.getNode(stmts[1]);
    const ret_vals_node = pt.getNode(tree.nodeIndex(ret_node));
    const ret_vals = tree.getNodes(tree.nodeSpan(ret_vals_node));
    try testing.expectEqual(@as(usize, 2), ret_vals.len);
    try testing.expectEqual(true, tree.boolean(pt.getNode(ret_vals[0])));
    try testing.expectEqualStrings("done", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ret_vals[1]).data))));
}

test "KupCAD Parser: Property and Index Assignment Interactions" {
    const source = "config.sections[0].name = \"Top\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.property_assignment, stmt.tag);
    const pa = tree.propertyAssignment(stmt);

    try testing.expectEqualStrings("name", tree.getString(pa.property));
    try testing.expectEqualStrings("Top", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(pa.value).data))));

    const target = pt.getNode(pa.target);
    try testing.expectEqual(ast.Tag.index_access, target.tag);
    const ia = tree.indexAccess(target);
    try testing.expectEqual(@as(f64, 0.0), tree.number(pt.getNode(ia.index)));

    const access_target = pt.getNode(ia.target);
    try testing.expectEqual(ast.Tag.method_call, access_target.tag);
    const mc = tree.methodCall(access_target);
    try testing.expectEqualStrings("sections", tree.getString(mc.method_name));
    try testing.expectEqualStrings("config", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(mc.receiver).data))));
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
    try testing.expectEqual(ast.Tag.begin_stmt, node.tag);
    const bs = tree.beginStmt(node);

    const rescues = tree.getRescueClauses(bs.rescues);
    try testing.expectEqual(@as(usize, 2), rescues.len);

    // First rescue
    const r0_errors = tree.getStringLists(rescues[0].errors);
    try testing.expectEqual(@as(usize, 2), r0_errors.len);
    try testing.expectEqualStrings("MathError", tree.getString(r0_errors[0]));
    try testing.expectEqualStrings("DivByZero", tree.getString(r0_errors[1]));
    try testing.expectEqualStrings("e", tree.getString(rescues[0].variable));

    const r0_body = pt.getNode(rescues[0].body);
    const r0_stmts = tree.getNodes(tree.block(r0_body).stmts);
    try testing.expectEqual(@as(f64, 1.0), tree.number(pt.getNode(r0_stmts[0])));

    // Second rescue (catch-all)
    const r1_errors = tree.getStringLists(rescues[1].errors);
    try testing.expectEqual(@as(usize, 0), r1_errors.len);
    try testing.expectEqualStrings("fallback", tree.getString(rescues[1].variable));

    const r1_body = pt.getNode(rescues[1].body);
    const r1_stmts = tree.getNodes(tree.block(r1_body).stmts);
    try testing.expectEqual(@as(f64, 2.0), tree.number(pt.getNode(r1_stmts[0])));
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

    try testing.expectEqual(ast.Tag.while_stmt, stmt.tag);
    const ws = tree.whileStmt(stmt);
    try testing.expectEqual(true, ws.is_until);
    try testing.expectEqualStrings("done?", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ws.condition).data))));

    const body_node = pt.getNode(ws.body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    const wrapped_begin = pt.getNode(body_stmts[0]);
    try testing.expectEqual(ast.Tag.begin_stmt, wrapped_begin.tag);
    const bs = tree.beginStmt(wrapped_begin);

    const begin_body = pt.getNode(bs.body);
    const begin_stmts = tree.getNodes(tree.block(begin_body).stmts);
    try testing.expectEqualStrings("step", tree.getString(tree.methodCall(pt.getNode(begin_stmts[0])).method_name));
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
    const a1 = tree.assignment(s1);
    try testing.expectEqualStrings("@width", tree.getString(a1.name));

    const s2_idx = try pt.parser.parseStatement();
    const s2 = pt.getNode(s2_idx);
    const a2 = tree.assignment(s2);
    try testing.expectEqualStrings("$offset", tree.getString(a2.name));

    const s2_val = pt.getNode(a2.value);
    const bin = tree.binaryExpr(s2_val);
    const left = pt.getNode(bin.left);
    try testing.expectEqualStrings("@width", tree.getString(@as(ast.StringId, @enumFromInt(left.data))));
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
    const arr_node = pt.getNode(tree.assignment(s1).value);
    const arr_elems = tree.getNodes(tree.nodeSpan(arr_node));
    try testing.expectEqual(@as(usize, 0), arr_elems.len);

    const s2_idx = try pt.parser.parseStatement();
    const s2 = pt.getNode(s2_idx);
    const hash_node = pt.getNode(tree.assignment(s2).value);
    const hash_entries = tree.getHashEntries(tree.nodeSpan(hash_node));
    try testing.expectEqual(@as(usize, 0), hash_entries.len);

    const s3_idx = try pt.parser.parseStatement();
    const s3 = pt.getNode(s3_idx);
    const mc = tree.methodCall(s3);
    try testing.expectEqualStrings("run", tree.getString(mc.method_name));

    const block = pt.getNode(mc.block);
    const block_stmts = tree.getNodes(tree.block(block).stmts);
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
    const a1 = tree.assignment(stmt1);
    try testing.expectEqualStrings("arr_max", tree.getString(a1.name));

    const call1 = pt.getNode(a1.value);
    try testing.expectEqual(ast.Tag.method_call, call1.tag);
    const mc1 = tree.methodCall(call1);
    try testing.expectEqualStrings("max", tree.getString(mc1.method_name));

    const receiver1 = pt.getNode(mc1.receiver);
    try testing.expectEqual(ast.Tag.array_literal, receiver1.tag);
    const rec1_elems = tree.getNodes(tree.nodeSpan(receiver1));
    try testing.expectEqual(@as(usize, 3), rec1_elems.len);
    try testing.expectEqual(@as(f64, 1.0), tree.number(pt.getNode(rec1_elems[0])));

    // hash_keys = { a: 1 }.keys()
    const stmt2_idx = try pt.parser.parseStatement();
    const stmt2 = pt.getNode(stmt2_idx);
    const a2 = tree.assignment(stmt2);
    try testing.expectEqualStrings("hash_keys", tree.getString(a2.name));

    const call2 = pt.getNode(a2.value);
    try testing.expectEqual(ast.Tag.method_call, call2.tag);
    const mc2 = tree.methodCall(call2);
    try testing.expectEqualStrings("keys", tree.getString(mc2.method_name));

    const receiver2 = pt.getNode(mc2.receiver);
    try testing.expectEqual(ast.Tag.hash_literal, receiver2.tag);
    const rec2_entries = tree.getHashEntries(tree.nodeSpan(receiver2));
    try testing.expectEqual(@as(usize, 1), rec2_entries.len);
    try testing.expectEqualStrings("a", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(rec2_entries[0].key).data))));
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

    const line_index = try @import("../../core/line_index.zig").LineIndex.init(pt.arena.allocator(), source);

    // LineIndex returns a 0-based index. "x = 10 + }" is on physical line 2, which corresponds to index 1.
    try testing.expectEqual(@as(u32, 1), line_index.getLine(diag.loc.offset));
    try testing.expectEqual(@as(u32, 11), line_index.getUtf8Column(diag.loc.offset));
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
    try testing.expectEqual(ast.Tag.module_stmt, mod_stmt.tag);
    const ms = tree.moduleStmt(mod_stmt);
    try testing.expectEqualStrings("Math", tree.getString(ms.name));

    const mod_body = pt.getNode(ms.body);
    const mod_stmts = tree.getNodes(tree.block(mod_body).stmts);
    try testing.expectEqual(@as(usize, 0), mod_stmts.len);

    const class_stmt_idx = try pt.parser.parseStatement();
    const class_stmt = pt.getNode(class_stmt_idx);
    try testing.expectEqual(ast.Tag.class_stmt, class_stmt.tag);
    const cs = tree.classStmt(class_stmt);
    const name_node = pt.getNode(cs.name);
    try testing.expectEqualStrings("Vector", tree.getString(@as(ast.StringId, @enumFromInt(name_node.data))));

    const class_body = pt.getNode(cs.body);
    const class_stmts = tree.getNodes(tree.block(class_body).stmts);
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
    try testing.expectEqual(ast.Tag.property_assignment, stmt.tag);
    const pa = tree.propertyAssignment(stmt);
    try testing.expectEqualStrings("callback", tree.getString(pa.property));

    const lambda = pt.getNode(pa.value);
    try testing.expectEqual(ast.Tag.lambda_expr, lambda.tag);
    const le = tree.lambdaExpr(lambda);

    const params = tree.getParams(le.params);
    try testing.expectEqualStrings("event", tree.getString(params[0].name));

    const lambda_body = pt.getNode(le.body);
    const lambda_stmts = tree.getNodes(tree.block(lambda_body).stmts);
    const call_node = pt.getNode(lambda_stmts[0]);
    try testing.expectEqualStrings("log", tree.getString(tree.methodCall(call_node).method_name));
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
    const ds = tree.defStmt(stmt);

    const def_body = pt.getNode(ds.body);
    const def_stmts = tree.getNodes(tree.block(def_body).stmts);
    const body_stmt = pt.getNode(def_stmts[0]);
    try testing.expectEqual(ast.Tag.if_stmt, body_stmt.tag);

    const ifs = tree.ifStmt(body_stmt);
    const then_branch = pt.getNode(ifs.then_branch);
    const then_stmts = tree.getNodes(tree.block(then_branch).stmts);
    const ret_stmt = pt.getNode(then_stmts[0]);
    try testing.expectEqual(ast.Tag.return_stmt, ret_stmt.tag);
    try testing.expectEqual(ast.NodeIndex.none, tree.nodeIndex(ret_stmt));
}

test "KupCAD Parser: Inline Array/Hash Creation within Command Arguments" {
    const source = "extrude [0, 0, 10], opts: { twist: 360 }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.method_call, stmt.tag);
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("extrude", tree.getString(mc.method_name));

    const args = tree.getNamedArgs(mc.args);
    try testing.expectEqual(@as(usize, 2), args.len);

    // Arg 1 is Array
    const arg0 = pt.getNode(args[0].value);
    try testing.expectEqual(ast.Tag.array_literal, arg0.tag);
    const arg0_elems = tree.getNodes(tree.nodeSpan(arg0));
    try testing.expectEqual(@as(usize, 3), arg0_elems.len);

    // Arg 2 is Hash
    try testing.expectEqualStrings("opts", tree.getString(args[1].name));
    const arg1 = pt.getNode(args[1].value);
    try testing.expectEqual(ast.Tag.hash_literal, arg1.tag);
    const arg1_entries = tree.getHashEntries(tree.nodeSpan(arg1));
    try testing.expectEqualStrings("twist", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(arg1_entries[0].key).data))));
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
    const cs = tree.caseStmt(stmt);
    const branches = tree.getWhenBranches(cs.when_branches);
    try testing.expectEqual(@as(usize, 1), branches.len);

    const conditions = tree.getNodes(branches[0].conditions);
    try testing.expectEqual(@as(usize, 3), conditions.len);
    try testing.expectEqualStrings("hex", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(conditions[0]).data))));
    try testing.expectEqualStrings("square", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(conditions[1]).data))));
    try testing.expectEqualStrings("round", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(conditions[2]).data))));
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
    const ds = tree.defStmt(stmt);
    try testing.expectEqualStrings("build", tree.getString(ds.name));

    const params = tree.getParams(ds.params);
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("width", tree.getString(params[0].name));
    try testing.expectEqualStrings("height", tree.getString(params[1].name));
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(params[1].default_value)));
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
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("translate", tree.getString(mc.method_name));

    const args = tree.getNamedArgs(mc.args);
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
    const stmts = tree.getNodes(tree.block(result).stmts);

    // Thanks to AST Poisoning, all 3 statements are mapped!
    try testing.expectEqual(@as(usize, 3), stmts.len);

    const valid_stmt = pt.getNode(stmts[2]);
    try testing.expectEqualStrings("z", tree.getString(tree.assignment(valid_stmt).name));

    // Two syntax errors were recorded inside the poisoned nodes
    try testing.expectEqual(@as(usize, 2), pt.parser.diagnostics.list.items.len);
}

test "KupCAD Parser: Nested String Interpolation AST" {
    const source = "\"Outer #{ \"Inner #{1 + 2}\" } end\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseExpression(.none);
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.interpolated_string, stmt.tag);

    const outer_parts = tree.getNodes(tree.nodeSpan(stmt));
    try testing.expectEqualStrings("Outer ", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(outer_parts[0]).data))));

    const inner_node = pt.getNode(outer_parts[1]);
    try testing.expectEqual(ast.Tag.interpolated_string, inner_node.tag);

    const inner_parts = tree.getNodes(tree.nodeSpan(inner_node));
    try testing.expectEqualStrings("Inner ", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(inner_parts[0]).data))));
    try testing.expectEqual(ast.BinaryOp.add, tree.binaryExpr(pt.getNode(inner_parts[1])).op);
    try testing.expectEqualStrings("", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(inner_parts[2]).data))));
    try testing.expectEqualStrings(" end", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(outer_parts[2]).data))));
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
    const a = tree.assignment(stmt);
    try testing.expectEqualStrings("val", tree.getString(a.name));

    const begin_expr = pt.getNode(a.value);
    try testing.expectEqual(ast.Tag.begin_stmt, begin_expr.tag);
    const bs = tree.beginStmt(begin_expr);

    const rescues = tree.getRescueClauses(bs.rescues);
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
    const cs = tree.caseStmt(stmt);
    const branches = tree.getWhenBranches(cs.when_branches);
    try testing.expectEqual(@as(usize, 2), branches.len);

    const branch0_body = pt.getNode(branches[0].body);
    const b0_stmts = tree.getNodes(tree.block(branch0_body).stmts);
    const call0 = pt.getNode(b0_stmts[0]);
    try testing.expectEqualStrings("cube", tree.getString(tree.methodCall(call0).method_name));

    const branch1_body = pt.getNode(branches[1].body);
    const b1_stmts = tree.getNodes(tree.block(branch1_body).stmts);
    const call1 = pt.getNode(b1_stmts[0]);
    try testing.expectEqualStrings("sphere", tree.getString(tree.methodCall(call1).method_name));
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
    try testing.expectEqual(ast.Tag.method_call, stmt.tag);
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("grid", tree.getString(mc.method_name));

    const args = tree.getNamedArgs(mc.args);
    try testing.expectEqual(@as(usize, 2), args.len);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(params[0]).data))));
}

test "KupCAD Parser: Multi-Assignment with Raw Comma Values" {
    const source = "x, y = 10, 20";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.multiple_assignment, stmt.tag);
    const ma = tree.multipleAssignment(stmt);

    const val_node = pt.getNode(ma.value);
    const rhs_array = tree.getNodes(tree.nodeSpan(val_node));
    try testing.expectEqual(@as(usize, 2), rhs_array.len);
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(rhs_array[0])));
    try testing.expectEqual(@as(f64, 20.0), tree.number(pt.getNode(rhs_array[1])));
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
    const rhs_arr1_node = pt.getNode(tree.assignment(stmt1).value);
    const rhs_arr1 = tree.getNodes(tree.nodeSpan(rhs_arr1_node));
    try testing.expectEqual(@as(usize, 3), rhs_arr1.len);
    try testing.expectEqual(@as(f64, 30.0), tree.number(pt.getNode(rhs_arr1[2])));

    // Verify `points[0] = 5, 5`
    const stmt2_idx = try pt.parser.parseStatement();
    const stmt2 = pt.getNode(stmt2_idx);
    const ia = tree.indexAssignment(stmt2);
    const rhs_arr2_node = pt.getNode(ia.value);
    const rhs_arr2 = tree.getNodes(tree.nodeSpan(rhs_arr2_node));
    try testing.expectEqual(@as(usize, 2), rhs_arr2.len);
    try testing.expectEqual(@as(f64, 5.0), tree.number(pt.getNode(rhs_arr2[1])));
}

test "KupCAD Parser: Multi-Dimensional Array Indexing" {
    const source = "val = matrix[x, y]";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const index_node = pt.getNode(tree.assignment(stmt).value);

    try testing.expectEqual(ast.Tag.index_access, index_node.tag);
    const ia = tree.indexAccess(index_node);

    const index_args_node = pt.getNode(ia.index);
    const index_args = tree.getNodes(tree.nodeSpan(index_args_node));
    try testing.expectEqual(@as(usize, 2), index_args.len);
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(index_args[0]).data))));
    try testing.expectEqualStrings("y", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(index_args[1]).data))));
}

test "KupCAD Parser: Empty Parentheses evaluate to Nil" {
    const source = "call() do\n ()\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block_node = pt.getNode(mc.block);
    const block_stmts = tree.getNodes(tree.block(block_node).stmts);
    const block_stmt = pt.getNode(block_stmts[0]);

    try testing.expectEqual(ast.Tag.nil, block_stmt.tag);
}

test "KupCAD Parser: Chained and Compound Assignment Right-Associativity" {
    const source1 = "a = b = c = 10";
    var pt1 = try KTest.init(source1);
    defer pt1.deinit();
    const tree1 = &pt1.parser.b.tree;

    const stmt1_idx = try pt1.parser.parseStatement();
    const stmt1 = pt1.getNode(stmt1_idx);
    const a1 = tree1.assignment(stmt1);

    try testing.expectEqualStrings("a", tree1.getString(a1.name));
    const assign_b = pt1.getNode(a1.value);
    try testing.expectEqual(ast.Tag.assignment, assign_b.tag);
    const ab = tree1.assignment(assign_b);
    try testing.expectEqualStrings("b", tree1.getString(ab.name));

    const assign_c = pt1.getNode(ab.value);
    try testing.expectEqual(ast.Tag.assignment, assign_c.tag);
    const ac = tree1.assignment(assign_c);
    try testing.expectEqualStrings("c", tree1.getString(ac.name));
    try testing.expectEqual(@as(f64, 10.0), tree1.number(pt1.getNode(ac.value)));

    const source2 = "x += y += 5";
    var pt2 = try KTest.init(source2);
    defer pt2.deinit();
    const tree2 = &pt2.parser.b.tree;

    const stmt2_idx = try pt2.parser.parseStatement();
    const stmt2 = pt2.getNode(stmt2_idx);
    const a2 = tree2.assignment(stmt2);

    try testing.expectEqualStrings("x", tree2.getString(a2.name));
    try testing.expectEqual(ast.BinaryOp.add, a2.op.?);

    const assign_y = pt2.getNode(a2.value);
    const ay = tree2.assignment(assign_y);
    try testing.expectEqual(ast.BinaryOp.add, ay.op.?);
    try testing.expectEqualStrings("y", tree2.getString(ay.name));
    try testing.expectEqual(@as(f64, 5.0), tree2.number(pt2.getNode(ay.value)));
}

test "KupCAD Parser: Nested Ternary Right-Associativity" {
    const source = "a ? b : c ? d : e";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);

    try testing.expectEqual(ast.Tag.ternary_op, expr.tag);
    const t1 = tree.ternaryExpr(expr);
    try testing.expectEqualStrings("a", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(t1.condition).data))));
    try testing.expectEqualStrings("b", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(t1.then_branch).data))));

    const else_ternary = pt.getNode(t1.else_branch);
    try testing.expectEqual(ast.Tag.ternary_op, else_ternary.tag);
    const t2 = tree.ternaryExpr(else_ternary);
    try testing.expectEqualStrings("c", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(t2.condition).data))));
    try testing.expectEqualStrings("d", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(t2.then_branch).data))));
    try testing.expectEqualStrings("e", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(t2.else_branch).data))));
}

test "KupCAD Parser: Multiple Unary Prefix Right-Associativity" {
    const source = "!!true";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);
    const un1 = tree.unaryExpr(expr);

    try testing.expectEqual(ast.UnaryOp.not, un1.op);
    const inner_not = pt.getNode(un1.operand);
    const un2 = tree.unaryExpr(inner_not);
    try testing.expectEqual(ast.UnaryOp.not, un2.op);
    try testing.expectEqual(true, tree.boolean(pt.getNode(un2.operand)));
}

test "KupCAD Parser: Ruby 3.1 Shorthand Hash Syntax" {
    const source = "opts = { width:, height: }";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    const hash_node = pt.getNode(tree.assignment(stmt).value);
    const hash = tree.getHashEntries(tree.nodeSpan(hash_node));
    try testing.expectEqual(@as(usize, 2), hash.len);

    try testing.expectEqualStrings("width", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[0].key).data))));
    try testing.expectEqualStrings("width", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[0].value).data))));

    try testing.expectEqualStrings("height", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[1].key).data))));
    try testing.expectEqualStrings("height", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(hash[1].value).data))));
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
    try testing.expectEqual(ast.Tag.docstring, doc_stmt1.tag);
    const doc = tree.docString(doc_stmt1);

    try testing.expectEqualStrings("deprecated", tree.getString(doc.tag_name));
    try testing.expectEqualStrings("Use {#my_new_method} instead of this method because\nit uses a library that is no longer supported.", tree.getString(doc.content));

    const def_stmt_idx = try pt.parser.parseStatement();
    const def_stmt = pt.getNode(def_stmt_idx);
    try testing.expectEqual(ast.Tag.def_stmt, def_stmt.tag);
    try testing.expectEqualStrings("mymethod", tree.getString(tree.defStmt(def_stmt).name));
}

test "KupCAD Parser: AST Node offset and length calculation for LSP" {
    const source = "val = 10 + 200";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.Tag.assignment, stmt.tag);
    try testing.expectEqual(@as(u32, 0), pt.parser.tokens.starts[stmt.main_token]);

    const bin_expr = pt.getNode(tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.binary_op, bin_expr.tag);
    try testing.expectEqual(@as(u32, 6), pt.parser.tokens.starts[bin_expr.main_token]);

    const bin_payload = tree.binaryExpr(bin_expr);
    const left_num = pt.getNode(bin_payload.left);
    try testing.expectEqual(ast.Tag.number, left_num.tag);
    try testing.expectEqual(@as(u32, 6), pt.parser.tokens.starts[left_num.main_token]);
    try testing.expectEqual(@as(u32, 2), pt.parser.tokens.lengths[left_num.main_token]);

    const right_num = pt.getNode(bin_payload.right);
    try testing.expectEqual(ast.Tag.number, right_num.tag);
    try testing.expectEqual(@as(u32, 11), pt.parser.tokens.starts[right_num.main_token]);
    try testing.expectEqual(@as(u32, 3), pt.parser.tokens.lengths[right_num.main_token]);
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

    try testing.expectEqual(ast.Tag.def_stmt, stmt.tag);
    try testing.expectEqual(@as(u32, 0), pt.parser.tokens.starts[stmt.main_token]);

    const body_node = pt.getNode(tree.defStmt(stmt).body);
    const body_stmts = tree.getNodes(tree.block(body_node).stmts);
    try testing.expectEqual(@as(usize, 1), body_stmts.len);

    const math_expr = pt.getNode(body_stmts[0]);
    try testing.expectEqual(ast.Tag.binary_op, math_expr.tag);
    try testing.expectEqual(@as(u32, 33), pt.parser.tokens.starts[math_expr.main_token]);

    try testing.expectEqual(@as(usize, 1), pt.parser.comments.items.len);
    const captured_comment = pt.parser.comments.items[0];
    try testing.expectEqualStrings("# a comment", captured_comment.lexeme);
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
    try testing.expectEqual(ast.Tag.while_stmt, while_stmt.tag);
    const ws1 = tree.whileStmt(while_stmt);
    try testing.expectEqual(false, ws1.is_until);

    const while_body = pt.getNode(ws1.body);
    const while_stmts = tree.getNodes(tree.block(while_body).stmts);
    const while_assign = pt.getNode(while_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.add, tree.assignment(while_assign).op.?);

    const until_stmt_idx = try pt.parser.parseStatement();
    const until_stmt = pt.getNode(until_stmt_idx);
    try testing.expectEqual(ast.Tag.while_stmt, until_stmt.tag);
    const ws2 = tree.whileStmt(until_stmt);
    try testing.expectEqual(true, ws2.is_until);

    const until_body = pt.getNode(ws2.body);
    const until_stmts = tree.getNodes(tree.block(until_body).stmts);
    const until_assign = pt.getNode(until_stmts[0]);
    try testing.expectEqual(ast.BinaryOp.subtract, tree.assignment(until_assign).op.?);
}

test "KupCAD Parser: Index Compound Assignment" {
    const source = "arr[0] *= 5";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.Tag.index_assignment, stmt.tag);
    const ia = tree.indexAssignment(stmt);
    try testing.expectEqualStrings("arr", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(ia.target).data))));
    try testing.expectEqual(@as(f64, 0.0), tree.number(pt.getNode(ia.index)));
    try testing.expectEqual(ast.BinaryOp.multiply, ia.op.?);
    try testing.expectEqual(@as(f64, 5.0), tree.number(pt.getNode(ia.value)));
}

test "KupCAD Parser: Property Compound Assignment" {
    const source = "obj.x += 10";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.Tag.property_assignment, stmt.tag);
    const pa = tree.propertyAssignment(stmt);
    try testing.expectEqualStrings("obj", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(pa.target).data))));
    try testing.expectEqualStrings("x", tree.getString(pa.property));
    try testing.expectEqual(ast.BinaryOp.add, pa.op.?);
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(pa.value)));
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
    const bin1 = tree.binaryExpr(p1);
    try testing.expectEqual(ast.BinaryOp.subtract, bin1.op);
    try testing.expectEqualStrings("part", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin1.left).data))));
    try testing.expectEqualStrings("part", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(bin1.right).data))));

    const p2 = pt.getNode(try pt.parser.parseStatement());
    try testing.expectEqualStrings("cube", tree.getString(tree.methodCall(p2).method_name));

    try testing.expectEqual(@as(usize, 0), pt.parser.diagnostics.list.items.len);
}

test "KupCAD Parser: Deeply Nested String Interpolation gracefully fails" {
    const source = "\"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"deep\" }\" }\" }\" }\" }\" }\" }\" }\" }\"";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const result = pt.parser.parseExpression(.none);
    try testing.expectError(error.UnexpectedToken, result);

    try testing.expect(pt.parser.diagnostics.list.items.len > 0);
    try testing.expectEqualStrings("Interpolation depth exceeded", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Trailing commas in multiple assignment" {
    const source = "x, y, = 10, 20";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.Tag.multiple_assignment, stmt.tag);
    const ma = tree.multipleAssignment(stmt);
    const lhs = tree.getLhsExprs(ma.lhs);

    try testing.expectEqual(@as(usize, 2), lhs.len);
    try testing.expectEqualStrings("x", tree.getString(lhs[0].name));
    try testing.expectEqualStrings("y", tree.getString(lhs[1].name));

    const rhs_val = pt.getNode(ma.value);
    const rhs_array = tree.getNodes(tree.nodeSpan(rhs_val));
    try testing.expectEqual(@as(usize, 2), rhs_array.len);
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(rhs_array[0])));
    try testing.expectEqual(@as(f64, 20.0), tree.number(pt.getNode(rhs_array[1])));
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

    try testing.expectEqual(ast.Tag.number, expr.tag);
    try testing.expectEqual(@as(f64, 1.0), pt.parser.b.tree.number(expr));
}

test "KupCAD Parser: Right-Associative Assignment Chaining" {
    var pt = try KTest.init("a = b = c = 1");
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);

    try testing.expectEqual(ast.Tag.assignment, stmt.tag);
    const a_assign = tree.assignment(stmt);
    try testing.expectEqualStrings("a", tree.getString(a_assign.name));

    const b_assign_node = pt.getNode(a_assign.value);
    try testing.expectEqual(ast.Tag.assignment, b_assign_node.tag);
    const b_assign = tree.assignment(b_assign_node);
    try testing.expectEqualStrings("b", tree.getString(b_assign.name));

    const c_assign_node = pt.getNode(b_assign.value);
    try testing.expectEqual(ast.Tag.assignment, c_assign_node.tag);
    const c_assign = tree.assignment(c_assign_node);
    try testing.expectEqualStrings("c", tree.getString(c_assign.name));

    try testing.expectEqual(@as(f64, 1.0), tree.number(pt.getNode(c_assign.value)));
}

test "KupCAD Parser: Empty Arrays and Hashes" {
    var pt = try KTest.init("[]\n{}");
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const arr_idx = try pt.parser.parseStatement();
    const arr = pt.getNode(arr_idx);
    try testing.expectEqual(ast.Tag.array_literal, arr.tag);
    try testing.expectEqual(@as(usize, 0), tree.getNodes(tree.nodeSpan(arr)).len);

    const hash_idx = try pt.parser.parseStatement();
    const hash = pt.getNode(hash_idx);
    try testing.expectEqual(ast.Tag.hash_literal, hash.tag);
    try testing.expectEqual(@as(usize, 0), tree.getHashEntries(tree.nodeSpan(hash)).len);
}

test "AST Builder: Contiguous String Interner tightly packs bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const id1 = try b.intern("hello");
    const id2 = try b.intern("world");
    const id3 = try b.intern("zig");

    // Verify IDs are distinct
    try testing.expect(id1 != id2);
    try testing.expect(id2 != id3);

    // Verify contiguous packing! (5 + 5 + 3 = 13 bytes total)
    try testing.expectEqual(@as(usize, 13), b.tree.string_bytes.items.len);
    try testing.expectEqualStrings("helloworldzig", b.tree.string_bytes.items);

    // Verify retrieval uses the spans correctly to extract the exact slices
    try testing.expectEqualStrings("hello", b.tree.getString(id1));
    try testing.expectEqualStrings("world", b.tree.getString(id2));
    try testing.expectEqualStrings("zig", b.tree.getString(id3));
}

test "AST Builder: String Interner handles empty strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const id = try b.intern("");

    // Should map directly to the `.none` enum without allocating
    try testing.expectEqual(ast.StringId.none, id);
    try testing.expectEqualStrings("", b.tree.getString(id));

    // Ensure absolutely no bytes were appended to the global buffer
    try testing.expectEqual(@as(usize, 0), b.tree.string_bytes.items.len);
}

test "AST Builder: String Interner Hash Map resizing is safe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Insert enough strings to force the HashMap to resize/rehash.
    // If our custom InternContext is broken, this will panic or corrupt data.
    var ids: [1000]ast.StringId = undefined;
    for (0..1000) |i| {
        const str = try std.fmt.allocPrint(arena.allocator(), "var_{d}", .{i});
        ids[i] = try b.intern(str);
    }

    // Verify retrieval after resizes
    for (0..1000) |i| {
        const expected = try std.fmt.allocPrint(arena.allocator(), "var_{d}", .{i});
        try testing.expectEqualStrings(expected, b.tree.getString(ids[i]));
    }
}

test "AST Builder: Number Deduplication merges identical floats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    // Parse the same logical value 4 times using different syntactic representations
    _ = try b.number("10", 0);
    _ = try b.number("10.0", 0);
    _ = try b.number("0xA", 0);
    _ = try b.number("1_0", 0);

    // Parse a different value
    _ = try b.number("99", 0);

    // It should have only allocated exactly 2 floats in the tree payload
    try testing.expectEqual(@as(usize, 2), b.tree.numbers.items.len);
    try testing.expectEqual(@as(f64, 10.0), b.tree.numbers.items[0]);
    try testing.expectEqual(@as(f64, 99.0), b.tree.numbers.items[1]);
}

test "Parser: parses shorthand hash keys" {
    const source = "{ width: 50, height: 20 }";
    var t = try KTest.init(source);
    defer t.deinit();

    const node_idx = try t.parser.parseExpression(.none);
    const node = t.getNode(node_idx);

    try testing.expectEqual(ast.Tag.hash_literal, node.tag);
    const entries = t.parser.b.tree.getHashEntries(t.parser.b.tree.nodeSpan(node));
    try testing.expectEqual(@as(usize, 2), entries.len);

    const key1 = t.parser.b.tree.getNode(entries[0].key).?;
    try testing.expectEqual(ast.Tag.symbol, key1.tag);
    try testing.expectEqualStrings("width", t.parser.b.tree.getString(@as(ast.StringId, @enumFromInt(key1.data))));

    const val1 = t.parser.b.tree.getNode(entries[0].value).?;
    try testing.expectEqual(@as(f64, 50.0), t.parser.b.tree.number(val1));
}

test "KupCAD Parser: Block with splat (*args) parameters" {
    const source = "list.each do |first, *rest|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 2), params.len);

    // first
    const param0 = pt.getNode(params[0]);
    try testing.expectEqual(ast.Tag.identifier, param0.tag);
    try testing.expectEqualStrings("first", tree.getString(@as(ast.StringId, @enumFromInt(param0.data))));

    // *rest
    const param1 = pt.getNode(params[1]);
    try testing.expectEqual(ast.Tag.splat_expr, param1.tag);
    const rest_ident = pt.getNode(@as(ast.NodeIndex, @enumFromInt(param1.data)));
    try testing.expectEqual(ast.Tag.identifier, rest_ident.tag);
    try testing.expectEqualStrings("rest", tree.getString(@as(ast.StringId, @enumFromInt(rest_ident.data))));
}

test "KupCAD Parser: Block with double splat (**kwargs) parameters" {
    const source = "list.each do |val, **opts|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 2), params.len);

    // val
    const param0 = pt.getNode(params[0]);
    try testing.expectEqual(ast.Tag.identifier, param0.tag);
    try testing.expectEqualStrings("val", tree.getString(@as(ast.StringId, @enumFromInt(param0.data))));

    // **opts
    const param1 = pt.getNode(params[1]);
    try testing.expectEqual(ast.Tag.double_splat_expr, param1.tag);
    const opts_ident = pt.getNode(@as(ast.NodeIndex, @enumFromInt(param1.data)));
    try testing.expectEqual(ast.Tag.identifier, opts_ident.tag);
    try testing.expectEqualStrings("opts", tree.getString(@as(ast.StringId, @enumFromInt(opts_ident.data))));
}

test "KupCAD Parser: Block with extreme complex arguments |(x, y), *args, **kw|" {
    const source = "list.each do |(x, y), *args, **kw|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 3), params.len);

    // (x, y) -> .array_literal
    const param0 = pt.getNode(params[0]);
    try testing.expectEqual(ast.Tag.array_literal, param0.tag);
    const tuple_elems = tree.getNodes(tree.nodeSpan(param0));
    try testing.expectEqual(@as(usize, 2), tuple_elems.len);

    // *args -> .splat_expr
    const param1 = pt.getNode(params[1]);
    try testing.expectEqual(ast.Tag.splat_expr, param1.tag);
    const args_ident = pt.getNode(@as(ast.NodeIndex, @enumFromInt(param1.data)));
    try testing.expectEqualStrings("args", tree.getString(@as(ast.StringId, @enumFromInt(args_ident.data))));

    // **kw -> .double_splat_expr
    const param2 = pt.getNode(params[2]);
    try testing.expectEqual(ast.Tag.double_splat_expr, param2.tag);
    const kw_ident = pt.getNode(@as(ast.NodeIndex, @enumFromInt(param2.data)));
    try testing.expectEqualStrings("kw", tree.getString(@as(ast.StringId, @enumFromInt(kw_ident.data))));
}

test "KupCAD Parser: Block with empty parameter pipes (||)" {
    const source = "list.each do ||\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);

    // Should parse cleanly but yield 0 parameters
    try testing.expectEqual(@as(usize, 0), params.len);
}

test "KupCAD Parser: Block with nested destructuring |((x, y), z)|" {
    const source = "list.each do |((x, y), z)|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 1), params.len); // 1 top-level param

    // Outer tuple
    const outer_tuple = pt.getNode(params[0]);
    try testing.expectEqual(ast.Tag.array_literal, outer_tuple.tag);
    const outer_elems = tree.getNodes(tree.nodeSpan(outer_tuple));
    try testing.expectEqual(@as(usize, 2), outer_elems.len);

    // Inner tuple (x, y)
    const inner_tuple = pt.getNode(outer_elems[0]);
    try testing.expectEqual(ast.Tag.array_literal, inner_tuple.tag);
    const inner_elems = tree.getNodes(tree.nodeSpan(inner_tuple));
    try testing.expectEqual(@as(usize, 2), inner_elems.len);
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(inner_elems[0]).data))));
    try testing.expectEqualStrings("y", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(inner_elems[1]).data))));

    // z
    const z_ident = pt.getNode(outer_elems[1]);
    try testing.expectEqual(ast.Tag.identifier, z_ident.tag);
    try testing.expectEqualStrings("z", tree.getString(@as(ast.StringId, @enumFromInt(z_ident.data))));
}

test "KupCAD Parser: Block with single element destructuring |(x,)|" {
    const source = "list.each do |(x,)|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 1), params.len);

    const tuple = pt.getNode(params[0]);
    try testing.expectEqual(ast.Tag.array_literal, tuple.tag);

    // The trailing comma should be ignored, leaving exactly 1 element
    const elems = tree.getNodes(tree.nodeSpan(tuple));
    try testing.expectEqual(@as(usize, 1), elems.len);
    try testing.expectEqualStrings("x", tree.getString(@as(ast.StringId, @enumFromInt(pt.getNode(elems[0]).data))));
}

test "KupCAD Parser: Block with default positional parameters" {
    const source = "list.each do |x = 10, y = 20|\nend";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    const mc = tree.methodCall(stmt);

    const block = pt.getNode(mc.block);
    const params = tree.getNodes(tree.block(block).params);
    try testing.expectEqual(@as(usize, 2), params.len);

    const param0 = pt.getNode(params[0]);
    try testing.expectEqual(ast.Tag.assignment, param0.tag);
    const assign0 = tree.assignment(param0);
    try testing.expectEqualStrings("x", tree.getString(assign0.name));
    try testing.expectEqual(@as(f64, 10.0), tree.number(pt.getNode(assign0.value)));
}

test "KupCAD Parser: Inline visibility modifiers (private def / public def)" {
    const source =
        \\class Guard
        \\  public def open() true end
        \\  private def secret() 123 end
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const class_stmt_idx = try pt.parser.parseStatement();
    const class_stmt = pt.getNode(class_stmt_idx);
    const cs = tree.classStmt(class_stmt);

    const class_body = pt.getNode(cs.body);
    const stmts = tree.getNodes(tree.block(class_body).stmts);

    const pub_def = tree.defStmt(pt.getNode(stmts[0]));
    try testing.expectEqual(false, pub_def.is_private);
    try testing.expectEqualStrings("open", tree.getString(pub_def.name));

    const priv_def = tree.defStmt(pt.getNode(stmts[1]));
    try testing.expectEqual(true, priv_def.is_private);
    try testing.expectEqualStrings("secret", tree.getString(priv_def.name));
}

test "KupCAD Parser: Attribute accessors AST parsing" {
    const source =
        \\class Widget
        \\  attr_accessor :width, :height
        \\  attr_reader "label"
        \\  attr_writer :color
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.class_stmt, stmt.tag);

    const cs = tree.classStmt(stmt);
    const body_node = pt.getNode(cs.body);
    const stmts = tree.getNodes(tree.block(body_node).stmts);

    try testing.expectEqual(@as(usize, 3), stmts.len);
    try testing.expectEqual(ast.Tag.method_call, pt.getNode(stmts[0]).tag);
    try testing.expectEqualStrings("attr_accessor", tree.getString(tree.methodCall(pt.getNode(stmts[0])).method_name));
}

test "KupCAD Parser: Multi-Line Fluent API with Trailing Inline Comments" {
    const source =
        \\part
        \\  .translate(x: 10) # Trailing comment 1
        \\  .rotate(z: 45)    # Trailing comment 2
        \\  .chamfer()
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.method_call, stmt.tag);

    // Check final method in the chain
    const mc = tree.methodCall(stmt);
    try testing.expectEqualStrings("chamfer", tree.getString(mc.method_name));

    // Check middle method
    const prev_call = pt.getNode(mc.receiver);
    const prev_mc = tree.methodCall(prev_call);
    try testing.expectEqualStrings("rotate", tree.getString(prev_mc.method_name));
}

test "KupCAD Parser: Ruby Double-Quoted Escape Sequences" {
    const source = "\"Line 1\\nLine 2\\tTabbed\\\"Quote\\\\Hash\\#\"";
    var pt = try KTest.init(source);
    defer pt.deinit();

    const expr_idx = try pt.parser.parseExpression(.none);
    const expr = pt.getNode(expr_idx);

    try testing.expectEqual(ast.Tag.string, expr.tag);
    const str_id = @as(ast.StringId, @enumFromInt(expr.data));
    const parsed_str = pt.parser.b.tree.getString(str_id);

    try testing.expectEqualStrings("Line 1\nLine 2\tTabbed\"Quote\\Hash#", parsed_str);
}

test "KupCAD Parser: Standalone Export of Methods and Variables" {
    // Exporting lowercase identifiers (methods/variables) mixed with a constant
    const source = "export my_func, local_var, SomeClass";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.export_stmt, stmt.tag);

    const es = tree.exportStmt(stmt);
    const symbols = tree.getStringLists(es.symbols);

    // Verifies the parser correctly accepts `.ident` tokens without throwing UnexpectedToken
    try testing.expectEqual(@as(usize, 3), symbols.len);
    try testing.expectEqualStrings("my_func", tree.getString(symbols[0]));
    try testing.expectEqualStrings("local_var", tree.getString(symbols[1]));
    try testing.expectEqualStrings("SomeClass", tree.getString(symbols[2]));

    // Standalone exports don't have a `from` path
    try testing.expectEqual(ast.StringId.none, es.path);
}

test "KupCAD Parser: Braced Export of Methods and Variables" {
    const source = "export { calculate_area, PI } from \"./math.kup\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.export_stmt, stmt.tag);

    const es = tree.exportStmt(stmt);
    try testing.expectEqualStrings("./math.kup", tree.getString(es.path));

    const symbols = tree.getStringLists(es.symbols);
    try testing.expectEqual(@as(usize, 2), symbols.len);

    // Verifies braced lists successfully process `.ident` and `.constant`
    try testing.expectEqualStrings("calculate_area", tree.getString(symbols[0]));
    try testing.expectEqualStrings("PI", tree.getString(symbols[1]));
}

test "KupCAD Parser: Standalone Namespace Exports" {
    const source = "export Test::Example, Math::Vector";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.export_stmt, stmt.tag);

    const es = tree.exportStmt(stmt);
    const symbols = tree.getStringLists(es.symbols);

    // Verifies the `::` namespaces were perfectly merged into single string IDs
    try testing.expectEqual(@as(usize, 2), symbols.len);
    try testing.expectEqualStrings("Test::Example", tree.getString(symbols[0]));
    try testing.expectEqualStrings("Math::Vector", tree.getString(symbols[1]));

    // Standalone exports don't have a `from` path
    try testing.expectEqual(ast.StringId.none, es.path);
}

test "KupCAD Parser: Braced Namespace Imports" {
    const source = "import { Custom::Example, Base::Math::Vector } from \"./lib.kup\"";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt_idx = try pt.parser.parseStatement();
    const stmt = pt.getNode(stmt_idx);
    try testing.expectEqual(ast.Tag.import_stmt, stmt.tag);

    const is_stmt = tree.importStmt(stmt);
    try testing.expectEqualStrings("./lib.kup", tree.getString(is_stmt.path));

    const symbols = tree.getStringLists(is_stmt.symbols);
    try testing.expectEqual(@as(usize, 2), symbols.len);

    // Verifies braced lists also successfully process `::` tokens
    try testing.expectEqualStrings("Custom::Example", tree.getString(symbols[0]));
    try testing.expectEqualStrings("Base::Math::Vector", tree.getString(symbols[1]));
}

test "KupCAD Parser: Rejects Nested Import/Export Statements" {
    const source =
        \\class Wrapper
        \\  export Test::Example
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    // The parser will process the class, increment scope_depth, and then fail on `export`
    _ = pt.parser.parseProgram() catch {};

    try testing.expect(pt.parser.diagnostics.list.items.len > 0);
    try testing.expectEqualStrings("Import and Export statements are only allowed at the top level", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Rejects Imports inside Def Blocks" {
    const source =
        \\def fetch_data()
        \\  import { Data } from "data.kup"
        \\end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    _ = pt.parser.parseProgram() catch {};

    try testing.expect(pt.parser.diagnostics.list.items.len > 0);
    try testing.expectEqualStrings("Import and Export statements are only allowed at the top level", pt.parser.diagnostics.list.items[0].message);
}

test "KupCAD Parser: Semicolons act as valid statement terminators" {
    // Proves the parser can execute multiple statements on a single line separated by semicolons
    const source = "x = 10; y = 20";
    var pt = try KTest.init(source);
    defer pt.deinit();
    const tree = &pt.parser.b.tree;

    const stmt1_idx = try pt.parser.parseStatement();
    const stmt1 = pt.getNode(stmt1_idx);
    try testing.expectEqual(ast.Tag.assignment, stmt1.tag);
    try testing.expectEqualStrings("x", tree.getString(tree.assignment(stmt1).name));

    // The semicolon should have safely bypassed the parser to the next statement
    const stmt2_idx = try pt.parser.parseStatement();
    const stmt2 = pt.getNode(stmt2_idx);
    try testing.expectEqual(ast.Tag.assignment, stmt2.tag);
    try testing.expectEqualStrings("y", tree.getString(tree.assignment(stmt2).name));
}

test "KupCAD Parser: Swallows redundant semicolons like blank lines" {
    // Proves that skipIgnored() handles multiple trailing semicolons without error
    const source = "a = 1;;;; b = 2";
    var pt = try KTest.init(source);
    defer pt.deinit();

    _ = try pt.parser.parseStatement(); // a = 1

    // Without the parser update, this second call would throw UnexpectedToken
    const stmt2_idx = try pt.parser.parseStatement(); // b = 2
    const stmt2 = pt.getNode(stmt2_idx);
    try testing.expectEqual(ast.Tag.assignment, stmt2.tag);
    try testing.expectEqualStrings("b", pt.parser.b.tree.getString(pt.parser.b.tree.assignment(stmt2).name));
}

test "KupCAD Parser: Compiles single-line empty class and def stubs" {
    // A highly common use case for semicolons
    const source =
        \\class Part; end
        \\def noop; end
    ;
    var pt = try KTest.init(source);
    defer pt.deinit();

    // Class Stub
    const stmt1_idx = try pt.parser.parseStatement();
    const stmt1 = pt.getNode(stmt1_idx);
    try testing.expectEqual(ast.Tag.class_stmt, stmt1.tag);

    // Def Stub
    const stmt2_idx = try pt.parser.parseStatement();
    const stmt2 = pt.getNode(stmt2_idx);
    try testing.expectEqual(ast.Tag.def_stmt, stmt2.tag);
}
