//! Language semantics checked end to end: each test runs scripts on a fresh VM through
//! test_support, so a fix here is guarded by the script that used to go wrong.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

test "Language: iterators follow the receiver as the block grows it" {
    // The block pushed to the array it iterated; the slice taken once read the freed buffer
    // (the values came back as 1.19e104). As in Ruby, the iteration reaches what was pushed.
    try expectScripts(&.{
        .{ .src = "a = [1, 2, 3]\nr = a.map { |x| 100.times { a.push(0) } if x == 1; x * 10 }.slice(0, 4)", .expected = .{ .nums = &.{ 10, 20, 30, 0 } } },
        .{ .src = "a = [1]\nseen = []\na.each { |x| a.push(x + 1) if x < 5; seen.push(x) }\nr = seen", .expected = .{ .nums = &.{ 1, 2, 3, 4, 5 } } },
        .{ .src = "a = [1, 2, 3]\nr = a.reduce(0) { |acc, x| 100.times { a.push(100) } if x == 1; acc + x }", .expected = .{ .num = 6 + 100 * 100 } },
        .{ .src = "a = [1, 2, 3, 4]\nr = a.filter { |x| 100.times { a.push(6) } if x == 1; x.even? }.slice(0, 3)", .expected = .{ .nums = &.{ 2, 4, 6 } } },
        .{ .src = "m = { a: 1 }\nr = []\nm.each { |k, v| 40.times { |i| m[\"k#{i}\"] = i } if k == :a; r.push(v) }\nr = r.slice(0, 3)", .expected = .{ .nums = &.{ 1, 0, 1 } } },
        .{ .src = "m = { a: 1, b: 2 }\nr = m.map { |k, v| 40.times { |i| m[\"k#{i}\"] = i } if k == :a; v }.slice(0, 3)", .expected = .{ .nums = &.{ 1, 2, 0 } } },
    });
}

test "Language: break out of an iterating method's block hands back its value" {
    // The break value stayed on the stack, so the values after it were off by one:
    // `show(1, xs.each { break 2 })` called the Number 2.
    try expectScripts(&.{
        .{ .src = "r = [1, [10, 20].each { |v| break v * 2 }]", .expected = .{ .nums = &.{ 1, 20 } } },
        .{ .src = "h = {}\nh[:k] = 3.times { break 42 }\nr = h[:k]", .expected = .{ .num = 42 } },
        .{ .src = "r = [0, 1.upto(9) { |i| break i if i == 4 }]", .expected = .{ .nums = &.{ 0, 4 } } },
        .{ .src = "r = [0, CAD.with_config(tolerance: 0.1) { break 7 }, CAD.current_config[:tolerance]]", .expected = .{ .nums = &.{ 0, 7, 1e-5 } } },
        // filter, reject, reduce, sort and Map#each used to fail with "failed (BlockBreak)".
        .{ .src = "r = [1, 2, 3].filter { |x| break 9 }", .expected = .{ .num = 9 } },
        .{ .src = "r = [1, 2, 3].reject { |x| break 8 }", .expected = .{ .num = 8 } },
        .{ .src = "r = [1, 2, 3].reduce { |a, b| break 7 }", .expected = .{ .num = 7 } },
        .{ .src = "r = { a: 1 }.each { |k, v| break 6 }", .expected = .{ .num = 6 } },
        .{ .src = "r = { a: 1 }.map { |k, v| break 5 }", .expected = .{ .num = 5 } },
        // A yielding method: break returns the break value, not the first yielded argument.
        .{ .src = "def each_twice\n  yield 1\n  yield 2\nend\nr = each_twice { |x| break x * 100 }", .expected = .{ .num = 100 } },
        .{ .src = "def pair\n  yield 7, 8\nend\nr = pair { |a, b| break a + b }", .expected = .{ .num = 15 } },
        // Nothing broke: the method's own value.
        .{ .src = "def pair\n  yield 7, 8\n  3\nend\nr = pair { |a, b| a + b }", .expected = .{ .num = 3 } },
    });
}

test "Language: break in a block that isn't an iteration is an error, not a crash" {
    try expectScripts(&.{
        .{ .src = rescued("highlight { break 5 }"), .expected = .{ .str = "ArgumentError: break can only stop a block given to an iterating method, not highlight's" } },
        .{ .src = rescued("benchmark { break 5 }"), .expected = .{ .str = "ArgumentError: break can only stop a block given to an iterating method, not benchmark's" } },
        // The stack is balanced afterwards.
        .{ .src = "x = begin\n  highlight { break 5 }\nrescue ArgumentError => e\n  1\nend\nr = [x, 2]", .expected = .{ .nums = &.{ 1, 2 } } },
    });
}

test "Language: a call's block survives a collection while its splat is packed" {
    // dispatchClosure popped the block into a Zig local before the splat Array was
    // allocated; a collection there swept it, and `yield` found no block.
    try expectScripts(&.{
        .{ .src = "def f(*args)\n  yield args.length\nend\nr = 0\n50.times { r += f(1, 2) { |n| n + 1 } }", .expected = .{ .num = 150 }, .gc_stress = true },
        .{ .src = "def g(a, *rest, &blk)\n  blk.call(rest.length)\nend\nr = g(1, 2, 3) { |n| n * 10 }", .expected = .{ .num = 20 }, .gc_stress = true },
    });
}

test "Language: a call site follows a method redefined after it ran" {
    // Inline caches were never invalidated: the site kept calling the first definition,
    // and once a collection freed it, called freed memory (NoMethodError, or worse).
    try expectScripts(&.{
        .{ .src = "class A\n  def v\n    1\n  end\nend\na = A.new\ndef call_v(x)\n  x.v\nend\nfirst = call_v(a)\nclass A\n  def v\n    2\n  end\nend\nr = [first, call_v(a), a.v]", .expected = .{ .nums = &.{ 1, 2, 2 } } },
        // A subclass that overrides later, and a redefinition followed by a collection.
        .{ .src = "class A\n  def foo\n    3\n  end\nend\nclass B < A\nend\ndef go(x)\n  x.foo\nend\nb = B.new\nfirst = go(b)\nclass B\n  def foo\n    4\n  end\nend\nr = [first, go(b)]", .expected = .{ .nums = &.{ 3, 4 } } },
        .{ .src = "class A\n  def foo\n    1\n  end\nend\ndef go(x)\n  x.foo\nend\na = A.new\ngo(a)\nclass A\n  def foo\n    2\n  end\nend\nGC.collect\nr = go(a)", .expected = .{ .num = 2 }, .gc_stress = true },
        // A module included after the site cached a miss.
        .{ .src = "module M\n  def m\n    5\n  end\nend\nclass A\n  def initialize\n    @x = 1\n  end\nend\na = A.new\ndef x_of(o)\n  o.x\nend\nfirst = x_of(a)\nclass A\n  include M\n  def x\n    9\n  end\nend\nr = [first, x_of(a), a.m]", .expected = .{ .nums = &.{ 1, 9, 5 } } },
    });
}

test "Language: a field read through a call site stays a field read" {
    // `p.x` with no method `x` is a field read; the site cached it as a miss and went
    // down the full lookup (and interned a private name) on every call.
    try expectScripts(&.{
        .{ .src = "class P\n  def initialize(x)\n    @x = x\n  end\nend\np = P.new(3)\nr = 0\n100.times { r += p.x }", .expected = .{ .num = 300 }, .gc_stress = true },
        .{ .src = "class P\n  def initialize\n    @x = 1\n  end\n  def set(v)\n    @x = v\n  end\nend\np = P.new\nq = P.new\nq.set(5)\nr = [p.x, q.x]", .expected = .{ .nums = &.{ 1, 5 } } },
    });
}

test "Language: sort is bounded whatever the input, and reports what it can't compare" {
    // The hand-written quicksort overran its 64-entry partition buffer on a few hundred
    // sorted numbers (index out of bounds; a buffer overrun in release).
    try expectScripts(&.{
        .{ .src = "s = (1..300).to_a.sort\nr = [s.first, s.last, s.size, s[149]]", .expected = .{ .nums = &.{ 1, 300, 300, 150 } } },
        .{ .src = "s = (1..300).to_a.sort { |a, b| b <=> a }\nr = [s.first, s.last]", .expected = .{ .nums = &.{ 300, 1 } } },
        .{ .src = "r = [3, 1, 2].sort", .expected = .{ .nums = &.{ 1, 2, 3 } } },
        .{ .src = "r = [\"pear\", \"apple\", \"fig\"].sort.join(\",\")", .expected = .{ .str = "apple,fig,pear" } },
        .{ .src = rescued("[1, \"a\"].sort"), .expected = .{ .str = "ArgumentError: sort can't compare String with Number; give it a block" } },
        .{ .src = rescued("[2, 1].sort { |a, b| \"x\" }"), .expected = .{ .str = "TypeError: sort block must return a Number (-1, 0, 1)." } },
        .{ .src = rescued("[2, 1].sort { |a, b| raise \"no\" }"), .expected = .{ .str = "RuntimeError: no" } },
        .{ .src = "r = [2, 1, 3].sort { |a, b| break 7 }", .expected = .{ .num = 7 } },
        // The receiver is left alone.
        .{ .src = "a = [3, 1, 2]\na.sort\nr = a", .expected = .{ .nums = &.{ 3, 1, 2 } } },
    });
}

test "Language: inspect prints a container that holds itself as [...], and escapes strings" {
    try expectScripts(&.{
        .{ .src = "a = [1]\na.push(a)\nr = a.inspect", .expected = .{ .str = "[1, [...]]" } },
        .{ .src = "m = { a: 1 }\nm[:me] = m\nr = m.inspect", .expected = .{ .str = "{a: 1, me: {...}}" } },
        .{ .src = "a = [1]\nb = [a]\na.push(b)\nr = \"#{a}\"", .expected = .{ .str = "[1, [[...]]]" } },
        // 301 levels deep: the print stops at 256, as a cycle would.
        .{ .src = "a = []\n300.times { a = [a] }\nr = a.inspect.length", .expected = .{ .num = 517 } },
        .{ .src = "r = (\"say \\\"hi\\\"\" + \"\\n\\t\\\\\").inspect", .expected = .{ .str = "\"say \\\"hi\\\"\\n\\t\\\\\"" } },
        .{ .src = "r = (\"a#\" + \"{b}\").inspect", .expected = .{ .str = "\"a\\#{b}\"" } },
        .{ .src = "r = [\"x\\\"y\"].inspect", .expected = .{ .str = "[\"x\\\"y\"]" } },
    });
}

test "Language: split on an empty String and clamp with reversed bounds don't trip asserts" {
    try expectScripts(&.{
        .{ .src = "r = \"abc\".split(\"\").join(\"|\")", .expected = .{ .str = "a|b|c" } },
        .{ .src = "r = \"héllo\".split(\"\").length", .expected = .{ .num = 5 } },
        .{ .src = "r = \"\".split(\"\").length", .expected = .{ .num = 0 } },
        .{ .src = "r = Math.clamp(5, 0, 10) + Math.clamp(-1, 0, 10) + Math.clamp(99, 0, 10)", .expected = .{ .num = 15 } },
        .{ .src = rescued("Math.clamp(5, 10, 0)"), .expected = .{ .str = "ArgumentError: Math.clamp needs its low bound first, got 10 and 0" } },
        .{ .src = rescued("Math.clamp(5, Number::NAN, 0)"), .expected = .{ .str = "ArgumentError: Math.clamp needs its low bound first, got NaN and 0" } },
    });
}
