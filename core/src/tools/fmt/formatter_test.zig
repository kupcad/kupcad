const std = @import("std");
const testing = std.testing;

const FormatterConfig = @import("config.zig").Config;

/// Formats through the checked API, so every layout test also proves its output parses,
/// means the same program and keeps the comments. (A local wrapper used to drive the
/// Formatter directly, so none of the 43 layout tests checked equivalence.)
fn formatCodeLocal(allocator: std.mem.Allocator, source: []const u8, config: FormatterConfig) ![]const u8 {
    return @import("../../api.zig").formatCode(allocator, source, config);
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

test "Formatter: a chain stays on one line when it fits, and breaks a call per line when not" {
    // Every chain used to be broken, `cube(10).translate(1, 2, 3)` included.
    try expectStableFormat("part = Box.new(10, 20).chamfer(2).translate(z: 5)\n", "part = Box.new(10, 20).chamfer(2).translate(z: 5)\n");
    try expectStableFormat("a = cube(10).translate(1, 2, 3)\n", "a = cube(10).translate(1, 2, 3)\n");
    // Too long: a call per line, the first staying with a bare name.
    try expectStableFormat(
        \\bracket = Box.new(width: 120, depth: 40).chamfer(2).translate(x: 10, y: 20, z: 30).rotate(z: 45).mirror(1, 0, 0)
    ,
        \\bracket = Box.new(width: 120, depth: 40)
        \\  .chamfer(2)
        \\  .translate(x: 10, y: 20, z: 30)
        \\  .rotate(z: 45)
        \\  .mirror(1, 0, 0)
        \\
    );
    // Broken by the author: kept as written, calls on one line together.
    try expectStableFormat(
        \\part = cube(10).center
        \\  .translate(1, 2, 3).rotate(z: 5)
        \\  .mirror(1, 0, 0)
    ,
        \\part = cube(10).center
        \\  .translate(1, 2, 3).rotate(z: 5)
        \\  .mirror(1, 0, 0)
        \\
    );
    // One call that won't fit breaks its arguments instead of the chain.
    try expectStableFormat(
        \\plate = cube(10).translate(x: plate_offset_from_origin, y: other_plate_offset, z: vertical_plate_offset_value)
    ,
        \\plate = cube(10).translate(
        \\  x: plate_offset_from_origin,
        \\  y: other_plate_offset,
        \\  z: vertical_plate_offset_value,
        \\)
        \\
    );
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
    // In the places the language allows them: the checked API rejects a stray `break`.
    const source = "def f(x,y)\n[1].each do |v|\nbreak   42\nnext\nend\nyield(  1,  width: 50)\nreturn  x,y\nend";
    const expected =
        \\def f(x, y)
        \\  [1].each do |v|
        \\    break 42
        \\    next
        \\  end
        \\  yield(1, width: 50)
        \\  return x, y
        \\end
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

test "Formatter: a minus before a call on a number keeps applying last" {
    // `- 3.abs` is -(3.abs), but `-3.abs` is (-3).abs: printed without the space, the
    // minus became part of the number (found by the fuzzer).
    const source = "a = - 3.abs\nb = - 2[0].m\nc = - 2.m ** 2\nd = - 2 ** 2\ne = -3.abs";
    const expected =
        \\a = -(3.abs)
        \\b = -(2[0].m)
        \\c = -(2.m ** 2)
        \\d = -2 ** 2
        \\e = (-3).abs
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

test "Formatter: an import's names stay bare or in braces, as they mean different things for a file" {
    // Braces were always printed: `import gears from` became `import { gears } from`, which
    // takes a key of a JSON file and is a syntax error for a mesh.
    const source =
        \\import  gears  from  "./gears.json"
        \\import { teeth , hub } from "./gear.json"
        \\import part from "./part.stl"
        \\export machine from "./machine.json"
    ;
    const expected =
        \\import gears from "./gears.json"
        \\import { teeth, hub } from "./gear.json"
        \\import part from "./part.stl"
        \\export machine from "./machine.json"
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Imports and Exports" {
    const source =
        \\import   "lib.kup"
        \\import  {  A,B  }  from  "lib.kup"   with {  type:"kup"  }
        \\export {C} from "other.kup"
        \\export {D,E as F}
    ;
    // A file's own export has no path (it was printed with `from ""`).
    const expected =
        \\import "lib.kup"
        \\import { A, B } from "lib.kup" with { type: "kup" }
        \\export { C } from "other.kup"
        \\export { D, E as F }
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

test "Formatter: Preserves same-line statements with a single semicolon and squashes repeats" {
    // Messy input with terrible spacing and repeated semicolons
    const source = "a = 1;;;   b = 2;; c = 3; \n d = 4";

    // The formatter perfectly cleans up the spacing and reduces repeats to a single ';'
    const expected =
        \\a = 1; b = 2; c = 3
        \\d = 4
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: Prevents semicolons from combining across lines" {
    // If they were on different lines originally, they stay on different lines
    const source =
        \\x = 10;
        \\y = 20;
    ;
    const expected =
        \\x = 10
        \\y = 20
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: a call without parentheses gets them, keeping what -1, *xs and &blk meant" {
    // Its output must parse back to the same calls: `puts -1` formatted as `puts - 1` would subtract.
    const source =
        \\puts -1
        \\count *xs
        \\list.map &blk
        \\x = 1
        \\x -1
        \\pts = [1]
        \\pts [0]
    ;
    const expected =
        \\puts(-1)
        \\count(*xs)
        \\list.map(&blk)
        \\x = 1
        \\x - 1
        \\pts = [1]
        \\pts[0]
        \\
    ;
    try expectFormat(source, expected);
}

test "Formatter: adds the parentheses the meaning needs, and keeps the author's" {
    // The AST keeps no grouping, and these used to print without it: `(1 + 2) * 3` as
    // `1 + 2 * 3`, `-(a + b)` as `-a + b`, `2 ** (1 + 1)` as `2 ** 1 + 1`.
    const source =
        \\x = (1 + 2) * 3
        \\y = -(a + b)
        \\z = (a - b) - (c - d)
        \\w = 2 ** (1 + 1)
        \\w2 = (2 ** 3) ** 2
        \\w3 = 2 ** (3 ** 2)
        \\w4 = (-2) ** 2
        \\w5 = -(2 ** 2)
        \\v = (1..3).to_a
        \\v2 = (1 + 1)..(2 * 3)
        \\u = !(a && b)
        \\t = (a ? b : c) + 1
        \\s = (a || b) ? 1 : 2
        \\q = (x = 1) + 2
        \\r = (a rescue b) + 1
        \\m = (a + b).abs
        \\n = (a - b)[0]
        \\(a + b).c = 1
        \\puts (1 + 2) * 3
        \\k = (a * b) + (c << 1)
    ;
    // Every parenthesis written stays; only a call's own (`puts (x)`) becomes the call's.
    const kept = try std.mem.replaceOwned(u8, testing.allocator, source ++ "\n", "puts (1 + 2) * 3", "puts((1 + 2) * 3)");
    defer testing.allocator.free(kept);
    try expectFormat(source, kept);
    try expectFormat(kept, kept);

    // Without the redundant ones, it adds only what the meaning needs.
    const minimal =
        \\x = (1 + 2) * 3
        \\y = -(a + b)
        \\z = a - b - (c - d)
        \\w = 2 ** (1 + 1)
        \\w2 = (2 ** 3) ** 2
        \\w3 = 2 ** 3 ** 2
        \\w4 = (-2) ** 2
        \\w5 = -2 ** 2
        \\v = (1..3).to_a
        \\v2 = 1 + 1..2 * 3
        \\u = !(a && b)
        \\t = (a ? b : c) + 1
        \\s = a || b ? 1 : 2
        \\q = (x = 1) + 2
        \\r = (a rescue b) + 1
        \\m = (a + b).abs
        \\n = (a - b)[0]
        \\(a + b).c = 1
        \\puts((1 + 2) * 3)
        \\k = a * b + (c << 1)
        \\
    ;
    try expectFormat(minimal, minimal);
}

/// Formats `source` to `expected`, and formatting `expected` changes nothing.
fn expectStableFormat(source: []const u8, expected: []const u8) !void {
    try expectFormat(source, expected);
    try expectFormat(expected, expected);
}

test "Formatter: keeps one blank line where the source had any, never at the start of a block" {
    // Every blank line used to be dropped, merging a script's sections.
    try expectStableFormat(
        \\# header
        \\
        \\# section 1
        \\a = 1
        \\
        \\
        \\b = 2
        \\# about c
        \\c = 3
        \\def f
        \\
        \\  x = 1
        \\
        \\  y = 2
        \\end
    ,
        \\# header
        \\
        \\# section 1
        \\a = 1
        \\
        \\b = 2
        \\# about c
        \\c = 3
        \\
        \\def f
        \\  x = 1
        \\
        \\  y = 2
        \\end
        \\
    );
}

test "Formatter: a comment trailing any line of a statement stays with it" {
    // The comment used to move below the chain on the next run, then to its last call; one
    // inside the chain was written mid-call: `.rotate(z: # note` / `5)`.
    try expectStableFormat(
        \\hole = circle(d: 12).translate(22, 17.5) # moved
        \\chain = cube(1)
        \\  .translate(1, 2, 3) # on line two
        \\  .rotate(z: 5)
        \\last = 1 # same line
    ,
        \\hole = circle(d: 12).translate(22, 17.5) # moved
        \\chain = cube(1)
        \\  .translate(1, 2, 3) # on line two
        \\  .rotate(z: 5)
        \\last = 1 # same line
        \\
    );
}

test "Formatter: comments above end or else stay inside their block" {
    // They used to move below `end` and into the else branch.
    try expectStableFormat(
        \\def f
        \\  x = 1
        \\  # closing note
        \\end
        \\if ok
        \\  a = 1
        \\  # before else
        \\else
        \\  b = 2
        \\end
    ,
        \\def f
        \\  x = 1
        \\  # closing note
        \\end
        \\
        \\if ok
        \\  a = 1
        \\  # before else
        \\else
        \\  b = 2
        \\end
        \\
    );
}

test "Formatter: comments stay with the list row, call or operator line they follow" {
    // A list the author broke keeps its rows, and an operator expression its lines, so the
    // comments stay on theirs (they used to move after the statement).
    try expectStableFormat(
        \\pts = [
        \\  1, # first
        \\  # own line
        \\  2
        \\]
        \\total = 1 +
        \\  # why two
        \\  2
    ,
        \\pts = [
        \\  1, # first
        \\  # own line
        \\  2,
        \\]
        \\total = 1 +
        \\  # why two
        \\  2
        \\
    );
}

test "Formatter: a list the author broke keeps its rows; one too long goes an item per line" {
    // A matrix written in rows used to be flattened into one line.
    try expectStableFormat(
        \\m = [
        \\  1.0, 0.0, 0.0,
        \\  0.0, 1.0, 0.0,
        \\  0.0, 0.0, 10.0
        \\]
        \\opts = { a: 1,
        \\  b: 2 }
        \\short = [1, 2, 3]
        \\long = [first_value_name, second_value_name, third_value_name, fourth_value_name, fifth_value_name, sixth]
    ,
        \\m = [
        \\  1.0, 0.0, 0.0,
        \\  0.0, 1.0, 0.0,
        \\  0.0, 0.0, 10.0,
        \\]
        \\opts = {
        \\  a: 1,
        \\  b: 2,
        \\}
        \\short = [1, 2, 3]
        \\long = [
        \\  first_value_name,
        \\  second_value_name,
        \\  third_value_name,
        \\  fourth_value_name,
        \\  fifth_value_name,
        \\  sixth,
        \\]
        \\
    );
}

test "Formatter: for loops print as KupCAD" {
    // The formatter printed OpenSCAD's `for(i = ...)`, which KupCAD can't read.
    try expectStableFormat(
        \\for i in 1..3
        \\puts i
        \\end
        \\for first, *rest in rows; do_it(first); end
    ,
        \\for i in 1..3
        \\  puts(i)
        \\end
        \\for first, *rest in rows
        \\  do_it(first)
        \\end
        \\
    );
}

test "Formatter: number literals keep their spelling" {
    // `20.0` used to print as `20`, losing the author's choice; the value is the same.
    try expectFormat("w = 20.0\nn = 1_000\ne = 1e3\nm = -2.50\nh = 0.5 * w\n", "w = 20.0\nn = 1_000\ne = 1e3\nm = -2.50\nh = 0.5 * w\n");
}

test "Formatter: keeps the parentheses the author wrote, and adds the ones the meaning needs" {
    try expectFormat(
        \\a = d + (w * 2.0)
        \\b = (x)
        \\c = (1 + 2) * 3
        \\e = -(a + b)
        \\f = (a * b) + c
        \\g = cube((10))
        \\
    ,
        \\a = d + (w * 2.0)
        \\b = (x)
        \\c = (1 + 2) * 3
        \\e = -(a + b)
        \\f = (a * b) + c
        \\g = cube(10)
        \\
    );
}

test "Formatter: comments between and after the calls of a chain stay there" {
    try expectStableFormat(
        \\part = cube(10)
        \\  # centre it first
        \\  .center
        \\  .translate(0, 0, 5) # lift
        \\  .rotate(z: 45)
        \\
    ,
        \\part = cube(10)
        \\  # centre it first
        \\  .center
        \\  .translate(0, 0, 5) # lift
        \\  .rotate(z: 45)
        \\
    );
}

test "Formatter: arguments break inside a broken chain, indented under their call" {
    try expectStableFormat(
        \\body = cube(10)
        \\  .translate(x: first_long_offset_name, y: second_long_offset_name, z: third_long_offset_name_here_too)
        \\  .rotate(z: 45)
    ,
        \\body = cube(10)
        \\  .translate(
        \\    x: first_long_offset_name,
        \\    y: second_long_offset_name,
        \\    z: third_long_offset_name_here_too,
        \\  )
        \\  .rotate(z: 45)
        \\
    );
}

test "Formatter: line_width is a setting" {
    const allocator = testing.allocator;
    const formatted = try formatCodeLocal(allocator, "p = cube(10).translate(1, 2, 3).rotate(z: 5)\n", .{ .sort_imports = false, .line_width = 30 });
    defer allocator.free(formatted);
    try testing.expectEqualStrings("p = cube(10)\n  .translate(1, 2, 3)\n  .rotate(z: 5)\n", formatted);
}

test "Formatter: elsif stays elsif, and an if inside an else stays inside it" {
    // `elsif` printed as `else` + a nested `if ... end`, a different program, so any `if`
    // with an `elsif` was refused.
    try expectStableFormat(
        \\if a
        \\  1
        \\elsif b # second
        \\  2
        \\elsif c
        \\  3
        \\else
        \\  4
        \\end
        \\if x
        \\  1
        \\else
        \\  if y
        \\    2
        \\  end
        \\end
        \\
    ,
        \\if a
        \\  1
        \\elsif b # second
        \\  2
        \\elsif c
        \\  3
        \\else
        \\  4
        \\end
        \\if x
        \\  1
        \\else
        \\  if y
        \\    2
        \\  end
        \\end
        \\
    );
}

test "Formatter: a brace block stays a brace block, on one line when it fits" {
    // `{ |x| x * 2 }` used to become `do |x|` / `x * 2` / `end` over three lines.
    try expectStableFormat(
        \\a = [1, 2].map { |x| x * 2 }
        \\b = [1].map { |x| puts(x); x }
        \\c = ->(x) { x + 1 }
        \\d = items.select { |i| i > 2 } # keep
        \\e = [1].each { |x|
        \\  puts(x)
        \\}
        \\f = ->(x) do
        \\  x
        \\end
        \\[1].each do |x|
        \\  puts(x)
        \\end
        \\
    ,
        \\a = [1, 2].map { |x| x * 2 }
        \\b = [1].map { |x| puts(x); x }
        \\c = ->(x) { x + 1 }
        \\d = items.select { |i| i > 2 } # keep
        \\e = [1].each { |x|
        \\  puts(x)
        \\}
        \\f = ->(x) do
        \\  x
        \\end
        \\[1].each do |x|
        \\  puts(x)
        \\end
        \\
    );
}

test "Formatter: a long last list argument opens up in place" {
    // It used to move to a line of its own, nested a level deeper.
    try expectStableFormat(
        \\inspect("Bounds (X, Y, Z):", [final_part.bbox.x_size.round(2), final_part.bbox.y_size.round(2), final_part.bbox.z_size.round(2)])
        \\
    ,
        \\inspect("Bounds (X, Y, Z):", [
        \\  final_part.bbox.x_size.round(2),
        \\  final_part.bbox.y_size.round(2),
        \\  final_part.bbox.z_size.round(2),
        \\])
        \\
    );
    // Arguments the author broke over lines stay one per line.
    try expectStableFormat(
        \\inspect(
        \\  "Bounds:",
        \\  [a, b],
        \\)
        \\
    ,
        \\inspect(
        \\  "Bounds:",
        \\  [a, b],
        \\)
        \\
    );
}

test "Formatter: an operator expression keeps the author's line breaks" {
    // The names are variables: an unknown `first_part +` followed by `second_part`
    // would be a call, first_part(+second_part), as in Ruby.
    try expectStableFormat(
        \\first_part = 1
        \\second_part = 2
        \\third_part = 3
        \\wide = first_part +
        \\  second_part + # middle
        \\  third_part
        \\body = cube(10) -
        \\  cylinder(r: 2, h: 20).translate(
        \\    1,
        \\    2,
        \\  )
        \\flat = a + b
        \\
    ,
        \\first_part = 1
        \\second_part = 2
        \\third_part = 3
        \\wide = first_part +
        \\  second_part + # middle
        \\  third_part
        \\body = cube(10) -
        \\  cylinder(r: 2, h: 20).translate(
        \\    1,
        \\    2,
        \\  )
        \\flat = a + b
        \\
    );
}

test "Formatter: string and symbol literals are printed as written" {
    // The decoded value was printed: `"x\ty\n"` came out with a real TAB and line break,
    // `'a'` as `"a"`, `"say \"hi\""` and `:"with space"` as programs that didn't parse.
    try expectStableFormat("s = \"x\\ty\\n\"\nt = 'raw\\n'\nu = \"say \\\"hi\\\"\"\nv = :\"with space\"\nw = \"a#{1}b\\tc\"\nx = :plain", "s = \"x\\ty\\n\"\nt = 'raw\\n'\nu = \"say \\\"hi\\\"\"\nv = :\"with space\"\nw = \"a#{1}b\\tc\"\nx = :plain\n");
    // A heredoc has no text to reuse in place: it becomes one double-quoted literal, and
    // the statement after it gets no blank line (its last line used to be the body's first).
    try expectStableFormat("x = <<~EOS\n  hello \"there\"\n  world\nEOS\ny = 1\n", "x = \"hello \\\"there\\\"\\nworld\\n\"\ny = 1\n");
    try expectStableFormat("x = <<-EOS\n  kept\n  EOS\ny = 1\n", "x = \"  kept\\n\"\ny = 1\n");
    try expectStableFormat("y = \"line1\nline2\"\nz = 2\n", "y = \"line1\nline2\"\nz = 2\n");
    try expectStableFormat("w = %w[a b]\n", "w = [\"a\", \"b\"]\n");
}

test "Formatter: a method's own rescue and ensure stay at the method's level" {
    // They were printed inside a `begin` of their own, another program, so the formatter
    // refused any method with them.
    try expectStableFormat(
        "def f(x)\n  x / 2 # half\nrescue ArgumentError, TypeError => e # why\n  0\nensure\n  puts(1)\nend\n",
        "def f(x)\n  x / 2 # half\nrescue ArgumentError, TypeError => e # why\n  0\nensure\n  puts(1)\nend\n",
    );
    // An explicit `begin` in a method stays one.
    try expectStableFormat("def g\n  begin\n    1\n  rescue\n    0\n  end\nend\n", "def g\n  begin\n    1\n  rescue\n    0\n  end\nend\n");
}

test "Formatter: a string written inside #{} stays inside it" {
    // It was printed as one of the string's own pieces: `"#{"a"}"` became `"a"`, a string
    // that isn't interpolated (found by the generated-program fuzz test).
    try expectStableFormat("x = \"p#{\"a\"}q\"\ny = \"#{'raw'} and #{\"b#{1}\"}\"\n", "x = \"p#{\"a\"}q\"\ny = \"#{'raw'} and #{\"b#{1}\"}\"\n");
}

test "Formatter: an empty #{} stays in its string" {
    // It is no part of the string's own, so it was dropped: `"#{}"` became `""`, a string
    // that isn't interpolated, and the formatter refused it (found by the front-end fuzz test).
    try expectStableFormat("x = \"#{}\"\ny = \"a #{} b #{1}#{}\"\n", "x = \"#{}\"\ny = \"a #{} b #{1}#{}\"\n");
}

test "Formatter: a top-level constant keeps its leading ::" {
    // `::A` is the top-level A; printed as `A` it read back as a constant looked up in the
    // enclosing modules (found by the fuzzer, as `param(::arm_length)`).
    try expectStableFormat("x = ::A\ny = [::b, 1 + ::C]\nparam(::w)\n", "x = ::A\ny = [::b, 1 + ::C]\nparam(::w)\n");
    try expectStableFormat("module M\n  A = 1\n  x = ::A\nend\n", "module M\n  A = 1\n  x = ::A\nend\n");
    // A longer path is resolved from the top either way.
    try expectStableFormat("x = ::A::B\n", "x = A::B\n");
}

test "Formatter: a heredoc after an operator stays on the operator's line" {
    // Its body starts a line down, which read as a line broken after the operator: `q & <<~EOS`
    // came out as `q &` over its operand, which parsed as `q(&...)` (found by the fuzzer).
    try expectStableFormat("q&<<~EOS\n  two\nEOS\nput\n", "q & \"two\\n\"\nput\n");
    try expectStableFormat("x = 1 + <<~EOS\n  two\nEOS\n", "x = 1 + \"two\\n\"\n");
    // A break the author made is kept.
    try expectStableFormat("x = 1 +\n  <<~EOS\n  two\nEOS\n", "x = 1 +\n  \"two\\n\"\n");
}

test "Formatter: code after a heredoc's opener stays with it, and the next statement follows the body" {
    // The statement ends on the terminator line: the line after it is the next statement's,
    // not a blank line between them.
    try expectStableFormat("f(<<~A).upcase # note\n  x\nA\ny = 1\n", "f(\"x\\n\").upcase # note\ny = 1\n");
    try expectStableFormat("parts = [<<~A, <<~B]\n  a\nA\n  b\nB\n\ny = 1\n", "parts = [\"a\\n\", \"b\\n\"]\n\ny = 1\n");
    try expectStableFormat("x = <<~A + 1\n  a\nA\n", "x = \"a\\n\" + 1\n");
}

test "Formatter: lambda parameters, bracketed returns, super(), aliases and multi-assignment keep their form" {
    // Each of these made the formatter refuse the whole file (it would have changed the
    // program): a lambda lost its defaults and splat, `return []` its brackets, `super()`
    // its parentheses, `import { a as b }` its alias; `a, b = 1, 2` became `a, b = [1, 2]`.
    try expectStableFormat("f = ->(a, b = 2, *rest, k: 1, &blk) { a }\n", "f = ->(a, b = 2, *rest, k: 1, &blk) { a }\n");
    try expectStableFormat("def r\n  return []\nend\n", "def r\n  return []\nend\n");
    try expectStableFormat("def r\n  return 1, 2\nend\n", "def r\n  return 1, 2\nend\n");
    try expectStableFormat("class B < A\n  def f\n    super()\n  end\n  def g\n    super\n  end\nend\n", "class B < A\n  def f\n    super()\n  end\n\n  def g\n    super\n  end\nend\n");
    try expectStableFormat("import { a as b, c } from \"./x.kup\"\n", "import { a as b, c } from \"./x.kup\"\n");
    try expectStableFormat("a, b = 1, 2\nc, d = [3, 4]\ne, = [5, 6]\n", "a, b = 1, 2\nc, d = [3, 4]\ne, = [5, 6]\n");
    // A splat alone keeps its comma too: without it the output didn't parse (the nightly
    // front-end fuzzer, from `*m , **=[...]`)
    try expectStableFormat("*m, = [1, 2]\n", "*m, = [1, 2]\n");
}

test "Formatter: comments on case, when, else, begin, rescue and ensure lines stay there" {
    // `case x # c` and `begin # c` gained a blank line below; a comment on a `when`,
    // `else`, `rescue` or `ensure` line moved into the body.
    const source =
        \\case x # c
        \\when 1 # one
        \\  puts(1)
        \\else # other
        \\  puts(2)
        \\end
        \\begin # c
        \\  cube(1)
        \\rescue => e # oops
        \\  nil
        \\ensure # done
        \\  nil
        \\end
        \\if a # yes
        \\  1
        \\else # no
        \\  2
        \\end
        \\
    ;
    try expectStableFormat(source, source);
}

test "Formatter: imports with comments keep their order" {
    // Sorting moved the imports away from their comments: `# bee` ended up above `a`.
    const commented = "import \"./b.kup\" # bee\nimport \"./a.kup\" # ay\n\ncube(1)\n";
    const formatted = try formatCodeLocal(testing.allocator, commented, .{});
    defer testing.allocator.free(formatted);
    try testing.expectEqualStrings(commented, formatted);
    // Without comments in the run, the imports are sorted; a header above them is fine.
    const sorted = try formatCodeLocal(testing.allocator, "# header\nimport \"./b.kup\"\nimport \"./a.kup\"\n\ncube(1)\n", .{});
    defer testing.allocator.free(sorted);
    try testing.expectEqualStrings("# header\nimport \"./a.kup\"\nimport \"./b.kup\"\n\ncube(1)\n", sorted);
}

test "Formatter: the checked API accepts the constructs it used to refuse" {
    const api = @import("../../api.zig");
    for ([_][]const u8{
        "u = \"say \\\"hi\\\"\"\n",
        "v = :\"with space\"\n",
        "f = ->(a, b = 2) { a + b }\n",
        "g = ->(*xs) { xs }\n",
        "def r\n  return []\nend\n",
        "import { a as b } from \"./x.kup\"\n",
        "class B < A\n  def f\n    super()\n  end\nend\n",
        "a, = [1, 2]\n",
        "*m, = [1, 2]\n",
    }) |source| {
        errdefer std.debug.print("source:\n{s}\n", .{source});
        const formatted = try api.formatCode(testing.allocator, source, .{});
        defer testing.allocator.free(formatted);
        try testing.expectEqualStrings(source, formatted);
    }
}

test "Formatter: a comment ending the file without a newline stays on its own line" {
    // It was glued to the statement above (`x = 1# c`, a blank line before it lost), and
    // formatting that again added a space: found by the front-end fuzz test.
    try expectStableFormat("x = 1\n\n# c", "x = 1\n\n# c\n");
    try expectStableFormat("x = 1\n# c", "x = 1\n# c\n");
    try expectStableFormat("def f\n  1\nend\n# c", "def f\n  1\nend\n# c\n");
}

test "Formatter: a call on an expression with no name keeps its form" {
    // `(f)(2)` (which fails when run: a lambda takes .call) was printed `(f).(2)`, which
    // doesn't parse, so the formatter refused the file: found by the front-end fuzz test.
    try expectStableFormat("(1) (2)", "(1)(2)\n");
    try expectStableFormat("x = (a + b)()", "x = (a + b)()\n");
    try expectStableFormat("y = (a + b)(1, 2).first", "y = (a + b)(1, 2).first\n");
}

test "Formatter: a multiple assignment to one name keeps its comma" {
    // `a, = list` took the first element; printed `a = list`, it assigned the whole list,
    // so the formatter refused the file: found by the front-end fuzz test.
    try expectStableFormat("a, = [1, 2]", "a, = [1, 2]\n");
}

test "Formatter: an assignment passed as an argument keeps its arguments" {
    // Laid out over lines it took a trailing comma, `b = 5,`, which read back as b = [5, ...]:
    // found by the front-end fuzz test.
    try expectStableFormat("o a,\nb = 5\n", "o(\n  a,\n  b = 5,\n)\n");
    try expectStableFormat("o(b = 5, 6)", "o(b = 5, 6)\n");
}

test "Formatter: a single-quoted or %q string keeps its text, backslashes and all" {
    // Its value is now decoded by its own rules (only \\ and the delimiter escape), so the
    // text still decodes to the value and is written back as it was.
    try expectStableFormat("x = 'C:\\data\\new'\n", "x = 'C:\\data\\new'\n");
    try expectStableFormat("y = 'it\\'s'\n", "y = 'it\\'s'\n");
    // %q was rewritten as a double-quoted string, which needed escapes it was written to avoid
    try expectStableFormat("z = %q(a \\) b \\d \"q\")\n", "z = %q(a \\) b \\d \"q\")\n");
    try expectStableFormat("w = %q[nested [x] y]\n", "w = %q[nested [x] y]\n");
    // Quotes as its delimiter: written as "a\nb" it would hold a newline
    try expectStableFormat("v = %q\"a\\nb\"\n", "v = %q\"a\\nb\"\n");
    try expectStableFormat("u = %q'it\\'s'\n", "u = %q'it\\'s'\n");
}

test "Formatter: a quoted symbol named with colons keeps its name" {
    // The parser dropped a leading colon of the name, so `:":"` was the empty symbol and
    // formatted to a lone `:`, which doesn't parse (found by the nightly fuzzer).
    try expectStableFormat("x = :\":\"\n", "x = :\":\"\n");
    try expectStableFormat("y = :\"::x\"\n", "y = :\"::x\"\n");
}

test "Formatter: a comment before a list's closing bracket stays at its items' indent, formatted again too" {
    // It was written after the indent dropped, so a second pass moved it out to the
    // bracket's: the nightly fuzzer found `f(` + `x, # a` + `# b` + `)` formatting two ways.
    const stable = [_][]const u8{
        "f(\n  x, # trailing\n  # own line\n)\n",
        "xs = [\n  1,\n  2,\n  # more to come\n]\n",
        "h = {\n  a: 1,\n  # b: 2\n}\n",
    };
    for (stable) |source| {
        errdefer std.debug.print("source:\n{s}\n", .{source});
        try expectFormat(source, source);
    }
    try expectFormat("f(\n  x,\n# own line\n)\n", "f(\n  x,\n  # own line\n)\n");
}

test "Formatter: a map key that is a name or a call keeps its value after =>" {
    // `{ a.k: 1 }` means `{ a.k => 1 }`, which the formatter writes, but a name before `=>`
    // was read as a call without parentheses, `k(=> 1)`, so the output didn't parse (found
    // by the nightly front-end fuzzer).
    try expectStableFormat("m = { a.k: 1 }\n", "m = { a.k => 1 }\n");
    try expectStableFormat("m = { (1...5).k: 1, \"s\" => 2 }\n", "m = { (1...5).k => 1, \"s\" => 2 }\n");
    try expectStableFormat("k = 2\nm = { k => 1 }\n", "k = 2\nm = { k => 1 }\n");
}
