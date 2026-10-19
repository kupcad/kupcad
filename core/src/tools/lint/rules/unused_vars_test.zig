const std = @import("std");
const testing = std.testing;
const linter_mod = @import("../linter.zig");
const UnusedVarsRule = @import("unused_vars.zig").UnusedVarsRule;
const lint_testing = @import("../testing.zig");

fn runRule(allocator: std.mem.Allocator, source: []const u8) !linter_mod.Linter {
    return lint_testing.lint(allocator, source, lint_testing.only(UnusedVarsRule.id));
}

test "Linter Rule: UnusedVarsRule catches unused variables" {
    const source =
        \\x = 10
        \\_y = 20
        \\z = 30
        \\cube(z)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'x'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnusedVarsRule detects usage across nested scopes" {
    const source =
        \\wall_thickness = 5.0
        \\begin
        \\  cube(wall_thickness)
        \\end
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "Linter Rule: UnusedVarsRule flags unused function parameters" {
    // Note: Since `build_part` is defined at the top level and never called, it WILL also trigger an unused warning!
    // We add a dummy call to `build_part` to ensure it is marked as used so we ONLY flag `height`.
    const source =
        \\def build_part(width, height)
        \\  cube(width)
        \\end
        \\build_part(10, 20)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'height'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnusedVarsRule handles arbitrary nested destructuring in block parameters" {
    const source =
        \\items.each do |((a, b), _c)|
        \\  cube(a)
        \\end
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'b'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnusedVarsRule follows the language's scopes and what counts as a use" {
    // Each of these used to report a variable that is read (or is the model).
    const clean = [_][]const u8{
        "box = cube(10)\npart = box - cube(2)", // the script's last statement is the model
        "if ok\n  y = 1\nend\nputs y", // if, while and for bodies open no scope
        "for i in [1]\nend\nputs i",
        "n = 0\nwhile n < 1\n  z = 5\n  n += 1\nend\nputs z", // n += 1 reads n
        "x = 1\nexport x",
        "def f\n  r = 1\nend\nputs f", // a method's last statement is its result
        "puts [1].map { |v| w = v * 2 }",
    };
    for (clean) |src| {
        errdefer std.debug.print("source:\n{s}\n", .{src});
        var engine = try runRule(testing.allocator, src);
        defer engine.deinit();
        try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }

    // Still reported: assigned and never read.
    const unused = [_]struct { src: []const u8, name: []const u8 }{
        .{ .src = "unused = 1\nputs 2", .name = "unused" },
        .{ .src = "def f(a)\n  t = a\n  1\nend\nputs f(1)", .name = "t" },
        .{ .src = "[1].each { |v| q = v\n  puts 1 }", .name = "q" },
        .{ .src = "if ok\n  y = 1\nend\nputs 2", .name = "y" },
    };
    for (unused) |case| {
        errdefer std.debug.print("source:\n{s}\n", .{case.src});
        var engine = try runRule(testing.allocator, case.src);
        defer engine.deinit();
        try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
        const expected = try testing.allocator.print("Unused variable '{s}'. Prefix with '_' if intentional.", .{case.name});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, engine.diagnostics.items[0].message);
    }
}

test "Linter Rule: UnusedVarsRule leaves a class's and a module's methods alone" {
    // They are called through the class's objects (`G.new.teeth`), outside the class's
    // scope, so every method of a class was reported unused.
    const source =
        \\class Gear
        \\  def teeth(n)
        \\    n * 2
        \\  end
        \\  class << self
        \\    def standard = new
        \\  end
        \\end
        \\module Parts
        \\  def self.bolt = 1
        \\end
        \\def helper = 1
        \\Gear.standard.teeth(3)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    // A script's own top-level method is still reported when nothing calls it.
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'helper'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnusedVarsRule leaves a class's or module's constants alone" {
    // They are read through the namespace (`Sizes::W`), here or in a file that imports it,
    // and were reported as unused variables even when read. A local in the body still is.
    const source =
        \\module Sizes
        \\  W = 4
        \\  H = 2
        \\  scratch = 1
        \\end
        \\class Plate
        \\  THICKNESS = 3
        \\end
        \\cube(Sizes::W)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'scratch'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnusedVarsRule leaves fields, class variables and globals alone" {
    // A field set in `initialize` and read in another method was reported unused unless it
    // was the method's last statement: `@`, `@@` and `$` names outlive the method.
    const source =
        \\class Part
        \\  @@count = 0
        \\  def initialize(size)
        \\    @size = size
        \\    @@count += 1
        \\    $last = self
        \\  end
        \\  def volume = @size ** 3
        \\end
        \\cube(Part.new(2).volume)
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
}

test "Linter Rule: UnusedVarsRule counts a call from a method defined above" {
    // `b` was reported unused when the method calling it came first.
    const source =
        \\def a = b() + 1
        \\def b = 1
        \\def unused_helper = 2
        \\cube(a())
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'unused_helper'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}

test "Linter Rule: UnusedVarsRule counts the parameters a bare super passes on" {
    // `super` without arguments passes the method's own: its parameter was reported unused
    // (found writing the fuzz corpus). One `super(...)` doesn't pass still is.
    const source =
        \\class A
        \\  def go(x, y) = x + y
        \\end
        \\class B < A
        \\  def go(x, y)
        \\    [1].each { |i| i }
        \\    super
        \\  end
        \\  def other(z) = super(1)
        \\end
        \\cube(B.new.go(1, 2))
    ;
    var engine = try runRule(testing.allocator, source);
    defer engine.deinit();

    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    try testing.expectEqualStrings("Unused variable 'z'. Prefix with '_' if intentional.", engine.diagnostics.items[0].message);
}
