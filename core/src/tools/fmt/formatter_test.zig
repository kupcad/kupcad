const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");

/// Helper to parse, format, and strictly compare the output.
/// We disable `sort_imports` here to strictly test the canonical layout engine.
fn expectFormat(source: []const u8, expected: []const u8) !void {
    const allocator = testing.allocator;
    const formatted = try api.formatCode(allocator, source, .{ .sort_imports = false });
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
    // The formatter forces chained method calls onto new indented lines
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
    // Replaced OpenSCAD `for` loop with a valid `until` loop to ensure syntax passes
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
