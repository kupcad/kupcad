const std = @import("std");
const testing = std.testing;

const LineIndex = @import("../../core/line_index.zig").LineIndex;
const lexer_mod = @import("../../frontend/kupcad/lexer.zig");
const parser_mod = @import("../../frontend/kupcad/parser.zig");
const Formatter = @import("formatter.zig").Formatter;
const FormatterConfig = @import("config.zig").Config;

/// Completely local wrapper that uses our strict Phase 2 & 3 structures for isolated testing
fn formatCodeLocal(allocator: std.mem.Allocator, source: []const u8, config: FormatterConfig) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena_alloc);

    var parser = try parser_mod.Parser.init(tokens, source, arena_alloc);
    const root = parser.parseProgram() catch .none;

    if (parser.diagnostics.list.items.len > 0) return error.SyntaxError;
    if (root == .none) return error.SyntaxError;

    const line_index = try LineIndex.init(arena_alloc, source);

    var formatter = Formatter.init(allocator, tokens.starts, &line_index, parser.comments.items, config);
    defer formatter.deinit();
    try formatter.registerDefaultRules();

    return formatter.format(&parser.b.tree, root);
}

/// Helper to parse, format, and strictly compare the output.
/// We disable `sort_imports` here to strictly test the canonical layout engine.
fn expectFormat(source: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    const formatted = try formatCodeLocal(allocator, source, .{ .sort_imports = false });
    defer allocator.free(formatted);

    try testing.expectEqualStrings(expected, formatted);
}

test "Formatter: Spacing around binary operators and assignments" {
    const source = "x=1+  2*3   -4";
    const expected = "x = 1 + 2 * 3 - 4\n";
    try expectFormat(source, expected);
}

test "Formatter: Array and Hash spacing with Hash Shorthand canonicalization" {
    const source = "data = [ 1 ,2,   3 ]\nopts = {a:  1, b: b ,c:c}";
    const expected =
        \\data = [1, 2, 3]
        \\opts = { a: 1, b:, c: }
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Empty Collections" {
    const source = "arr = [   ]\nobj = {    }";
    const expected =
        \\arr = []
        \\obj = {}
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Multi-line fluent method chains" {
    const source = "part = Box.new(10, 20).chamfer(2).translate(z: 5)";
    const expected =
        \\part = Box.new(10, 20)
        \\  .chamfer(2)
        \\  .translate(z: 5)
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Control flow block indentation" {
    const source =
        \\if x>10
        \\y=1
        \\else
        \\y=2
        \\end
    ;
    const expected =
        \\if x > 10
        \\  y = 1
        \\else
        \\  y = 2
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Function definitions with keyword and splat arguments" {
    const source =
        \\def build( w,h:10, *args, **kwargs )
        \\cube(w,h)
        \\end
    ;
    const expected =
        \\def build(w, h: 10, *args, **kwargs)
        \\  cube(w, h)
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: String Interpolation" {
    const source = "echo( \"Value: #{ x+10 } mm\" )";
    const expected = "echo(\"Value: #{x + 10} mm\")\n";
    try expectFormat(source, expected);
}

test "Formatter: Do blocks and pipes" {
    const source =
        \\part.each do | x, y |
        \\log(x)
        \\end
    ;
    const expected =
        \\part.each do |x, y|
        \\  log(x)
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Inline Rescue Modifier" {
    const source = "val = dangerous()    rescue   0";
    const expected = "val = dangerous() rescue 0\n";
    try expectFormat(source, expected);
}

test "Formatter: Classes, Modules, and Namespace Access" {
    const source =
        \\module Hardware
        \\class Screw< Base::Part
        \\def self.build()
        \\end
        \\end
        \\end
    ;
    const expected =
        \\module Hardware
        \\  class Screw < Base::Part
        \\    def self.build
        \\    end
        \\  end
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Loops (while, until)" {
    const source =
        \\while x<10
        \\x+=1
        \\end
        \\until y>10
        \\cube(y)
        \\end
    ;
    const expected =
        \\while x < 10
        \\  x += 1
        \\end
        \\until y > 10
        \\  cube(y)
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Begin / Rescue / Ensure blocks" {
    const source =
        \\begin
        \\build()
        \\rescue MathError=>e
        \\log(e)
        \\ensure
        \\clean()
        \\end
    ;
    const expected =
        \\begin
        \\  build()
        \\rescue MathError => e
        \\  log(e)
        \\ensure
        \\  clean()
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Case Statements" {
    const source =
        \\case type
        \\when 1,2
        \\a()
        \\else
        \\b()
        \\end
    ;
    const expected =
        \\case type
        \\when 1, 2
        \\  a()
        \\else
        \\  b()
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Multi-Assignment and Indexing" {
    const source =
        \\x, y,z = [1,2,3]
        \\obj[0]=x
    ;
    const expected =
        \\x, y, z = [1, 2, 3]
        \\obj[0] = x
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Flow control keywords (return, break, next, yield)" {
    const source = "return  x,y\nbreak   42\nnext\nyield  1,  2";
    const expected =
        \\return [x, y]
        \\break 42
        \\next
        \\yield 1, 2
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Unary Operators and Splats (no extra spaces)" {
    const source = "x =  - 10\ny =  ! true\nz =  ~ part\ndef foo( * args,  ** kwargs)\nend";
    const expected =
        \\x = -10
        \\y = !true
        \\z = ~part
        \\
        \\def foo(*args, **kwargs)
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Property and Index Assignment" {
    const source = "obj . x  =  10\narr[0]= 5";
    const expected =
        \\obj.x = 10
        \\arr[0] = 5
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Imports and Exports" {
    const source =
        \\import   "lib.kup"
        \\import  {  A,B  }  from  "lib.kup"   with {  version:2  }
        \\export {C} from "other.kup"
    ;
    const expected =
        \\import "lib.kup"
        \\import { A, B } from "lib.kup" with { version: 2 }
        \\export { C } from "other.kup"
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Percent Arrays normalize to standard canonical arrays" {
    const source = "arr = %w[ gear shaft ]\nsyms = %i( a b )";
    const expected =
        \\arr = ["gear", "shaft"]
        \\syms = [:a, :b]
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Compound Property and Index Assignments" {
    const source = "obj . x  +=  10\narr[0]*= 5";
    const expected =
        \\obj.x += 10
        \\arr[0] *= 5
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Aborts formatting when source contains syntax errors" {
    const invalid_source =
        \\valid_line = 10
        \\arr [ 0 ] *= 5 # Syntax error
        \\another_valid = 20
    ;

    const allocator = testing.allocator;
    const result = formatCodeLocal(allocator, invalid_source, .{});

    try testing.expectError(error.SyntaxError, result);
}

test "Formatter: Inline and leading comments are placed correctly" {
    const source =
        \\# Leading comment
        \\width = 50 # Inline comment
        \\# Another leading comment
        \\Box.new(width)
    ;
    const expected =
        \\# Leading comment
        \\width = 50 # Inline comment
        \\# Another leading comment
        \\Box.new(width)
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: properly adds newline before 'end' in multi-statement blocks" {
    const source =
        \\def test
        \\  return
        \\  a += 1
        \\end
    ;
    const expected =
        \\def test
        \\  return
        \\  a += 1
        \\end
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: inserts blank lines between methods and classes" {
    const source =
        \\def foo
        \\  a = 1
        \\end
        \\# Comment for bar
        \\def bar
        \\  b = 2
        \\end
        \\class MyClass
        \\end
        \\x = 10
    ;

    const expected =
        \\def foo
        \\  a = 1
        \\end
        \\
        \\# Comment for bar
        \\def bar
        \\  b = 2
        \\end
        \\
        \\class MyClass
        \\end
        \\
        \\x = 10
        \\
    ;
    try expectFormat(source, expected);
}
