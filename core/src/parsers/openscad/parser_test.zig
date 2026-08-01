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

    try testing.expectEqual(@as(usize, 1), comp_node.kind.comprehension.clauses.len);
    try testing.expectEqualStrings("x", comp_node.kind.comprehension.clauses[0].kind.for_stmt.bindings[0].name);
    try testing.expectEqual(ast.BinaryOp.multiply, comp_node.kind.comprehension.yield_expr.kind.binary_op.op);
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
