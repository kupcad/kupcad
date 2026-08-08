const std = @import("std");
const testing = std.testing;

const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;

const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;

const ast = @import("../../core/ast.zig");

fn getNode(parser: *Parser, idx: ast.NodeIndex) *const ast.Node {
    return parser.b.tree.getNode(idx).?;
}

fn getStr(parser: *Parser, id: ast.StringId) []const u8 {
    return parser.b.tree.getString(id);
}

fn getNodes(parser: *Parser, span: ast.Span) []const ast.NodeIndex {
    return parser.b.tree.getNodes(span);
}

fn getParams(parser: *Parser, span: ast.Span) []const ast.Param {
    return parser.b.tree.getParams(span);
}

fn getNamedArgs(parser: *Parser, span: ast.Span) []const ast.NamedArg {
    return parser.b.tree.getNamedArgs(span);
}

fn getForBindings(parser: *Parser, span: ast.Span) []const ast.ForBinding {
    return parser.b.tree.getForBindings(span);
}

test "OpenSCAD Parser: Module definition and CSG Tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\module housing(w=50) {
        \\  difference() {
        \\    cube([w, w, 20]);
        \\    #cylinder(r=w/4, h=21);
        \\  }
        \\}
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const mod_idx = try parser.parseStatement();
    const mod_node = getNode(&parser, mod_idx);

    // Module lowers to DefStmt
    const def_stmt = parser.b.tree.def_stmts.items[mod_node.data];
    try testing.expectEqualStrings("housing", getStr(&parser, def_stmt.name));
    try testing.expectEqualStrings("w", getStr(&parser, getParams(&parser, def_stmt.params)[0].name));

    const body_node = getNode(&parser, def_stmt.body);
    const body_block = parser.b.tree.blocks.items[body_node.data];
    const diff_call = getNode(&parser, getNodes(&parser, body_block.stmts)[0]);
    try testing.expectEqualStrings("difference", getStr(&parser, parser.b.tree.methodCall(diff_call).method_name));

    const diff_block = getNode(&parser, parser.b.tree.methodCall(diff_call).block);
    const diff_block_payload = parser.b.tree.blocks.items[diff_block.data];
    const diff_children = getNodes(&parser, diff_block_payload.stmts);

    const cube_node = getNode(&parser, diff_children[0]);
    try testing.expectEqualStrings("cube", getStr(&parser, parser.b.tree.methodCall(cube_node).method_name));

    const mod_call = getNode(&parser, diff_children[1]);
    // Modifiers lower to method calls with the child trapped in a block!
    try testing.expectEqualStrings("debug", getStr(&parser, parser.b.tree.methodCall(mod_call).method_name));

    const mod_call_block = getNode(&parser, parser.b.tree.methodCall(mod_call).block);
    const mod_call_block_payload = parser.b.tree.blocks.items[mod_call_block.data];
    const mod_call_child0 = getNode(&parser, getNodes(&parser, mod_call_block_payload.stmts)[0]);
    try testing.expectEqualStrings("cylinder", getStr(&parser, parser.b.tree.methodCall(mod_call_child0).method_name));
}

test "OpenSCAD Parser: For Loop and Range [start:step:end]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "for (i = [0 : 2 : 10]) { cube(i); }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node_idx = try parser.parseStatement();
    const node = getNode(&parser, node_idx);

    const for_stmt = parser.b.tree.for_stmts.items[node.data];
    const bindings = getForBindings(&parser, for_stmt.bindings);
    try testing.expectEqualStrings("i", getStr(&parser, bindings[0].name));
    const range = getNode(&parser, bindings[0].range);

    const range_payload = parser.b.tree.ranges.items[range.data];

    const start = getNode(&parser, range_payload.start);
    try testing.expectEqual(@as(f64, 0.0), parser.b.tree.numbers.items[start.data]);

    const step = getNode(&parser, range_payload.step);
    try testing.expectEqual(@as(f64, 2.0), parser.b.tree.numbers.items[step.data]);

    const end = getNode(&parser, range_payload.end);
    try testing.expectEqual(@as(f64, 10.0), parser.b.tree.numbers.items[end.data]);
}

test "OpenSCAD Parser: Function Definition & Includes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\include <BOSL2/std.scad>
        \\function double(x) = x * 2;
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const inc_idx = try parser.parseStatement();
    const inc_node = getNode(&parser, inc_idx);
    // Includes lower to ImportStmt
    const import_stmt = parser.b.tree.import_stmts.items[inc_node.data];
    try testing.expectEqualStrings("BOSL2/std.scad", getStr(&parser, import_stmt.path));

    const fn_idx = try parser.parseStatement();
    const fn_node = getNode(&parser, fn_idx);
    const def_stmt = parser.b.tree.def_stmts.items[fn_node.data];
    try testing.expectEqualStrings("double", getStr(&parser, def_stmt.name));

    const fn_body = getNode(&parser, def_stmt.body);
    try testing.expectEqual(ast.BinaryOp.multiply, parser.b.tree.binaryExpr(fn_body).op);
}

test "OpenSCAD Parser: Vector Comprehension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "pts = [ for (x = [0:5]) x * 2 ];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const assign_idx = try parser.parseStatement();
    const assign_node = getNode(&parser, assign_idx);

    const comp_node = getNode(&parser, parser.b.tree.assignment(assign_node).value);
    // Comprehensions lower to Array Literals with nested loop nodes
    const for_node = getNode(&parser, getNodes(&parser, parser.b.tree.getSpan(comp_node.data))[0]);

    try testing.expectEqual(ast.Tag.for_stmt, for_node.tag);
    const for_stmt = parser.b.tree.for_stmts.items[for_node.data];
    try testing.expectEqualStrings("x", getStr(&parser, getForBindings(&parser, for_stmt.bindings)[0].name));

    // The body of the FOR is the mathematical expression
    const math_node = getNode(&parser, for_stmt.body);
    try testing.expectEqual(ast.BinaryOp.multiply, parser.b.tree.binaryExpr(math_node).op);
}

test "OpenSCAD Parser: Unbraced Operator Module Chaining" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "translate([10, 0, 0]) rotate([0, 0, 90]) cube(10);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const top_idx = try parser.parseStatement();
    const top_node = getNode(&parser, top_idx);

    // Verify outer `translate`
    try testing.expectEqualStrings("translate", getStr(&parser, parser.b.tree.methodCall(top_node).method_name));

    const top_block = getNode(&parser, parser.b.tree.methodCall(top_node).block);
    const rotate_node = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[top_block.data].stmts)[0]);

    // Verify middle `rotate`
    try testing.expectEqualStrings("rotate", getStr(&parser, parser.b.tree.methodCall(rotate_node).method_name));

    const rotate_block = getNode(&parser, parser.b.tree.methodCall(rotate_node).block);
    const cube_node = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[rotate_block.data].stmts)[0]);

    // Verify leaf `cube`
    try testing.expectEqualStrings("cube", getStr(&parser, parser.b.tree.methodCall(cube_node).method_name));
    try testing.expectEqual(ast.NodeIndex.none, parser.b.tree.methodCall(cube_node).block);
}

test "OpenSCAD Parser: Scoped Block and Variable Shadowing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\a = 10;
        \\{
        \\  a = 20;
        \\  cube(a);
        \\}
        \\cube(a);
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const program_idx = try parser.parseProgram();
    const program = getNode(&parser, program_idx);

    const stmts = getNodes(&parser, parser.b.tree.blocks.items[program.data].stmts);

    // Statement 0: Outer assignment `a = 10`
    const stmt0 = getNode(&parser, stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, parser.b.tree.assignment(stmt0).name));

    const stmt0_val = getNode(&parser, parser.b.tree.assignment(stmt0).value);
    try testing.expectEqual(@as(f64, 10.0), parser.b.tree.numbers.items[stmt0_val.data]);

    // Statement 1: Standalone scope block
    const stmt1 = getNode(&parser, stmts[1]);
    const inner_stmts = getNodes(&parser, parser.b.tree.blocks.items[stmt1.data].stmts);

    const inner_stmt0 = getNode(&parser, inner_stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, parser.b.tree.assignment(inner_stmt0).name));

    const inner_stmt0_val = getNode(&parser, parser.b.tree.assignment(inner_stmt0).value);
    try testing.expectEqual(@as(f64, 20.0), parser.b.tree.numbers.items[inner_stmt0_val.data]);

    const inner_stmt1 = getNode(&parser, inner_stmts[1]);
    try testing.expectEqualStrings("cube", getStr(&parser, parser.b.tree.methodCall(inner_stmt1).method_name));

    // Statement 2: Outer `cube(a)`
    const stmt2 = getNode(&parser, stmts[2]);
    try testing.expectEqualStrings("cube", getStr(&parser, parser.b.tree.methodCall(stmt2).method_name));
}

test "OpenSCAD Parser: Special Variables and Children Calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\$fn = 60;
        \\module array() {
        \\  for (i = [0 : $children - 1]) {
        \\    translate([i * 10, 0, 0]) children(i);
        \\  }
        \\}
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const p1_idx = try parser.parseStatement();
    const p1 = getNode(&parser, p1_idx);
    try testing.expectEqualStrings("$fn", getStr(&parser, parser.b.tree.assignment(p1).name));

    const mod_idx = try parser.parseStatement();
    const mod = getNode(&parser, mod_idx);
    try testing.expectEqualStrings("array", getStr(&parser, parser.b.tree.def_stmts.items[mod.data].name));

    const mod_body = getNode(&parser, parser.b.tree.def_stmts.items[mod.data].body);
    const for_node = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[mod_body.data].stmts)[0]);

    const for_stmt = parser.b.tree.for_stmts.items[for_node.data];
    const range = getNode(&parser, getForBindings(&parser, for_stmt.bindings)[0].range);
    const range_end = getNode(&parser, parser.b.tree.ranges.items[range.data].end);

    const range_end_left = getNode(&parser, parser.b.tree.binaryExpr(range_end).left);
    try testing.expectEqualStrings("$children", getStr(&parser, @as(ast.StringId, @enumFromInt(range_end_left.data))));

    const for_body = getNode(&parser, for_stmt.body);
    const trans_node = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[for_body.data].stmts)[0]);

    const trans_block = getNode(&parser, parser.b.tree.methodCall(trans_node).block);
    const child_call = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[trans_block.data].stmts)[0]);
    try testing.expectEqualStrings("children", getStr(&parser, parser.b.tree.methodCall(child_call).method_name));
}

test "OpenSCAD Parser: Assert and Echo Prefixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "echo(\"Rendering\", size = 20) assert(size > 0) cube(size);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const echo_idx = try parser.parseStatement();
    const echo_node = getNode(&parser, echo_idx);
    try testing.expectEqualStrings("echo", getStr(&parser, parser.b.tree.methodCall(echo_node).method_name));

    const echo_block = getNode(&parser, parser.b.tree.methodCall(echo_node).block);
    const assert_node = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[echo_block.data].stmts)[0]);
    try testing.expectEqualStrings("assert", getStr(&parser, parser.b.tree.methodCall(assert_node).method_name));

    const assert_block = getNode(&parser, parser.b.tree.methodCall(assert_node).block);
    const cube_node = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[assert_block.data].stmts)[0]);
    try testing.expectEqualStrings("cube", getStr(&parser, parser.b.tree.methodCall(cube_node).method_name));
}

test "OpenSCAD Parser: Let and If Expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "x = let(a = 10, b = 2) if (a > b) a else b;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    // Validate target assignment
    try testing.expectEqualStrings("x", getStr(&parser, parser.b.tree.assignment(stmt).name));

    // Validate Let Expression lowers to Block Scope
    const let_block = getNode(&parser, parser.b.tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.block, let_block.tag);

    const let_stmts = getNodes(&parser, parser.b.tree.blocks.items[let_block.data].stmts);
    const let_assign0 = getNode(&parser, let_stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, parser.b.tree.assignment(let_assign0).name));

    // Validate Yield Expression (If Expression) at end of block
    const yield_node = getNode(&parser, let_stmts[2]);
    try testing.expectEqual(ast.Tag.if_stmt, yield_node.tag);

    const yield_if = parser.b.tree.ifStmt(yield_node);
    const then_branch = getNode(&parser, yield_if.then_branch);
    try testing.expectEqualStrings("a", getStr(&parser, @as(ast.StringId, @enumFromInt(then_branch.data))));

    const else_branch = getNode(&parser, yield_if.else_branch);
    try testing.expectEqualStrings("b", getStr(&parser, @as(ast.StringId, @enumFromInt(else_branch.data))));
}

test "OpenSCAD Parser: Local Quoted Includes and Unary Plus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\include "local_lib.scad"
        \\val = +5;
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    // Test Quoted Include Path lowers to Import
    const inc_idx = try parser.parseStatement();
    const inc_node = getNode(&parser, inc_idx);
    try testing.expectEqualStrings("local_lib.scad", getStr(&parser, parser.b.tree.import_stmts.items[inc_node.data].path));

    // Test Unary Plus
    const assign_idx = try parser.parseStatement();
    const assign_node = getNode(&parser, assign_idx);
    try testing.expectEqualStrings("val", getStr(&parser, parser.b.tree.assignment(assign_node).name));

    const assign_val = getNode(&parser, parser.b.tree.assignment(assign_node).value);
    try testing.expectEqual(ast.UnaryOp.positive, parser.b.tree.unaryExpr(assign_val).op);
}

test "OpenSCAD Parser: Expression-level Assert and Echo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = assert(a > 0) echo(a) a * 2;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    // Assigning to `val`
    try testing.expectEqualStrings("val", getStr(&parser, parser.b.tree.assignment(stmt).name));

    // Top expression lowers to a block with `assert` call and inner yield
    const assert_block = getNode(&parser, parser.b.tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.block, assert_block.tag);

    const assert_stmts = getNodes(&parser, parser.b.tree.blocks.items[assert_block.data].stmts);
    const assert_call = getNode(&parser, assert_stmts[0]);
    try testing.expectEqualStrings("assert", getStr(&parser, parser.b.tree.methodCall(assert_call).method_name));

    // Inner yield is another block for `echo`
    const echo_block = getNode(&parser, assert_stmts[1]);
    try testing.expectEqual(ast.Tag.block, echo_block.tag);

    const echo_stmts = getNodes(&parser, parser.b.tree.blocks.items[echo_block.data].stmts);
    const echo_call = getNode(&parser, echo_stmts[0]);
    try testing.expectEqualStrings("echo", getStr(&parser, parser.b.tree.methodCall(echo_call).method_name));

    // Yield expression of echo should be `a * 2`
    const math_node = getNode(&parser, echo_stmts[1]);
    try testing.expectEqual(ast.BinaryOp.multiply, parser.b.tree.binaryExpr(math_node).op);
}

test "OpenSCAD Parser: Array Literal Expansion (each)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "merged = [1, each sub_array, 4];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);
    const array_node = getNode(&parser, parser.b.tree.assignment(stmt).value);

    try testing.expectEqual(ast.Tag.array_literal, array_node.tag);
    const elements = getNodes(&parser, parser.b.tree.getSpan(array_node.data));
    try testing.expectEqual(@as(usize, 3), elements.len);

    const el0 = getNode(&parser, elements[0]);
    try testing.expectEqual(@as(f64, 1.0), parser.b.tree.numbers.items[el0.data]);

    // Verify the inner `each_expr` unpack node maps identically to KupCAD
    const el1 = getNode(&parser, elements[1]);
    try testing.expectEqual(ast.Tag.each_expr, el1.tag);

    const each_val = getNode(&parser, @as(ast.NodeIndex, @enumFromInt(el1.data)));
    try testing.expectEqualStrings("sub_array", getStr(&parser, @as(ast.StringId, @enumFromInt(each_val.data))));

    const el2 = getNode(&parser, elements[2]);
    try testing.expectEqual(@as(f64, 4.0), parser.b.tree.numbers.items[el2.data]);
}

test "OpenSCAD Parser: Comprehension with Else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "pts = [ for (i = [0:5]) if (i % 2 == 0) i else -i ];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);
    const comp_node = getNode(&parser, parser.b.tree.assignment(stmt).value);

    // The top node of the comprehension yield logic is the FOR statement
    const for_node = getNode(&parser, getNodes(&parser, parser.b.tree.getSpan(comp_node.data))[0]);
    const for_stmt = parser.b.tree.for_stmts.items[for_node.data];
    try testing.expectEqualStrings("i", getStr(&parser, getForBindings(&parser, for_stmt.bindings)[0].name));

    // The body of the FOR is the nested IF statement
    const if_node = getNode(&parser, for_stmt.body);
    const if_payload = parser.b.tree.ifStmt(if_node);

    const then_branch = getNode(&parser, if_payload.then_branch);
    try testing.expectEqualStrings("i", getStr(&parser, @as(ast.StringId, @enumFromInt(then_branch.data))));

    const else_branch = getNode(&parser, if_payload.else_branch);
    try testing.expectEqual(ast.UnaryOp.negate, parser.b.tree.unaryExpr(else_branch).op);
}

test "OpenSCAD Parser: Empty Arguments and Array Elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "translate([10, , 20]) cube(10, , 20);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node_idx = try parser.parseStatement();
    const node = getNode(&parser, node_idx);

    // Check empty array element inside arguments maps to undef
    const args0 = getNamedArgs(&parser, parser.b.tree.methodCall(node).args)[0];
    const arg0_val = getNode(&parser, args0.value);
    const arr = getNodes(&parser, parser.b.tree.getSpan(arg0_val.data));

    const arr0 = getNode(&parser, arr[0]);
    try testing.expectEqual(ast.Tag.number, arr0.tag);

    const arr1 = getNode(&parser, arr[1]);
    try testing.expectEqual(ast.Tag.undef, arr1.tag);

    const block = getNode(&parser, parser.b.tree.methodCall(node).block);
    const cube_call = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[block.data].stmts)[0]);
    const cube_args = getNamedArgs(&parser, parser.b.tree.methodCall(cube_call).args);

    const cube_arg1 = getNode(&parser, cube_args[1].value);
    try testing.expectEqual(ast.Tag.undef, cube_arg1.tag);
}

test "OpenSCAD Parser: Adjacency String Concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "echo(\"Path: \" \"to/file.stl\");";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node_idx = try parser.parseStatement();
    const node = getNode(&parser, node_idx);

    const args = getNamedArgs(&parser, parser.b.tree.methodCall(node).args);
    const arg0 = getNode(&parser, args[0].value);
    try testing.expectEqualStrings("Path: to/file.stl", getStr(&parser, @as(ast.StringId, @enumFromInt(arg0.data))));
}

test "OpenSCAD Parser: Trailing Commas Leniency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "module test(a, b, ) { let(x=1, y=2, ) cube(); }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);
    const def_stmt = parser.b.tree.def_stmts.items[stmt.data];

    try testing.expectEqualStrings("test", getStr(&parser, def_stmt.name));

    const params = getParams(&parser, def_stmt.params);
    try testing.expectEqual(@as(usize, 2), params.len); // Ignored trailing comma

    // Statement-level let() compiles into a scoped block!
    const body = getNode(&parser, def_stmt.body);
    const let_block = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[body.data].stmts)[0]);
    try testing.expectEqual(ast.Tag.block, let_block.tag);

    // Verify it ignored the comma and collected 2 assignments + 1 body statement
    const let_stmts = getNodes(&parser, parser.b.tree.blocks.items[let_block.data].stmts);
    try testing.expectEqual(@as(usize, 3), let_stmts.len);

    const let_stmt0 = getNode(&parser, let_stmts[0]);
    try testing.expectEqualStrings("x", getStr(&parser, parser.b.tree.assignment(let_stmt0).name));

    const let_stmt1 = getNode(&parser, let_stmts[1]);
    try testing.expectEqualStrings("y", getStr(&parser, parser.b.tree.assignment(let_stmt1).name));

    const let_stmt2 = getNode(&parser, let_stmts[2]);
    try testing.expectEqualStrings("cube", getStr(&parser, parser.b.tree.methodCall(let_stmt2).method_name));
}

test "OpenSCAD Parser: Mid-Expression Comments & Empty Statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "module foo() { ;; x = 10 /* offset */ + 5; ; }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const mod_idx = try parser.parseStatement();
    const mod_node = getNode(&parser, mod_idx);
    const mod_stmt = parser.b.tree.def_stmts.items[mod_node.data];

    const body = getNode(&parser, mod_stmt.body);
    const block_stmts = getNodes(&parser, parser.b.tree.blocks.items[body.data].stmts);
    // Only the actual assignment should survive the block
    try testing.expectEqual(@as(usize, 1), block_stmts.len);

    const assign = getNode(&parser, block_stmts[0]);
    try testing.expectEqualStrings("x", getStr(&parser, parser.b.tree.assignment(assign).name));

    const assign_val = getNode(&parser, parser.b.tree.assignment(assign).value);
    try testing.expectEqual(ast.BinaryOp.add, parser.b.tree.binaryExpr(assign_val).op);
}

test "OpenSCAD Parser: C-Style Hexadecimal Constants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = 0xFF;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    try testing.expectEqualStrings("val", getStr(&parser, parser.b.tree.assignment(stmt).name));

    const val = getNode(&parser, parser.b.tree.assignment(stmt).value);
    try testing.expectEqual(@as(f64, 255.0), parser.b.tree.numbers.items[val.data]);
}

test "OpenSCAD Parser: Leading-Dot Float Literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = .5 + .125;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    const math_node = getNode(&parser, parser.b.tree.assignment(stmt).value);
    const bin = parser.b.tree.binaryExpr(math_node);

    const left = getNode(&parser, bin.left);
    try testing.expectEqual(@as(f64, 0.5), parser.b.tree.numbers.items[left.data]);

    const right = getNode(&parser, bin.right);
    try testing.expectEqual(@as(f64, 0.125), parser.b.tree.numbers.items[right.data]);
}

test "OpenSCAD Parser: C-Style For Loops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "for (a = 0, b = 1; a < 10; a = a + 1, b = b * 2) cube(a);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node_idx = try parser.parseStatement();
    const node = getNode(&parser, node_idx);

    // Desugars down to an isolated block scope containing while loop
    try testing.expectEqual(ast.Tag.block, node.tag);

    const stmts = getNodes(&parser, parser.b.tree.blocks.items[node.data].stmts);

    // Check Multi-Init at start of block
    const stmt0 = getNode(&parser, stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, parser.b.tree.assignment(stmt0).name));

    const stmt1 = getNode(&parser, stmts[1]);
    try testing.expectEqualStrings("b", getStr(&parser, parser.b.tree.assignment(stmt1).name));

    // Check Condition of internal while loop
    const while_node = getNode(&parser, stmts[2]);
    try testing.expectEqual(ast.Tag.while_stmt, while_node.tag);
    const while_stmt = parser.b.tree.while_stmts.items[while_node.data];

    const cond = getNode(&parser, while_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.less, parser.b.tree.binaryExpr(cond).op);

    // Check updates appended to end of while loop body
    const while_body = getNode(&parser, while_stmt.body);
    const while_stmts = getNodes(&parser, parser.b.tree.blocks.items[while_body.data].stmts);

    const assign2 = getNode(&parser, while_stmts[1]);
    const assign2_val = getNode(&parser, parser.b.tree.assignment(assign2).value);
    try testing.expectEqual(ast.BinaryOp.add, parser.b.tree.binaryExpr(assign2_val).op);
}

test "OpenSCAD Parser: Function Literals (Anonymous)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "f = function(x, y) x * y;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    const func_lit = getNode(&parser, parser.b.tree.assignment(stmt).value);

    // Function literals compile down to Lambda Expressions!
    try testing.expectEqual(ast.Tag.lambda_expr, func_lit.tag);
    const lambda = parser.b.tree.lambda_exprs.items[func_lit.data];

    const params = getParams(&parser, lambda.params);
    try testing.expectEqualStrings("x", getStr(&parser, params[0].name));

    const body = getNode(&parser, lambda.body);
    try testing.expectEqual(ast.BinaryOp.multiply, parser.b.tree.binaryExpr(body).op);
}

test "OpenSCAD Parser: Diagnostics for Unexpected Token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // We intentionally use a bracket instead of a parenthesis
    const source = "cube(10 ];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const result = parser.parseStatement();

    // Assert it fails with the correct error
    try testing.expectError(error.UnexpectedToken, result);

    // Assert the diagnostic was captured
    try testing.expectEqual(@as(usize, 1), parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Expected 'r_paren', but found ']'", parser.diagnostics.list.items[0].message);
}

test "OpenSCAD Parser: Diagnostics for Invalid Expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // We intentionally start an expression with a stray multiplication symbol
    const source = "x = * 5;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const result = parser.parseStatement();

    try testing.expectError(error.InvalidExpression, result);
    try testing.expectEqual(@as(usize, 1), parser.diagnostics.list.items.len);
    try testing.expectEqualStrings("Invalid expression starting with '*'", parser.diagnostics.list.items[0].message);
}

test "OpenSCAD Parser: Deeply Nested Let Expressions & Chained Expression Modifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Tests multi-level `let` nesting combined with `assert` and `echo`
    const source = "val = let(a = 5) let(b = a * 2) assert(b > 0) echo(b) b + 1;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    try testing.expectEqualStrings("val", getStr(&parser, parser.b.tree.assignment(stmt).name));

    // Outer let: a = 5 (lowers to block)
    const let1 = getNode(&parser, parser.b.tree.assignment(stmt).value);
    try testing.expectEqual(ast.Tag.block, let1.tag);

    const let1_stmts = getNodes(&parser, parser.b.tree.blocks.items[let1.data].stmts);
    const let1_assign0 = getNode(&parser, let1_stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, parser.b.tree.assignment(let1_assign0).name));

    // Inner let: b = a * 2
    const let2 = getNode(&parser, let1_stmts[1]);
    const let2_stmts = getNodes(&parser, parser.b.tree.blocks.items[let2.data].stmts);

    const let2_assign0 = getNode(&parser, let2_stmts[0]);
    try testing.expectEqualStrings("b", getStr(&parser, parser.b.tree.assignment(let2_assign0).name));

    // Assert -> Echo -> Addition
    const assert_block = getNode(&parser, let2_stmts[1]);
    const assert_stmts = getNodes(&parser, parser.b.tree.blocks.items[assert_block.data].stmts);

    const assert_call = getNode(&parser, assert_stmts[0]);
    try testing.expectEqualStrings("assert", getStr(&parser, parser.b.tree.methodCall(assert_call).method_name));
}

test "OpenSCAD Parser: Children Module Invocation with Modulo Index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\module grid() {
        \\  for (i = [0:3]) {
        \\    translate([i * 10, 0, 0]) children(i % $children);
        \\  }
        \\}
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const mod_idx = try parser.parseStatement();
    const mod_node = getNode(&parser, mod_idx);
    const def_stmt = parser.b.tree.def_stmts.items[mod_node.data];
    try testing.expectEqualStrings("grid", getStr(&parser, def_stmt.name));

    const mod_body = getNode(&parser, def_stmt.body);
    const for_node = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[mod_body.data].stmts)[0]);
    const for_stmt = parser.b.tree.for_stmts.items[for_node.data];

    const for_body = getNode(&parser, for_stmt.body);
    const trans_call = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[for_body.data].stmts)[0]);
    try testing.expectEqualStrings("translate", getStr(&parser, parser.b.tree.methodCall(trans_call).method_name));

    const trans_block = getNode(&parser, parser.b.tree.methodCall(trans_call).block);
    const child_call = getNode(&parser, getNodes(&parser, parser.b.tree.blocks.items[trans_block.data].stmts)[0]);
    try testing.expectEqualStrings("children", getStr(&parser, parser.b.tree.methodCall(child_call).method_name));

    const args = getNamedArgs(&parser, parser.b.tree.methodCall(child_call).args);
    const arg_expr = getNode(&parser, args[0].value);
    try testing.expectEqual(ast.BinaryOp.modulo, parser.b.tree.binaryExpr(arg_expr).op);

    const left = getNode(&parser, parser.b.tree.binaryExpr(arg_expr).left);
    try testing.expectEqualStrings("i", getStr(&parser, @as(ast.StringId, @enumFromInt(left.data))));

    const right = getNode(&parser, parser.b.tree.binaryExpr(arg_expr).right);
    try testing.expectEqualStrings("$children", getStr(&parser, @as(ast.StringId, @enumFromInt(right.data))));
}

test "OpenSCAD Parser: Diagnostics Line and Column Tracking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\module box() {
        \\  cube(10);
        \\  cylinder(r=5, h=);
        \\}
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    _ = try parser.parseProgram();

    try testing.expectEqual(@as(usize, 1), parser.diagnostics.list.items.len);
    const diag = parser.diagnostics.list.items[0];

    // Validate error message
    try testing.expectEqualStrings("Invalid expression starting with ')'", diag.message);

    // Validate exact coordinates for LSP squigglies
    // Line 3: `  cylinder(r=5, h=);`
    // Col 19 is exactly the closing parenthesis `)`
    try testing.expectEqual(@as(u32, 3), diag.loc.line);
    try testing.expectEqual(@as(u32, 19), diag.loc.col);
}

test "OpenSCAD Parser: Error Recovery (synchronize)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\x = 10 * ];
        \\y = 20 + };
        \\z = 30;
    ;
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const result_idx = try parser.parseProgram();
    const result = getNode(&parser, result_idx);

    // The successful statement (z = 30;) was preserved
    try testing.expectEqual(@as(usize, 1), getNodes(&parser, parser.b.tree.blocks.items[result.data].stmts).len);

    // Both errors were captured
    try testing.expectEqual(@as(usize, 2), parser.diagnostics.list.items.len);
}
