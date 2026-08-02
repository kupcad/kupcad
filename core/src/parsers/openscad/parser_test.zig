const std = @import("std");
const testing = std.testing;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const ast = @import("../common/ast.zig");

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

    const mod_node = try parser.parseStatement();

    try testing.expectEqualStrings("housing", mod_node.kind.module_stmt.name);
    try testing.expectEqualStrings("w", mod_node.kind.module_stmt.params[0].name);

    const diff_call = mod_node.kind.module_stmt.body.kind.block.stmts[0];
    try testing.expectEqualStrings("difference", diff_call.kind.method_call.method_name);

    const diff_children = diff_call.kind.method_call.block.?.kind.block.stmts;
    try testing.expectEqualStrings("cube", diff_children[0].kind.method_call.method_name);

    const mod_call = diff_children[1];
    try testing.expectEqualStrings("#", mod_call.kind.modifier_call.modifier);
    try testing.expectEqualStrings("cylinder", mod_call.kind.modifier_call.child.kind.method_call.method_name);
}

test "OpenSCAD Parser: For Loop and Range [start:step:end]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "for (i = [0 : 2 : 10]) { cube(i); }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseStatement();

    try testing.expectEqualStrings("i", node.kind.for_stmt.bindings[0].name);
    const range = node.kind.for_stmt.bindings[0].range;
    try testing.expectEqual(@as(f64, 0.0), range.kind.range.start.kind.number);
    try testing.expectEqual(@as(f64, 2.0), range.kind.range.step.?.kind.number);
    try testing.expectEqual(@as(f64, 10.0), range.kind.range.end.kind.number);
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

    const inc_node = try parser.parseStatement();
    try testing.expectEqualStrings("BOSL2/std.scad", inc_node.kind.include_stmt.path);

    const fn_node = try parser.parseStatement();
    try testing.expectEqualStrings("double", fn_node.kind.def_stmt.name);
    try testing.expectEqual(ast.BinaryOp.multiply, fn_node.kind.def_stmt.body.kind.binary_op.op);
}

test "OpenSCAD Parser: Vector Comprehension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "pts = [ for (x = [0:5]) x * 2 ];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const assign_node = try parser.parseStatement();
    const comp_node = assign_node.kind.assignment.value;

    // Flat clauses are no longer used; verify it is empty
    try testing.expectEqual(@as(usize, 0), comp_node.kind.comprehension.clauses.len);

    // The top node of the comprehension yield logic is the FOR statement
    const for_node = comp_node.kind.comprehension.yield_expr;
    try testing.expectEqual(ast.Node.Kind.for_stmt, @as(std.meta.Tag(ast.Node.Kind), for_node.kind));
    try testing.expectEqualStrings("x", for_node.kind.for_stmt.bindings[0].name);

    // The body of the FOR is the mathematical expression
    const math_node = for_node.kind.for_stmt.body;
    try testing.expectEqual(ast.BinaryOp.multiply, math_node.kind.binary_op.op);
}

test "OpenSCAD Parser: Unbraced Operator Module Chaining" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "translate([10, 0, 0]) rotate([0, 0, 90]) cube(10);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const top_node = try parser.parseStatement();

    // Verify outer `translate`
    try testing.expectEqualStrings("translate", top_node.kind.method_call.method_name);
    const rotate_node = top_node.kind.method_call.block.?;

    // Verify middle `rotate`
    try testing.expectEqualStrings("rotate", rotate_node.kind.method_call.method_name);
    const cube_node = rotate_node.kind.method_call.block.?;

    // Verify leaf `cube`
    try testing.expectEqualStrings("cube", cube_node.kind.method_call.method_name);

    // FIX: Corrected @as cast syntax
    try testing.expectEqual(@as(?*ast.Node, null), cube_node.kind.method_call.block);
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

    const program = try parser.parseProgram();
    const stmts = program.kind.block.stmts;

    // Statement 0: Outer assignment `a = 10`
    try testing.expectEqualStrings("a", stmts[0].kind.assignment.name);
    try testing.expectEqual(@as(f64, 10.0), stmts[0].kind.assignment.value.kind.number);

    // Statement 1: Standalone scope block
    const inner_stmts = stmts[1].kind.block.stmts;
    try testing.expectEqualStrings("a", inner_stmts[0].kind.assignment.name);
    try testing.expectEqual(@as(f64, 20.0), inner_stmts[0].kind.assignment.value.kind.number);
    try testing.expectEqualStrings("cube", inner_stmts[1].kind.method_call.method_name);

    // Statement 2: Outer `cube(a)`
    try testing.expectEqualStrings("cube", stmts[2].kind.method_call.method_name);
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

    const p1 = try parser.parseStatement();
    try testing.expectEqualStrings("$fn", p1.kind.assignment.name);

    const mod = try parser.parseStatement();
    try testing.expectEqualStrings("array", mod.kind.module_stmt.name);

    const for_node = mod.kind.module_stmt.body.kind.block.stmts[0];
    const range_end = for_node.kind.for_stmt.bindings[0].range.kind.range.end;
    try testing.expectEqualStrings("$children", range_end.kind.binary_op.left.kind.identifier);

    const trans_node = for_node.kind.for_stmt.body.kind.block.stmts[0];
    const child_call = trans_node.kind.method_call.block.?;
    try testing.expectEqualStrings("children", child_call.kind.method_call.method_name);
}

test "OpenSCAD Parser: Assert and Echo Prefixes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "echo(\"Rendering\", size = 20) assert(size > 0) cube(size);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const echo_node = try parser.parseStatement();
    try testing.expectEqualStrings("echo", echo_node.kind.method_call.method_name);

    const assert_node = echo_node.kind.method_call.block.?;
    try testing.expectEqualStrings("assert", assert_node.kind.method_call.method_name);

    const cube_node = assert_node.kind.method_call.block.?;
    try testing.expectEqualStrings("cube", cube_node.kind.method_call.method_name);
}

test "OpenSCAD Parser: Let and If Expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "x = let(a = 10, b = 2) if (a > b) a else b;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    // Validate target assignment
    try testing.expectEqualStrings("x", stmt.kind.assignment.name);

    // Validate Let Expression
    const let_node = stmt.kind.assignment.value;
    try testing.expectEqual(ast.Node.Kind.let_expr, @as(std.meta.Tag(ast.Node.Kind), let_node.kind));
    try testing.expectEqualStrings("a", let_node.kind.let_expr.assignments[0].kind.assignment.name);

    // Validate Yield Expression (If Expression)
    const yield_node = let_node.kind.let_expr.yield_expr;
    try testing.expectEqual(ast.Node.Kind.if_stmt, @as(std.meta.Tag(ast.Node.Kind), yield_node.kind));
    try testing.expectEqualStrings("a", yield_node.kind.if_stmt.then_branch.kind.identifier);
    try testing.expectEqualStrings("b", yield_node.kind.if_stmt.else_branch.?.kind.identifier);
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

    // Test Quoted Include Path
    const inc_node = try parser.parseStatement();
    try testing.expectEqualStrings("local_lib.scad", inc_node.kind.include_stmt.path);
    try testing.expectEqual(false, inc_node.kind.include_stmt.is_use);

    // Test Unary Plus
    const assign_node = try parser.parseStatement();
    try testing.expectEqualStrings("val", assign_node.kind.assignment.name);
    try testing.expectEqual(ast.UnaryOp.positive, assign_node.kind.assignment.value.kind.unary_op.op);
}

test "OpenSCAD Parser: Expression-level Assert and Echo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = assert(a > 0) echo(a) a * 2;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();

    // Assigning to `val`
    try testing.expectEqualStrings("val", stmt.kind.assignment.name);

    // Top expression should be `assert`
    const assert_node = stmt.kind.assignment.value;
    try testing.expectEqual(ast.Node.Kind.assert_expr, @as(std.meta.Tag(ast.Node.Kind), assert_node.kind));

    // Yield expression of assert should be `echo`
    const echo_node = assert_node.kind.assert_expr.yield_expr;
    try testing.expectEqual(ast.Node.Kind.echo_expr, @as(std.meta.Tag(ast.Node.Kind), echo_node.kind));

    // Yield expression of echo should be `a * 2`
    const math_node = echo_node.kind.echo_expr.yield_expr;
    try testing.expectEqual(ast.BinaryOp.multiply, math_node.kind.binary_op.op);
}

test "OpenSCAD Parser: Array Literal Expansion (each)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "merged = [1, each sub_array, 4];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    const array_node = stmt.kind.assignment.value;

    try testing.expectEqual(ast.Node.Kind.array_literal, @as(std.meta.Tag(ast.Node.Kind), array_node.kind));
    const elements = array_node.kind.array_literal;

    try testing.expectEqual(@as(usize, 3), elements.len);
    try testing.expectEqual(@as(f64, 1.0), elements[0].kind.number);

    // Verify the inner `each_expr` unpack node
    try testing.expectEqual(ast.Node.Kind.each_expr, @as(std.meta.Tag(ast.Node.Kind), elements[1].kind));
    try testing.expectEqualStrings("sub_array", elements[1].kind.each_expr.kind.identifier);

    try testing.expectEqual(@as(f64, 4.0), elements[2].kind.number);
}

test "OpenSCAD Parser: Comprehension with Else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "pts = [ for (i = [0:5]) if (i % 2 == 0) i else -i ];";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    const comp_node = stmt.kind.assignment.value;

    // The top node of the comprehension yield logic is the FOR statement
    const for_node = comp_node.kind.comprehension.yield_expr;
    try testing.expectEqualStrings("i", for_node.kind.for_stmt.bindings[0].name);

    // The body of the FOR is the nested IF statement
    const if_node = for_node.kind.for_stmt.body;
    try testing.expectEqualStrings("i", if_node.kind.if_stmt.then_branch.kind.identifier);
    try testing.expectEqual(ast.UnaryOp.negate, if_node.kind.if_stmt.else_branch.?.kind.unary_op.op);
}

test "OpenSCAD Parser: Empty Arguments and Array Elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = "translate([10, , 20]) cube(10, , 20);";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());
    const node = try parser.parseStatement();

    // Check empty array element inside arguments
    const arr = node.kind.method_call.args[0].value.kind.array_literal;
    try testing.expectEqual(ast.Node.Kind.number, @as(std.meta.Tag(ast.Node.Kind), arr[0].kind));
    try testing.expectEqual(ast.Node.Kind.undef, @as(std.meta.Tag(ast.Node.Kind), arr[1].kind));

    // Check empty argument on block
    const cube_call = node.kind.method_call.block.?;
    const cube_args = cube_call.kind.method_call.args;
    try testing.expectEqual(ast.Node.Kind.undef, @as(std.meta.Tag(ast.Node.Kind), cube_args[1].value.kind));
}

test "OpenSCAD Parser: Adjacency String Concatenation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "echo(\"Path: \" \"to/file.stl\");";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const node = try parser.parseStatement();
    const args = node.kind.method_call.args;

    try testing.expectEqualStrings("Path: to/file.stl", args[0].value.kind.string);
}

test "OpenSCAD Parser: Trailing Commas Leniency" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "module test(a, b, ) { let(x=1, y=2, ) cube(); }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    try testing.expectEqualStrings("test", stmt.kind.module_stmt.name);
    try testing.expectEqual(@as(usize, 2), stmt.kind.module_stmt.params.len); // Ignored trailing comma

    // Statement-level let() compiles into a scoped block!
    const let_block = stmt.kind.module_stmt.body.kind.block.stmts[0];
    try testing.expectEqual(ast.Node.Kind.block, @as(std.meta.Tag(ast.Node.Kind), let_block.kind));

    // Verify it ignored the comma and collected 2 assignments + 1 body statement
    const let_stmts = let_block.kind.block.stmts;
    try testing.expectEqual(@as(usize, 3), let_stmts.len);

    try testing.expectEqualStrings("x", let_stmts[0].kind.assignment.name);
    try testing.expectEqualStrings("y", let_stmts[1].kind.assignment.name);
    try testing.expectEqualStrings("cube", let_stmts[2].kind.method_call.method_name);
}

test "OpenSCAD Parser: Mid-Expression Comments & Empty Statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "module foo() { ;; x = 10 /* offset */ + 5; ; }";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const mod_node = try parser.parseStatement();
    const block_stmts = mod_node.kind.module_stmt.body.kind.block.stmts;

    // Only the actual assignment should survive the block
    try testing.expectEqual(@as(usize, 1), block_stmts.len);

    const assign = block_stmts[0];
    try testing.expectEqualStrings("x", assign.kind.assignment.name);
    try testing.expectEqual(ast.BinaryOp.add, assign.kind.assignment.value.kind.binary_op.op);
}

test "OpenSCAD Parser: C-Style Hexadecimal Constants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = 0xFF;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    try testing.expectEqualStrings("val", stmt.kind.assignment.name);
    try testing.expectEqual(@as(f64, 255.0), stmt.kind.assignment.value.kind.number);
}

test "OpenSCAD Parser: Leading-Dot Float Literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source = "val = .5 + .125;";
    var lexer = Lexer.init(source, 0);
    var parser = Parser.init(&lexer, arena.allocator());

    const stmt = try parser.parseStatement();
    const math_node = stmt.kind.assignment.value;

    try testing.expectEqual(@as(f64, 0.5), math_node.kind.binary_op.left.kind.number);
    try testing.expectEqual(@as(f64, 0.125), math_node.kind.binary_op.right.kind.number);
}
