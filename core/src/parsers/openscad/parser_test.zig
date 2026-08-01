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

    try testing.expectEqualStrings("i", node.kind.for_stmt.var_name);
    const range = node.kind.for_stmt.range;
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
