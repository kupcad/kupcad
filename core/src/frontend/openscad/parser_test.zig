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
    try testing.expectEqualStrings("housing", getStr(&parser, mod_node.kind.def_stmt.name));
    try testing.expectEqualStrings("w", getStr(&parser, getParams(&parser, mod_node.kind.def_stmt.params)[0].name));

    const body_node = getNode(&parser, mod_node.kind.def_stmt.body);
    const diff_call = getNode(&parser, getNodes(&parser, body_node.kind.block.stmts)[0]);
    try testing.expectEqualStrings("difference", getStr(&parser, diff_call.kind.method_call.method_name));

    const diff_block = getNode(&parser, diff_call.kind.method_call.block);
    const diff_children = getNodes(&parser, diff_block.kind.block.stmts);
    
    const cube_node = getNode(&parser, diff_children[0]);
    try testing.expectEqualStrings("cube", getStr(&parser, cube_node.kind.method_call.method_name));

    const mod_call = getNode(&parser, diff_children[1]);
    // Modifiers lower to method calls with the child trapped in a block!
    try testing.expectEqualStrings("debug", getStr(&parser, mod_call.kind.method_call.method_name));
    
    const mod_call_block = getNode(&parser, mod_call.kind.method_call.block);
    const mod_call_child0 = getNode(&parser, getNodes(&parser, mod_call_block.kind.block.stmts)[0]);
    try testing.expectEqualStrings("cylinder", getStr(&parser, mod_call_child0.kind.method_call.method_name));
}

test "OpenSCAD Parser: For Loop and Range [start:step:end]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "for (i = [0 : 2 : 10]) { cube(i); }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node_idx = try parser.parseStatement();
    const node = getNode(&parser, node_idx);

    const bindings = getForBindings(&parser, node.kind.for_stmt.bindings);
    try testing.expectEqualStrings("i", getStr(&parser, bindings[0].name));
    const range = getNode(&parser, bindings[0].range);
    
    const start = getNode(&parser, range.kind.range.start);
    try testing.expectEqual(@as(f64, 0.0), start.kind.number);
    
    const step = getNode(&parser, range.kind.range.step);
    try testing.expectEqual(@as(f64, 2.0), step.kind.number);
    
    const end = getNode(&parser, range.kind.range.end);
    try testing.expectEqual(@as(f64, 10.0), end.kind.number);
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
    try testing.expectEqualStrings("BOSL2/std.scad", getStr(&parser, inc_node.kind.import_stmt.path));

    const fn_idx = try parser.parseStatement();
    const fn_node = getNode(&parser, fn_idx);
    try testing.expectEqualStrings("double", getStr(&parser, fn_node.kind.def_stmt.name));
    
    const fn_body = getNode(&parser, fn_node.kind.def_stmt.body);
    try testing.expectEqual(ast.BinaryOp.multiply, fn_body.kind.binary_op.op);
}

test "OpenSCAD Parser: Vector Comprehension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "pts = [ for (x = [0:5]) x * 2 ];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const assign_idx = try parser.parseStatement();
    const assign_node = getNode(&parser, assign_idx);

    const comp_node = getNode(&parser, assign_node.kind.assignment.value);
    // Comprehensions lower to Array Literals with nested loop nodes
    const for_node = getNode(&parser, getNodes(&parser, comp_node.kind.array_literal)[0]);

    try testing.expectEqual(std.meta.Tag(ast.NodeKind).for_stmt, std.meta.activeTag(for_node.kind));
    try testing.expectEqualStrings("x", getStr(&parser, getForBindings(&parser, for_node.kind.for_stmt.bindings)[0].name));

    // The body of the FOR is the mathematical expression
    const math_node = getNode(&parser, for_node.kind.for_stmt.body);
    try testing.expectEqual(ast.BinaryOp.multiply, math_node.kind.binary_op.op);
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
    try testing.expectEqualStrings("translate", getStr(&parser, top_node.kind.method_call.method_name));

    const top_block = getNode(&parser, top_node.kind.method_call.block);
    const rotate_node = getNode(&parser, getNodes(&parser, top_block.kind.block.stmts)[0]);

    // Verify middle `rotate`
    try testing.expectEqualStrings("rotate", getStr(&parser, rotate_node.kind.method_call.method_name));

    const rotate_block = getNode(&parser, rotate_node.kind.method_call.block);
    const cube_node = getNode(&parser, getNodes(&parser, rotate_block.kind.block.stmts)[0]);

    // Verify leaf `cube`
    try testing.expectEqualStrings("cube", getStr(&parser, cube_node.kind.method_call.method_name));
    try testing.expectEqual(ast.NodeIndex.none, cube_node.kind.method_call.block);
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

    const stmts = getNodes(&parser, program.kind.block.stmts);

    // Statement 0: Outer assignment `a = 10`
    const stmt0 = getNode(&parser, stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, stmt0.kind.assignment.name));
    
    const stmt0_val = getNode(&parser, stmt0.kind.assignment.value);
    try testing.expectEqual(@as(f64, 10.0), stmt0_val.kind.number);

    // Statement 1: Standalone scope block
    const stmt1 = getNode(&parser, stmts[1]);
    const inner_stmts = getNodes(&parser, stmt1.kind.block.stmts);
    
    const inner_stmt0 = getNode(&parser, inner_stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, inner_stmt0.kind.assignment.name));
    
    const inner_stmt0_val = getNode(&parser, inner_stmt0.kind.assignment.value);
    try testing.expectEqual(@as(f64, 20.0), inner_stmt0_val.kind.number);
    
    const inner_stmt1 = getNode(&parser, inner_stmts[1]);
    try testing.expectEqualStrings("cube", getStr(&parser, inner_stmt1.kind.method_call.method_name));

    // Statement 2: Outer `cube(a)`
    const stmt2 = getNode(&parser, stmts[2]);
    try testing.expectEqualStrings("cube", getStr(&parser, stmt2.kind.method_call.method_name));
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
    try testing.expectEqualStrings("$fn", getStr(&parser, p1.kind.assignment.name));

    const mod_idx = try parser.parseStatement();
    const mod = getNode(&parser, mod_idx);
    try testing.expectEqualStrings("array", getStr(&parser, mod.kind.def_stmt.name));

    const mod_body = getNode(&parser, mod.kind.def_stmt.body);
    const for_node = getNode(&parser, getNodes(&parser, mod_body.kind.block.stmts)[0]);
    
    const range = getNode(&parser, getForBindings(&parser, for_node.kind.for_stmt.bindings)[0].range);
    const range_end = getNode(&parser, range.kind.range.end);
    
    const range_end_left = getNode(&parser, range_end.kind.binary_op.left);
    try testing.expectEqualStrings("$children", getStr(&parser, range_end_left.kind.identifier));

    const for_body = getNode(&parser, for_node.kind.for_stmt.body);
    const trans_node = getNode(&parser, getNodes(&parser, for_body.kind.block.stmts)[0]);

    const trans_block = getNode(&parser, trans_node.kind.method_call.block);
    const child_call = getNode(&parser, getNodes(&parser, trans_block.kind.block.stmts)[0]);
    try testing.expectEqualStrings("children", getStr(&parser, child_call.kind.method_call.method_name));
}

test "OpenSCAD Parser: Assert and Echo Prefixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "echo(\"Rendering\", size = 20) assert(size > 0) cube(size);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const echo_idx = try parser.parseStatement();
    const echo_node = getNode(&parser, echo_idx);
    try testing.expectEqualStrings("echo", getStr(&parser, echo_node.kind.method_call.method_name));

    const echo_block = getNode(&parser, echo_node.kind.method_call.block);
    const assert_node = getNode(&parser, getNodes(&parser, echo_block.kind.block.stmts)[0]);
    try testing.expectEqualStrings("assert", getStr(&parser, assert_node.kind.method_call.method_name));

    const assert_block = getNode(&parser, assert_node.kind.method_call.block);
    const cube_node = getNode(&parser, getNodes(&parser, assert_block.kind.block.stmts)[0]);
    try testing.expectEqualStrings("cube", getStr(&parser, cube_node.kind.method_call.method_name));
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
    try testing.expectEqualStrings("x", getStr(&parser, stmt.kind.assignment.name));

    // Validate Let Expression lowers to Block Scope
    const let_block = getNode(&parser, stmt.kind.assignment.value);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).block, std.meta.activeTag(let_block.kind));
    
    const let_stmts = getNodes(&parser, let_block.kind.block.stmts);
    const let_assign0 = getNode(&parser, let_stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, let_assign0.kind.assignment.name));

    // Validate Yield Expression (If Expression) at end of block
    const yield_node = getNode(&parser, let_stmts[2]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).if_stmt, std.meta.activeTag(yield_node.kind));
    
    const then_branch = getNode(&parser, yield_node.kind.if_stmt.then_branch);
    try testing.expectEqualStrings("a", getStr(&parser, then_branch.kind.identifier));
    
    const else_branch = getNode(&parser, yield_node.kind.if_stmt.else_branch);
    try testing.expectEqualStrings("b", getStr(&parser, else_branch.kind.identifier));
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
    try testing.expectEqualStrings("local_lib.scad", getStr(&parser, inc_node.kind.import_stmt.path));

    // Test Unary Plus
    const assign_idx = try parser.parseStatement();
    const assign_node = getNode(&parser, assign_idx);
    try testing.expectEqualStrings("val", getStr(&parser, assign_node.kind.assignment.name));
    
    const assign_val = getNode(&parser, assign_node.kind.assignment.value);
    try testing.expectEqual(ast.UnaryOp.positive, assign_val.kind.unary_op.op);
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
    try testing.expectEqualStrings("val", getStr(&parser, stmt.kind.assignment.name));

    // Top expression lowers to a block with `assert` call and inner yield
    const assert_block = getNode(&parser, stmt.kind.assignment.value);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).block, std.meta.activeTag(assert_block.kind));
    
    const assert_stmts = getNodes(&parser, assert_block.kind.block.stmts);
    const assert_call = getNode(&parser, assert_stmts[0]);
    try testing.expectEqualStrings("assert", getStr(&parser, assert_call.kind.method_call.method_name));

    // Inner yield is another block for `echo`
    const echo_block = getNode(&parser, assert_stmts[1]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).block, std.meta.activeTag(echo_block.kind));
    
    const echo_stmts = getNodes(&parser, echo_block.kind.block.stmts);
    const echo_call = getNode(&parser, echo_stmts[0]);
    try testing.expectEqualStrings("echo", getStr(&parser, echo_call.kind.method_call.method_name));

    // Yield expression of echo should be `a * 2`
    const math_node = getNode(&parser, echo_stmts[1]);
    try testing.expectEqual(ast.BinaryOp.multiply, math_node.kind.binary_op.op);
}

test "OpenSCAD Parser: Array Literal Expansion (each)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "merged = [1, each sub_array, 4];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);
    const array_node = getNode(&parser, stmt.kind.assignment.value);

    try testing.expectEqual(std.meta.Tag(ast.NodeKind).array_literal, std.meta.activeTag(array_node.kind));
    const elements = getNodes(&parser, array_node.kind.array_literal);
    try testing.expectEqual(@as(usize, 3), elements.len);
    
    const el0 = getNode(&parser, elements[0]);
    try testing.expectEqual(@as(f64, 1.0), el0.kind.number);

    // Verify the inner `each_expr` unpack node maps identically to KupCAD
    const el1 = getNode(&parser, elements[1]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).each_expr, std.meta.activeTag(el1.kind));
    
    const each_val = getNode(&parser, el1.kind.each_expr);
    try testing.expectEqualStrings("sub_array", getStr(&parser, each_val.kind.identifier));
    
    const el2 = getNode(&parser, elements[2]);
    try testing.expectEqual(@as(f64, 4.0), el2.kind.number);
}

test "OpenSCAD Parser: Comprehension with Else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "pts = [ for (i = [0:5]) if (i % 2 == 0) i else -i ];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);
    const comp_node = getNode(&parser, stmt.kind.assignment.value);

    // The top node of the comprehension yield logic is the FOR statement
    const for_node = getNode(&parser, getNodes(&parser, comp_node.kind.array_literal)[0]);
    try testing.expectEqualStrings("i", getStr(&parser, getForBindings(&parser, for_node.kind.for_stmt.bindings)[0].name));

    // The body of the FOR is the nested IF statement
    const if_node = getNode(&parser, for_node.kind.for_stmt.body);
    
    const then_branch = getNode(&parser, if_node.kind.if_stmt.then_branch);
    try testing.expectEqualStrings("i", getStr(&parser, then_branch.kind.identifier));
    
    const else_branch = getNode(&parser, if_node.kind.if_stmt.else_branch);
    try testing.expectEqual(ast.UnaryOp.negate, else_branch.kind.unary_op.op);
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
    const args0 = getNamedArgs(&parser, node.kind.method_call.args)[0];
    const arg0_val = getNode(&parser, args0.value);
    const arr = getNodes(&parser, arg0_val.kind.array_literal);
    
    const arr0 = getNode(&parser, arr[0]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).number, std.meta.activeTag(arr0.kind));
    
    const arr1 = getNode(&parser, arr[1]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).undef, std.meta.activeTag(arr1.kind));

    const block = getNode(&parser, node.kind.method_call.block);
    const cube_call = getNode(&parser, getNodes(&parser, block.kind.block.stmts)[0]);
    const cube_args = getNamedArgs(&parser, cube_call.kind.method_call.args);
    
    const cube_arg1 = getNode(&parser, cube_args[1].value);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).undef, std.meta.activeTag(cube_arg1.kind));
}

test "OpenSCAD Parser: Adjacency String Concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "echo(\"Path: \" \"to/file.stl\");";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node_idx = try parser.parseStatement();
    const node = getNode(&parser, node_idx);

    const args = getNamedArgs(&parser, node.kind.method_call.args);
    const arg0 = getNode(&parser, args[0].value);
    try testing.expectEqualStrings("Path: to/file.stl", getStr(&parser, arg0.kind.string));
}

test "OpenSCAD Parser: Trailing Commas Leniency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "module test(a, b, ) { let(x=1, y=2, ) cube(); }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    try testing.expectEqualStrings("test", getStr(&parser, stmt.kind.def_stmt.name));
    
    const params = getParams(&parser, stmt.kind.def_stmt.params);
    try testing.expectEqual(@as(usize, 2), params.len); // Ignored trailing comma

    // Statement-level let() compiles into a scoped block!
    const body = getNode(&parser, stmt.kind.def_stmt.body);
    const let_block = getNode(&parser, getNodes(&parser, body.kind.block.stmts)[0]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).block, std.meta.activeTag(let_block.kind));

    // Verify it ignored the comma and collected 2 assignments + 1 body statement
    const let_stmts = getNodes(&parser, let_block.kind.block.stmts);
    try testing.expectEqual(@as(usize, 3), let_stmts.len);
    
    const let_stmt0 = getNode(&parser, let_stmts[0]);
    try testing.expectEqualStrings("x", getStr(&parser, let_stmt0.kind.assignment.name));
    
    const let_stmt1 = getNode(&parser, let_stmts[1]);
    try testing.expectEqualStrings("y", getStr(&parser, let_stmt1.kind.assignment.name));
    
    const let_stmt2 = getNode(&parser, let_stmts[2]);
    try testing.expectEqualStrings("cube", getStr(&parser, let_stmt2.kind.method_call.method_name));
}

test "OpenSCAD Parser: Mid-Expression Comments & Empty Statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "module foo() { ;; x = 10 /* offset */ + 5; ; }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const mod_idx = try parser.parseStatement();
    const mod_node = getNode(&parser, mod_idx);

    const body = getNode(&parser, mod_node.kind.def_stmt.body);
    const block_stmts = getNodes(&parser, body.kind.block.stmts);
    // Only the actual assignment should survive the block
    try testing.expectEqual(@as(usize, 1), block_stmts.len);

    const assign = getNode(&parser, block_stmts[0]);
    try testing.expectEqualStrings("x", getStr(&parser, assign.kind.assignment.name));
    
    const assign_val = getNode(&parser, assign.kind.assignment.value);
    try testing.expectEqual(ast.BinaryOp.add, assign_val.kind.binary_op.op);
}

test "OpenSCAD Parser: C-Style Hexadecimal Constants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = 0xFF;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    try testing.expectEqualStrings("val", getStr(&parser, stmt.kind.assignment.name));
    
    const val = getNode(&parser, stmt.kind.assignment.value);
    try testing.expectEqual(@as(f64, 255.0), val.kind.number);
}

test "OpenSCAD Parser: Leading-Dot Float Literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = .5 + .125;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    const math_node = getNode(&parser, stmt.kind.assignment.value);
    const left = getNode(&parser, math_node.kind.binary_op.left);
    try testing.expectEqual(@as(f64, 0.5), left.kind.number);
    
    const right = getNode(&parser, math_node.kind.binary_op.right);
    try testing.expectEqual(@as(f64, 0.125), right.kind.number);
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
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).block, std.meta.activeTag(node.kind));

    const stmts = getNodes(&parser, node.kind.block.stmts);

    // Check Multi-Init at start of block
    const stmt0 = getNode(&parser, stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, stmt0.kind.assignment.name));
    
    const stmt1 = getNode(&parser, stmts[1]);
    try testing.expectEqualStrings("b", getStr(&parser, stmt1.kind.assignment.name));

    // Check Condition of internal while loop
    const while_node = getNode(&parser, stmts[2]);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).while_stmt, std.meta.activeTag(while_node.kind));
    
    const cond = getNode(&parser, while_node.kind.while_stmt.condition);
    try testing.expectEqual(ast.BinaryOp.less, cond.kind.binary_op.op);

    // Check updates appended to end of while loop body
    const while_body = getNode(&parser, while_node.kind.while_stmt.body);
    const while_stmts = getNodes(&parser, while_body.kind.block.stmts);
    
    const assign2 = getNode(&parser, while_stmts[1]);
    const assign2_val = getNode(&parser, assign2.kind.assignment.value);
    try testing.expectEqual(ast.BinaryOp.add, assign2_val.kind.binary_op.op);
}

test "OpenSCAD Parser: Function Literals (Anonymous)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "f = function(x, y) x * y;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const stmt_idx = try parser.parseStatement();
    const stmt = getNode(&parser, stmt_idx);

    const func_lit = getNode(&parser, stmt.kind.assignment.value);

    // Function literals compile down to Lambda Expressions!
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).lambda_expr, std.meta.activeTag(func_lit.kind));
    
    const params = getParams(&parser, func_lit.kind.lambda_expr.params);
    try testing.expectEqualStrings("x", getStr(&parser, params[0].name));
    
    const body = getNode(&parser, func_lit.kind.lambda_expr.body);
    try testing.expectEqual(ast.BinaryOp.multiply, body.kind.binary_op.op);
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

    try testing.expectEqualStrings("val", getStr(&parser, stmt.kind.assignment.name));

    // Outer let: a = 5 (lowers to block)
    const let1 = getNode(&parser, stmt.kind.assignment.value);
    try testing.expectEqual(std.meta.Tag(ast.NodeKind).block, std.meta.activeTag(let1.kind));
    
    const let1_stmts = getNodes(&parser, let1.kind.block.stmts);
    const let1_assign0 = getNode(&parser, let1_stmts[0]);
    try testing.expectEqualStrings("a", getStr(&parser, let1_assign0.kind.assignment.name));

    // Inner let: b = a * 2
    const let2 = getNode(&parser, let1_stmts[1]);
    const let2_stmts = getNodes(&parser, let2.kind.block.stmts);
    
    const let2_assign0 = getNode(&parser, let2_stmts[0]);
    try testing.expectEqualStrings("b", getStr(&parser, let2_assign0.kind.assignment.name));

    // Assert -> Echo -> Addition
    const assert_block = getNode(&parser, let2_stmts[1]);
    const assert_stmts = getNodes(&parser, assert_block.kind.block.stmts);
    
    const assert_call = getNode(&parser, assert_stmts[0]);
    try testing.expectEqualStrings("assert", getStr(&parser, assert_call.kind.method_call.method_name));
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
    try testing.expectEqualStrings("grid", getStr(&parser, mod_node.kind.def_stmt.name));

    const mod_body = getNode(&parser, mod_node.kind.def_stmt.body);
    const for_node = getNode(&parser, getNodes(&parser, mod_body.kind.block.stmts)[0]);
    
    const for_body = getNode(&parser, for_node.kind.for_stmt.body);
    const trans_call = getNode(&parser, getNodes(&parser, for_body.kind.block.stmts)[0]);
    try testing.expectEqualStrings("translate", getStr(&parser, trans_call.kind.method_call.method_name));

    const trans_block = getNode(&parser, trans_call.kind.method_call.block);
    const child_call = getNode(&parser, getNodes(&parser, trans_block.kind.block.stmts)[0]);
    try testing.expectEqualStrings("children", getStr(&parser, child_call.kind.method_call.method_name));

    const args = getNamedArgs(&parser, child_call.kind.method_call.args);
    const arg_expr = getNode(&parser, args[0].value);
    try testing.expectEqual(ast.BinaryOp.modulo, arg_expr.kind.binary_op.op);
    
    const left = getNode(&parser, arg_expr.kind.binary_op.left);
    try testing.expectEqualStrings("i", getStr(&parser, left.kind.identifier));
    
    const right = getNode(&parser, arg_expr.kind.binary_op.right);
    try testing.expectEqualStrings("$children", getStr(&parser, right.kind.identifier));
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
    try testing.expectEqual(@as(usize, 1), getNodes(&parser, result.kind.block.stmts).len);

    // Both errors were captured
    try testing.expectEqual(@as(usize, 2), parser.diagnostics.list.items.len);
}
