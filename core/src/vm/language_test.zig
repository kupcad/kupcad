//! Language semantics checked end to end: each test runs scripts on a fresh VM through
//! test_support, so a fix here is guarded by the script that used to go wrong.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

const TO_S_CLASS = "class P\n  def initialize(x)\n    @x = x\n  end\n  def to_s\n    \"P(#{@x})\"\n  end\nend\n";

test "Language: iterators follow the receiver as the block grows it" {
    // The block pushed to the array it iterated; the slice taken once read the freed buffer
    // (the values came back as 1.19e104). As in Ruby, the iteration reaches what was pushed.
    try expectScripts(&.{
        .{ .src = "a = [1, 2, 3]\nr = a.map { |x| 100.times { a.push(0) } if x == 1; x * 10 }.slice(0, 4)", .expected = .{ .nums = &.{ 10, 20, 30, 0 } } },
        .{ .src = "a = [1]\nseen = []\na.each { |x| a.push(x + 1) if x < 5; seen.push(x) }\nr = seen", .expected = .{ .nums = &.{ 1, 2, 3, 4, 5 } } },
        .{ .src = "a = [1, 2, 3]\nr = a.reduce(0) { |acc, x| 100.times { a.push(100) } if x == 1; acc + x }", .expected = .{ .num = 6 + 100 * 100 } },
        .{ .src = "a = [1, 2, 3, 4]\nr = a.filter { |x| 100.times { a.push(6) } if x == 1; x.even? }.slice(0, 3)", .expected = .{ .nums = &.{ 2, 4, 6 } } },
        // A Map's give the entries there when they began (Ruby refuses a key added then)
        .{ .src = "m = { a: 1 }\nr = []\nm.each { |k, v| 40.times { |i| m[\"k#{i}\"] = i } if k == :a; r.push(v) }\nr = r.push(m.length)", .expected = .{ .nums = &.{ 1, 41 } } },
        .{ .src = "m = { a: 1, b: 2 }\nr = m.map { |k, v| 40.times { |i| m[\"k#{i}\"] = i } if k == :a; v }", .expected = .{ .nums = &.{ 1, 2 } } },
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
        .{ .src = rescued("[1, \"a\"].sort"), .expected = .{ .str = "TypeError: sort can't compare Number with String; give it a block" } },
        // NaN orders with nothing: the sort's order was whatever the comparisons gave
        .{ .src = rescued("[3, Number::NAN, 1].sort"), .expected = .{ .str = "MathError: sort: the Array holds NaN at index 1" } },
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

test "Language: a block inside a method sees the method's block, self and class" {
    // yield, block_given?, super and private calls in a block read the block's own frame,
    // where slot 0 is the block and there is no block slot: "No block given", "super can
    // only be called on instances", "private method called".
    try expectScripts(&.{
        .{ .src = "def each_doubled(xs)\n  xs.each { |x| yield x * 2 }\nend\nr = []\neach_doubled([1, 2]) { |v| r.push(v) }", .expected = .{ .nums = &.{ 2, 4 } } },
        .{ .src = "def given\n  [1].map { block_given? }.first\nend\nr = \"#{given} #{given { }}\"", .expected = .{ .str = "false true" } },
        .{ .src = "def g\n  f = ->() { yield 1 }\n  f.call\nend\nr = g { |v| v + 1 }", .expected = .{ .num = 2 } },
        .{ .src = "class A\n  def foo(x)\n    x * 2\n  end\nend\nclass B < A\n  def foo(x)\n    [x].map { |y| super(y) }.first\n  end\nend\nr = B.new.foo(5)", .expected = .{ .num = 10 } },
        .{ .src = "class K\n  private def helper\n    7\n  end\n  def run\n    [1].map { self.helper }.first\n  end\n  def other(o)\n    o.helper\n  end\nend\nr = K.new.run + K.new.other(K.new)", .expected = .{ .num = 14 } },
        .{ .src = rescued("class K\n  private def helper\n    7\n  end\nend\nK.new.helper"), .expected = .{ .str = "NoMethodError: private method 'helper' called." } },
    });
}

test "Language: super starts above the class that defines the running method" {
    // It started above the receiver's class: with C < B < A, B#foo's super on a C found
    // B#foo again, until the call stack overflowed.
    try expectScripts(&.{
        .{ .src = "class A\n  def foo\n    \"A\"\n  end\nend\nclass B < A\n  def foo\n    \"B\" + super\n  end\nend\nclass C < B\nend\nr = C.new.foo", .expected = .{ .str = "BA" } },
        .{ .src = "class A\n  def foo\n    \"A\"\n  end\nend\nclass B < A\n  def foo\n    \"B\" + super\n  end\nend\nclass C < B\n  def foo\n    \"C\" + super\n  end\nend\nr = C.new.foo", .expected = .{ .str = "CBA" } },
    });
}

test "Language: a new class variable belongs to the class that assigns it" {
    // It was bound to the root class, so A's @@x was visible from an unrelated B.
    try expectScripts(&.{
        .{ .src = rescued("class A\n  def self.set\n    @@x = 1\n  end\nend\nclass B\n  def self.get\n    @@x\n  end\nend\nA.set\nB.get"), .expected = .{ .str = "NameError: Undefined class variable '@@x'." } },
        .{ .src = "class A\n  def set\n    @@x = 1\n  end\n  def self.get\n    @@x\n  end\nend\nclass B < A\nend\nB.new.set\nr = A.get + B.get", .expected = .{ .num = 2 } },
    });
}

test "Language: yield, block_given? and super outside a method are compile errors" {
    // A top-level yield read a stale stack slot above the frame and called whatever the
    // previous statement had left there.
    for ([_][]const u8{ "yield", "r = block_given?", "super", "f = ->() { yield 1 }\nf.call", "def m\n  [1].each { super }\nend" }) |src| {
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectError(error.OutsideMethod, support.runOn(&vm, src));
    }
}

test "Language: ensure runs when an error leaves the begin" {
    // Only a matched rescue reached the ensure body: an error no clause matched, one raised
    // by a rescue clause, or one leaving a begin with no rescue at all skipped it.
    try expectScripts(&.{
        .{ .src = "log = []\nbegin\n  begin\n    raise \"x\"\n  ensure\n    log.push(\"e\")\n  end\nrescue => e\n  log.push(e.message)\nend\nr = log.join(\" \")", .expected = .{ .str = "e x" } },
        .{ .src = "log = []\nbegin\n  begin\n    raise \"x\"\n  rescue TypeError => e\n    log.push(\"wrong\")\n  ensure\n    log.push(\"e\")\n  end\nrescue => e\n  log.push(e.message)\nend\nr = log.join(\" \")", .expected = .{ .str = "e x" } },
        .{ .src = "log = []\nbegin\n  begin\n    raise \"a\"\n  rescue => e\n    raise \"b\"\n  ensure\n    log.push(\"e\")\n  end\nrescue => e\n  log.push(e.message)\nend\nr = log.join(\" \")", .expected = .{ .str = "e b" } },
        .{ .src = "r = begin\n  begin\n    raise \"a\"\n  ensure\n    raise \"b\"\n  end\nrescue => e\n  e.message\nend", .expected = .{ .str = "b" } },
        // Once, on every other way out.
        .{ .src = "log = []\nbegin\n  raise \"x\"\nrescue => e\n  log.push(\"r\")\nensure\n  log.push(\"e\")\nend\nr = log.join(\" \")", .expected = .{ .str = "r e" } },
        .{ .src = "log = []\nbegin\n  log.push(\"b\")\nensure\n  log.push(\"e\")\nend\nr = log.join(\" \")", .expected = .{ .str = "b e" } },
        .{ .src = "def f(log)\n  begin\n    raise \"x\"\n  rescue => e\n    return \"ret\"\n  ensure\n    log.push(\"e\")\n  end\nend\nlog = []\nlog.push(f(log))\nr = log.join(\" \")", .expected = .{ .str = "e ret" } },
        .{ .src = "log = []\n[1, 2].each do |i|\n  begin\n    next if i == 1\n    log.push(i)\n  ensure\n    log.push(\"e\")\n  end\nend\nr = log.join(\" \")", .expected = .{ .str = "e 2 e" } },
    });
}

test "Language: ensure runs before an uncaught error ends the script" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.runtime_error, try support.runOn(&vm, "log = []\nbegin\n  raise \"x\"\nensure\n  log.push(\"e\")\nend\nlog.push(\"unreached\")"));
    const log = (vm.globals.get("log") orelse return error.MissingGlobal).asArray().items.items;
    try testing.expectEqual(@as(usize, 1), log.len);
    try support.expectValue(.{ .str = "e" }, log[0]);
}

test "Language: a method left by its block's break drops its rescue handlers" {
    // The handler of a begin around the yield outlived the method; the next error jumped
    // to it in whatever frame had the method's index.
    try expectScripts(&.{
        .{ .src = "def m\n  begin\n    yield\n  rescue => e\n    \"rescued \" + e.message\n  end\nend\nfirst = m { break \"broke\" }\nsecond = begin\n  raise \"boom\"\nrescue => e\n  e.message\nend\nr = first + \" \" + second", .expected = .{ .str = "broke boom" } },
        .{ .src = "def m\n  begin\n    [1].each { yield }\n  rescue => e\n    \"rescued\"\n  end\nend\nfirst = m { break \"broke\" }\nr = first + \" \" + (begin\n  raise \"boom\"\nrescue => e\n  e.message\nend)", .expected = .{ .str = "broke boom" } },
    });
}

test "Language: break leaves the method the block was given to, however it got called" {
    // A method yielding from inside another block (`xs.each { |x| yield x }`) kept going:
    // the break stopped the inner block only, so each went on and the block ran again.
    try expectScripts(&.{
        .{ .src = "def each_doubled(xs)\n  xs.each { |x| yield x * 2 }\n  :finished\nend\nr = each_doubled([1, 2, 3]) { |v| break v if v > 2 }", .expected = .{ .num = 4 } },
        .{ .src = "def m\n  [1, 2].each { |i| yield i }\n  99\nend\nr = m { |i| break i * 10 }", .expected = .{ .num = 10 } },
        .{ .src = "def m(&b)\n  [1, 2].each(&b)\n  99\nend\nr = m { |i| break i + 5 }", .expected = .{ .num = 6 } },
        .{ .src = "def m(&b)\n  [1, 2].each { |i| b.call(i) }\n  99\nend\nr = m { |i| break i + 5 }", .expected = .{ .num = 6 } },
        .{ .src = "def helper\n  yield\n  :helper_done\nend\ndef m\n  helper { yield 1 }\n  99\nend\nr = m { |v| break v + 1 }", .expected = .{ .num = 2 } },
        .{ .src = "def m\n  [1].map { [2].map { yield } }\n  99\nend\nr = m { break 7 }", .expected = .{ .num = 7 } },
        // The value travels through two natives while they clean up; it must stay rooted.
        .{ .src = "def m\n  [1].map { [2].map { yield } }\n  99\nend\nr = m { break \"br\" + \"oke\" }", .expected = .{ .str = "broke" }, .gc_stress = true },
        // A block given to a native stops that native only: m goes on.
        .{ .src = "def m\n  [1, 2].each { |i| break i }\n  99\nend\nr = m { }", .expected = .{ .num = 99 } },
        .{ .src = "log = []\ndef m(log)\n  [1, 2].each { |i| yield i }\n  log.push(:after)\nend\nm(log) { |i| log.push(i); break if i == 1 }\nr = log.length", .expected = .{ .num = 1 } },
    });
}

/// Runs `source` with `files` ({ path, content } pairs) available to `import`; checks `r`.
fn expectImported(files: []const [2][]const u8, source: []const u8, expected: support.Expected) !void {
    const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    for (files) |file| try mem_vfs.vfs().writeFile(file[0], file[1]);
    var vm = try support.initVm();
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();
    errdefer std.debug.print("script:\n{s}\n", .{source});
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    try support.expectValue(expected, vm.globals.get("r") orelse return error.MissingGlobal);
}

test "Language: a module sees builtins, never the importing script's variables" {
    // The compiler decides whether a bare name is a variable or a call from what the VM
    // knows; for a module that is the builtins only (what lookupGlobal gives it), not the
    // main script's `size = 10` or `def plate`, which stay out of reach either way.
    try expectImported(&.{.{ "lib.kup", "def read\n  size\nend\nexport read" }}, comptime ("size = 10\nimport { read } from \"./lib.kup\"\n" ++ rescued("read")), .{ .str = "NameError: Undefined variable 'size'" });
    try expectImported(&.{.{ "lib.kup", "def read\n  plate\nend\nexport read" }}, comptime ("def plate\n  1\nend\nimport { read } from \"./lib.kup\"\n" ++ rescued("read")), .{ .str = "NameError: Undefined variable 'plate'" });
}

test "Language: a module whose value is nil can be imported again" {
    // A nil in the module cache marked an import in progress, so the second import of a
    // module ending in an assignment of nil, a def or a puts was a circular dependency.
    try expectImported(&.{.{ "lib.kup", "x = nil" }}, "import \"./lib.kup\"\nimport \"./lib.kup\"\nr = 1", .{ .num = 1 });
    try expectImported(&.{ .{ "a.kup", "import \"./b.kup\"\nx = 1\nexport x" }, .{ "b.kup", "import \"./a.kup\"" } }, rescued("import \"./a.kup\""), .{ .str = "ImportError: Circular dependency detected for 'a.kup'" });
}

test "Language: raise with a class raises an instance of it" {
    // `raise Klass, "msg"` dropped the message and threw the class itself, on which
    // `e.message` was a NoMethodError; `raise Klass` did the same.
    try expectScripts(&.{
        .{ .src = rescued("raise ArgumentError, \"bad\""), .expected = .{ .str = "ArgumentError: bad" } },
        .{ .src = rescued("raise ArgumentError"), .expected = .{ .str = "ArgumentError: ArgumentError" } },
        .{ .src = "class MyError < StandardError\nend\nr = begin\n  raise MyError, \"x\"\nrescue MyError => e\n  e.message\nend", .expected = .{ .str = "x" } },
        .{ .src = "class MyError < StandardError\n  def initialize(code)\n    super(\"code #{code}\")\n  end\nend\nr = begin\n  raise MyError, 7\nrescue StandardError => e\n  e.message\nend", .expected = .{ .str = "code 7" } },
        .{ .src = "class MyError < StandardError\n  def initialize\n    super(\"fixed\")\n  end\nend\nr = begin\n  raise MyError\nrescue => e\n  e.message\nend", .expected = .{ .str = "fixed" } },
        // initialize itself raising: its error is the one rescued
        .{ .src = "class Bad < StandardError\n  def initialize\n    raise \"inner\"\n  end\nend\nr = begin\n  raise Bad\nrescue => e\n  e.message\nend", .expected = .{ .str = "inner" } },
        .{ .src = "r = begin\n  raise ArgumentError\nrescue => e\n  e.backtrace.length > 0\nend", .expected = .{ .boolean = true } },
    });
}

test "Language: self in a class or module body is the namespace being defined" {
    // It was the script closure (slot 0 of the top-level frame): `@@count = 0` in a class
    // body had "no class context", and `self.helper` there called the script.
    try expectScripts(&.{
        .{ .src = "class A\n  @@count = 0\n  def self.inc\n    @@count = @@count + 1\n  end\nend\nA.inc\nr = A.inc", .expected = .{ .num = 2 } },
        .{ .src = "class A\n  def self.make\n    7\n  end\n  X = self.make\nend\nr = A::X", .expected = .{ .num = 7 } },
        .{ .src = "module M\n  def self.two\n    2\n  end\n  X = self.two\nend\nr = M::X", .expected = .{ .num = 2 } },
        // A block in the body sees the same self.
        .{ .src = "class A\n  @@items = []\n  def self.add(i)\n    @@items.push(i)\n  end\n  def self.items\n    @@items\n  end\n  [1, 2].each { |i| self.add(i) }\nend\nr = A.items", .expected = .{ .nums = &.{ 1, 2 } } },
        .{ .src = "class A\n  class << self\n    def hi\n      \"hi\"\n    end\n  end\nend\nr = A.hi", .expected = .{ .str = "hi" } },
        .{ .src = "class A\n  def self.hello\n    \"hello\"\n  end\nend\nclass A\n  GREETING = self.hello\nend\nr = A::GREETING", .expected = .{ .str = "hello" } },
    });
}

test "Language: a def takes the arguments it declares" {
    // Missing arguments were nil and extra ones dropped, as for a block; a Map that was
    // the last argument was taken for keyword arguments and moved into the slot of a
    // skipped parameter.
    try expectScripts(&.{
        .{ .src = rescued("def f(a, b)\n  a + b\nend\nf(1)"), .expected = .{ .str = "ArgumentError: f takes 2 arguments, got 1" } },
        .{ .src = rescued("def f(a, b)\n  a + b\nend\nf(1, 2, 3)"), .expected = .{ .str = "ArgumentError: f takes 2 arguments, got 3" } },
        .{ .src = "def g(a, b = 2)\n  a + b\nend\nr = [g(1), g(1, 5)]", .expected = .{ .nums = &.{ 3, 6 } } },
        .{ .src = rescued("def g(a, b = 2)\n  a + b\nend\ng"), .expected = .{ .str = "ArgumentError: g takes 1 to 2 arguments, got 0" } },
        .{ .src = "def h(a, *rest)\n  rest.length\nend\nr = h(1, 2, 3)", .expected = .{ .num = 2 } },
        .{ .src = rescued("def h(a, *rest)\n  rest.length\nend\nh"), .expected = .{ .str = "ArgumentError: h takes at least 1 argument, got 0" } },
        .{ .src = "def k(a, b: 2)\n  a + b\nend\nr = [k(1), k(1, b: 5)]", .expected = .{ .nums = &.{ 3, 6 } } },
        .{ .src = rescued("def k(a, b: 2)\n  a + b\nend\nk(1, 2)"), .expected = .{ .str = "ArgumentError: k takes 1 argument, got 2" } },
        .{ .src = rescued("def p(a)\n  a\nend\np(1, x: 2)"), .expected = .{ .str = "ArgumentError: p takes no keyword arguments" } },
        // A keyword with no default is required, and one it doesn't declare is refused (a
        // missing one was nil, and a mistyped one dropped): as a built-in's are
        .{ .src = rescued("def kw(a, k:, size: 1)\n  a\nend\nkw(1)"), .expected = .{ .str = "ArgumentError: kw needs the keyword 'k'" } },
        .{ .src = rescued("def kw(a, k:, size: 1)\n  a\nend\nkw(1, k: 2, sise: 3)"), .expected = .{ .str = "ArgumentError: kw does not take a keyword 'sise' (it accepts: k, size)" } },
        .{ .src = rescued("class A\n  def initialize(name:)\n    @name = name\n  end\nend\nA.new(nme: \"x\")"), .expected = .{ .str = "ArgumentError: initialize does not take a keyword 'nme' (it accepts: name)" } },
        // Given nil, it is given; **opts takes the rest
        .{ .src = "def kw(a, k:)\n  [a, k]\nend\nr = kw(1, k: nil).inspect", .expected = .{ .str = "[1, nil]" } },
        .{ .src = "def o(a, k: 1, **opts)\n  opts.length\nend\nr = o(1, x: 1, y: 2)", .expected = .{ .num = 2 } },
        .{ .src = "def q(m, n = 0)\n  m\nend\nr = q({ x: 1 })[:x]", .expected = .{ .num = 1 } },
        .{ .src = "class P\n  def initialize(x)\n    @x = x\n  end\nend\n" ++ "r = begin\n  P.new\nrescue ArgumentError => e\n  e.message\nend", .expected = .{ .str = "initialize takes 1 argument, got 0" } },
        // super forwards the keyword Map as keywords
        .{ .src = "class A\n  def f(a, b: 2)\n    a + b\n  end\nend\nclass B < A\n  def f(a, b: 2)\n    super * 10\n  end\nend\nr = B.new.f(1, b: 5)", .expected = .{ .num = 60 } },
        // Blocks and lambdas stay lenient, and get keywords through .call and yield.
        .{ .src = "f = ->(a, b: 2) { a + b }\nr = [f.call(1), f.call(1, b: 5), f.call(1, 9, b: 5)]", .expected = .{ .nums = &.{ 3, 6, 6 } } },
        .{ .src = "def y\n  yield 1, b: 5\nend\nr = y { |a, b: 2| a + b }", .expected = .{ .num = 6 } },
    });
}

test "Language: <= and >= are false against NaN; % is floored, folded or not" {
    // `a <= b` was `not (a > b)`, true for NaN; `%` is floored (the divisor's sign) in both
    // the VM and the compiler's constant folding, where Zig's @mod gave 7 % -3 = 1.
    try expectScripts(&.{
        .{ .src = "r = \"#{[Number::NAN <= 1, Number::NAN >= 1, 1 <= Number::NAN, 2 <= 2, 2 >= 3, 3 >= 3]}\"", .expected = .{ .str = "[false, false, false, true, false, true]" } },
        .{ .src = "x = -7\nr = [-7 % 3, x % 3, 7 % -3, x % -3, -7.5 % 2, x - 0.5 - (-7.5 % 2), 6 % 3, x % -7]", .expected = .{ .nums = &.{ 2, 2, -2, -1, 0.5, -8, 0, 0 } } },
        .{ .src = rescued("\"a\" <= 1"), .expected = .{ .str = "TypeError: '<=' can't combine String and Number" } },
    });
}

test "Language: round survives extreme decimal counts" {
    // round(400) overflowed the multiplier and gave NaN; round(-400) divided 0 by 0.
    try expectScripts(&.{
        .{ .src = "r = [2.5.round(400), 1234.5678.round(2), 1234.5678.round(-2), 5.round(-400), 2.5.round, 1e300.round(10)]", .expected = .{ .nums = &.{ 2.5, 1234.57, 1200, 0, 3, 1e300 } } },
        .{ .src = rescued("1.5.round(Number::INFINITY)"), .expected = .{ .str = "ValueError: round: the number of decimals must be finite, got Infinity" } },
    });
}

test "Language: Array#max, #min and #sum reject what they can't add or compare" {
    // Elements that weren't Numbers were skipped: ["a"].max was -Infinity, [1, nil].sum 1.
    try expectScripts(&.{
        .{ .src = "r = [[3, 9, 2].max, [3, 9, 2].min, [1, 2.5].sum, [].sum, [\"pear\", \"fig\"].max.length, [\"pear\", \"fig\"].min.length]", .expected = .{ .nums = &.{ 9, 2, 3.5, 0, 4, 3 } } },
        .{ .src = "r = [].max", .expected = .nil },
        .{ .src = rescued("[1, \"a\"].max"), .expected = .{ .str = "TypeError: max can't compare Number with String" } },
        .{ .src = rescued("[nil].min"), .expected = .{ .str = "TypeError: min needs Numbers or Strings, got nil at index 0" } },
        // A String first let anything but a Number through, and the VM read it as a String
        .{ .src = rescued("[\"a\", nil].min"), .expected = .{ .str = "TypeError: min needs Numbers or Strings, got nil at index 1" } },
        .{ .src = rescued("[\"a\", :b, \"c\"].max"), .expected = .{ .str = "TypeError: max needs Numbers or Strings, got Symbol at index 1" } },
        .{ .src = rescued("[1, nil].max"), .expected = .{ .str = "TypeError: max needs Numbers or Strings, got nil at index 1" } },
        .{ .src = rescued("[1, nil].sum"), .expected = .{ .str = "TypeError: sum needs Numbers, got nil at index 1" } },
        .{ .src = rescued("[1, Number::NAN].max"), .expected = .{ .str = "MathError: max: the Array holds NaN at index 1" } },
        .{ .src = rescued("[1e308, 1e308].sum"), .expected = .{ .str = "RangeError: sum overflowed the Number range" } },
        .{ .src = "r = [Number::INFINITY, 1].sum", .expected = .{ .num = std.math.inf(f64) } },
    });
}

test "Language: dup and clone copy Arrays, Maps and instances; Map#delete keeps the order" {
    // dup returned the receiver itself, so pushing to the copy changed the original; delete
    // swapped the last entry into the hole.
    try expectScripts(&.{
        .{ .src = "a = [1, 2]\nb = a.dup\nb.push(3)\nr = [a.length, b.length]", .expected = .{ .nums = &.{ 2, 3 } } },
        .{ .src = "m = { x: 1 }\nn = m.clone\nn[:y] = 2\nr = [m.keys.length, n.keys.length, n[:x]]", .expected = .{ .nums = &.{ 1, 2, 1 } } },
        .{ .src = "class P\n  attr_accessor :v\n  def initialize(v)\n    @v = v\n  end\nend\na = P.new(1)\nb = a.dup\nb.v = 5\nr = [a.v, b.v]", .expected = .{ .nums = &.{ 1, 5 } } },
        // Shallow: the copy holds the same inner Array.
        .{ .src = "a = [[1]]\nb = a.dup\nb[0].push(2)\nr = a[0].length", .expected = .{ .num = 2 } },
        .{ .src = "r = \"#{5.dup} #{\"s\".clone} #{nil.dup.nil?}\"", .expected = .{ .str = "5 s true" } },
        .{ .src = "m = { a: 1, b: 2, c: 3, d: 4 }\nr = [m.delete(:b), m.keys.length]", .expected = .{ .nums = &.{ 2, 3 } } },
        .{ .src = "m = { a: 1, b: 2, c: 3, d: 4 }\nm.delete(:a)\nr = \"#{m.keys}\"", .expected = .{ .str = "[:b, :c, :d]" } },
        .{ .src = "m = { a: 1 }\nr = m.delete(:zz).nil?", .expected = .{ .boolean = true } },
    });
}

test "Language: defined?(@x) is about this instance" {
    // It consulted the class's field layout, which another instance's assignment fills,
    // and read self from the block's own frame.
    try expectScripts(&.{
        .{ .src = "class P\n  def set\n    @x = 1\n  end\n  def has\n    defined?(@x) != nil\n  end\nend\na = P.new\nb = P.new\na.set\nr = \"#{a.has} #{b.has}\"", .expected = .{ .str = "true false" } },
        .{ .src = "class P\n  def set\n    @x = 1\n  end\n  def has\n    [1].map { defined?(@x) != nil }.first\n  end\nend\na = P.new\nb = P.new\na.set\nr = \"#{a.has} #{b.has}\"", .expected = .{ .str = "true false" } },
    });
}

test "Language: == compares Arrays, Maps and Ranges by content" {
    // They compared by identity, so [1] == [1] was false, as was [[1, 2]].contains?([1, 2]).
    try expectScripts(&.{
        .{ .src = "r = \"#{[1, [2, 3]] == [1, [2, 3]]} #{[1] == [1, 2]} #{[1, 2] != [1, 2]} #{[] == []}\"", .expected = .{ .str = "true false false true" } },
        .{ .src = "r = \"#{{ a: 1, b: [2] } == { b: [2], a: 1 }} #{{ a: 1 } == { a: 2 }} #{{ a: 1 } == { a: 1, b: 2 }}\"", .expected = .{ .str = "true false false" } },
        .{ .src = "r = \"#{(1..3) == (1..3)} #{(1..3) == (1...3)} #{[1, 2].contains?(2)} #{[[1, 2]].contains?([1, 2])}\"", .expected = .{ .str = "true false true true" } },
        .{ .src = "r = case [1, 2]\nwhen [1] then \"one\"\nwhen [1, 2] then \"two\"\nelse \"none\"\nend", .expected = .{ .str = "two" } },
        // A literal case table (op_switch) took NaN, neither below nor above a case, for
        // the case it was compared with
        .{ .src = "r = case Number::NAN\nwhen 1 then \"one\"\nwhen 2 then \"two\"\nwhen 3 then \"three\"\nelse \"none\"\nend", .expected = .{ .str = "none" } },
        .{ .src = "r = case 2.0\nwhen 1 then \"one\"\nwhen 2 then \"two\"\nelse \"none\"\nend", .expected = .{ .str = "two" } },
        // A structure containing itself: equal to itself, not to another such structure.
        .{ .src = "a = []\na.push(a)\nb = []\nb.push(b)\nr = \"#{a == a} #{a == b}\"", .expected = .{ .str = "true false" } },
        .{ .src = "r = \"#{[1] == 1} #{\"a\" == [\"a\"]}\"", .expected = .{ .str = "false false" } },
    });
}

test "Language: puts and interpolation show an instance by its own to_s" {
    // The method was ignored: the instance showed as "#<P>" in both.
    try expectScripts(&.{
        .{ .src = TO_S_CLASS ++ "r = \"#{P.new(1)} and #{P.new(2)}\"", .expected = .{ .str = "P(1) and P(2)" } },
        .{ .src = TO_S_CLASS ++ "r = \"#{P.new(1)}\"", .expected = .{ .str = "P(1)" }, .gc_stress = true },
        .{ .src = rescued("class Q\n  def to_s\n    5\n  end\nend\n\"#{Q.new}\""), .expected = .{ .str = "TypeError: Q#to_s must return a String, got Number" } },
        .{ .src = rescued("class Q\n  def to_s\n    raise \"boom\"\n  end\nend\n\"#{Q.new}\""), .expected = .{ .str = "RuntimeError: boom" } },
        .{ .src = "class Q\nend\nr = \"#{Q.new}\".length > 0", .expected = .{ .boolean = true } },
    });

    var vm = try support.initVm();
    defer vm.deinit();
    captured_output.clearRetainingCapacity();
    defer captured_output.clearAndFree(testing.allocator);
    vm.host.print_handler = capturePrint;
    try testing.expectEqual(.ok, try support.runOn(&vm, TO_S_CLASS ++ "puts P.new(3)\nprint P.new(4)"));
    try testing.expectEqualStrings("P(3)\nP(4)", captured_output.items);
}

test "Language: inspect shows an instance by its inspect, inherited too, or else its to_s" {
    // inspect() looked in the instance's own class only, called only built-in methods and
    // swallowed their errors: a script's inspect or to_s was never shown
    const classes = "class A\n  def inspect\n    \"A!\"\n  end\nend\nclass B < A\nend\nclass C\n  def to_s\n    \"C()\"\n  end\nend\nclass D\nend\n";
    var vm = try support.initVm();
    defer vm.deinit();
    captured_output.clearRetainingCapacity();
    defer captured_output.clearAndFree(testing.allocator);
    vm.host.print_handler = capturePrint;
    try testing.expectEqual(.ok, try support.runOn(&vm, classes ++ "inspect(A.new)\ninspect(B.new)\ninspect(C.new)\ninspect(D.new)\ninspect(cube(1).bbox)\ninspect(\"s\")"));
    var shown: std.ArrayList([]const u8) = .empty;
    defer shown.deinit(testing.allocator);
    var lines = std.mem.tokenizeScalar(u8, captured_output.items, '\n');
    // Each line after its "[line, col] " prefix, when the run has a line index
    while (lines.next()) |line| try shown.append(testing.allocator, if (std.mem.find(u8, line, "] ")) |at| line[at + 2 ..] else line);
    const expected = [_][]const u8{ "A!", "A!", "C()", "#<D>", "BoundingBox(min: [0, 0, 0], max: [1, 1, 1])", "\"s\"" };
    try testing.expectEqual(expected.len, shown.items.len);
    for (expected, shown.items) |want, got| try testing.expectEqualStrings(want, got);

    // An error in the method is the script's (a host that prints nothing runs none of it)
    const failing = [_]struct { src: []const u8, expected: []const u8 }{
        .{ .src = rescued("class Q\n  def inspect\n    5\n  end\nend\ninspect(Q.new)"), .expected = "TypeError: Q#inspect must return a String, got Number" },
        .{ .src = rescued("class Q\n  def inspect\n    raise \"boom\"\n  end\nend\ninspect(Q.new)"), .expected = "RuntimeError: boom" },
    };
    for (failing) |case| {
        var printing = try support.initVm();
        defer printing.deinit();
        printing.host.print_handler = capturePrint;
        try testing.expectEqual(.ok, try support.runOn(&printing, case.src));
        try testing.expectEqualStrings(case.expected, printing.globals.get("r").?.asString().chars);
    }
}

test "Language: a rescue modifier covers its whole statement, a call's arguments and all" {
    // `r.push raise("boom") rescue r.push(:rescued)` read as r.push(raise("boom") rescue
    // r.push(:rescued)): r pushed twice, the rescue's value pushed too
    try expectScripts(&.{
        .{ .src = "r = []\nr.push raise(\"boom\") rescue r.push(:rescued)\nr = r.length", .expected = .{ .num = 1 } },
        .{ .src = "def f(x)\n  raise \"boom\"\nend\nr = f 1 rescue 7", .expected = .{ .num = 7 } },
        // Within brackets, it is the bracketed expression's again
        .{ .src = "r = []\nr.push (raise(\"boom\") rescue 3)\nr = r", .expected = .{ .nums = &.{3} } },
        .{ .src = "r = [1, (raise(\"x\") rescue 2)]", .expected = .{ .nums = &.{ 1, 2 } } },
    });
}

test "Language: a class, rescue, range or module used wrongly says how" {
    try expectScripts(&.{
        .{ .src = rescued("class A\nend\nA.new(1)"), .expected = .{ .str = "ArgumentError: Expected 0 args for default constructor." } },
        .{ .src = rescued("class B\n  def initialize\n    super\n  end\nend\nB.new"), .expected = .{ .str = "NoMethodError: Superclass method 'initialize' not found." } },
        .{ .src = rescued("class C\n  def f\n    super\n  end\nend\nC.new.f"), .expected = .{ .str = "NoMethodError: Superclass method 'f' not found." } },
        .{ .src = rescued("x = 5\nbegin\n  raise \"boom\"\nrescue x => e\n  2\nend"), .expected = .{ .str = "TypeError: Rescue type must be a Class." } },
        .{ .src = rescued("(\"ab\"..\"c\").to_a"), .expected = .{ .str = "TypeError: a String range needs single characters, got \"ab\"..\"c\"" } },
        .{ .src = rescued("module M\nend\nM::Nope"), .expected = .{ .str = "NameError: module M has no member 'Nope' (it has none)" } },
    });
}

var captured_output: std.ArrayList(u8) = .empty;

fn capturePrint(vm: *@import("vm.zig").VM, message: []const u8) void {
    _ = vm;
    captured_output.appendSlice(testing.allocator, message) catch @panic("out of memory capturing output");
}

test "Language: rescue names a class by its scoped path, or lexically inside its module" {
    // `rescue Parts::MyError` was a syntax error, and `rescue MyError` inside module Parts
    // looked the name up as a bare global, which a class defined in a module doesn't get.
    const parts = "module Parts\n  class MyError < StandardError\n  end\n  def self.attempt\n    begin\n      raise MyError, \"inner\"\n    rescue MyError => e\n      e.message\n    end\n  end\nend\n";
    try expectScripts(&.{
        .{ .src = parts ++ "r = begin\n  raise Parts::MyError, \"x\"\nrescue Parts::MyError => e\n  e.message\nend", .expected = .{ .str = "x" } },
        .{ .src = parts ++ "r = Parts.attempt", .expected = .{ .str = "inner" } },
        .{ .src = parts ++ "r = begin\n  raise \"other\"\nrescue Parts::MyError => e\n  \"wrong\"\nrescue => e\n  e.message\nend", .expected = .{ .str = "other" } },
    });
}

test "Language: exporting an empty Solid is a GeometryError" {
    try expectScripts(&.{
        .{ .src = rescued("cube(1).difference(cube(2)).export_stl(\"never-written.stl\")"), .expected = .{ .str = "GeometryError: export_stl: the model is empty, there is nothing to write to 'never-written.stl'" } },
    });
}

test "Language: ||= and &&= assign only when the current value decides nothing" {
    // Both reached the emitter as operators it had no opcode for: "internal compiler error".
    try expectScripts(&.{
        .{ .src = "x = nil\nx ||= 5\ny = 3\ny ||= 9\nr = [x, y]", .expected = .{ .nums = &.{ 5, 3 } } },
        .{ .src = "z = 1\nz &&= 7\nw = nil\nw &&= 7\nr = \"#{z} #{w.nil?}\"", .expected = .{ .str = "7 true" } },
        .{ .src = "n = 0\nx = false\nx ||= (n += 1)\nx ||= (n += 1)\nr = n", .expected = .{ .num = 1 } },
        .{ .src = "class P\n  def v\n    @v ||= 4\n  end\nend\ninst = P.new\ninst.v\nr = inst.v", .expected = .{ .num = 4 } },
        .{ .src = "a = [nil, 2]\na[0] ||= 8\na[1] ||= 9\nr = a", .expected = .{ .nums = &.{ 8, 2 } } },
        .{ .src = "m = {}\nm[:k] ||= 1\nm[:k] ||= 2\nr = m[:k]", .expected = .{ .num = 1 } },
        .{ .src = "class Q\n  attr_accessor :p\nend\nq = Q.new\nq.p ||= 6\nq.p ||= 7\nr = q.p", .expected = .{ .num = 6 } },
    });
}

test "Language: an unset instance variable is nil, even where a method has its name" {
    // `@v` read through op_get_property, whose method fallback handed back the method `v`
    // itself, so `@v ||= 4` kept the method and `@v` inside `def v` was never nil.
    try expectScripts(&.{
        .{ .src = "class P\n  def v\n    @v\n  end\nend\nr = P.new.v.nil?", .expected = .{ .boolean = true } },
        .{ .src = "class P\n  def v\n    @v += 1\n  end\n  def initialize\n    @v = 1\n  end\nend\nr = P.new.v", .expected = .{ .num = 2 } },
    });
}

test "Language: include and inheritance mistakes are TypeErrors, not silent stops" {
    // `include M` in a module body and `class A < X` with a non-class X stopped the run
    // with no message and nothing to rescue.
    try expectScripts(&.{
        .{ .src = rescued("module M\nend\nmodule N\n  include M\nend"), .expected = .{ .str = "TypeError: include can't add a module to another module; include it in each class that needs it" } },
        .{ .src = rescued("class A\n  include 5\nend"), .expected = .{ .str = "TypeError: include needs a Module, got Number" } },
        .{ .src = rescued("X = 5\nclass A < X\nend"), .expected = .{ .str = "TypeError: a superclass must be a Class, got Number" } },
        .{ .src = rescued("S = \"s\"\nclass B < S\nend"), .expected = .{ .str = "TypeError: a superclass must be a Class, got String" } },
    });
}

test "Language: on_face and Workplane are withheld until the sketching API exists" {
    // on_face returned a Workplane with no methods: an API that led nowhere.
    try expectScripts(&.{
        .{ .src = rescued("cube(1).on_face(:top) { }"), .expected = .{ .str = "NoMethodError: undefined method 'on_face' for Solid" } },
        .{ .src = "r = defined?(Workplane).nil?", .expected = .{ .boolean = true } },
    });
}

test "Language: a heredoc's opener line goes on as code, and <<~ strips the indentation" {
    // The rest of the opener's line was dropped (`<<~EOS.upcase` lost its call without a
    // word), and `<<~` kept the indentation, as `<<-` does.
    try expectScripts(&.{
        .{ .src = "r = <<~EOS.upcase\n    ab\n      c\n  EOS", .expected = .{ .str = "AB\n  C\n" } },
        .{ .src = "def f(a, b) = a + b\nr = f(<<~A, <<-B)\n  one\nA\n  two\n  B", .expected = .{ .str = "one\n  two\n" } },
        .{ .src = "r = <<EOS.length + 1\n\tx\\ty\nEOS", .expected = .{ .num = 6 } },
        .{ .src = "r = <<~EOS\n  a\n\n  b\nEOS", .expected = .{ .str = "a\n\nb\n" } },
    });
}

test "Language: a recursion through built-ins stops at the nested-run limit, not the native stack" {
    // A block `map` calls and a raised class's `initialize` run nested on the native
    // stack: recursing through them crashed the process before the frame limit. They stop
    // with the call stack overflow error now; nesting below the limit runs as before.
    const overflowing = [_][]const u8{
        "def f(n) = n == 0 ? 0 : [1].map { |x| f(n - 1) + x }[0]\nf(5000)",
        "class Loop < RuntimeError\n  def initialize\n    raise Loop\n  end\nend\nraise Loop",
        // It ends the run, as the frame limit does: a rescue doesn't catch it.
        "def f(n) = n == 0 ? 0 : [1].map { |x| f(n - 1) + x }[0]\nbegin\n  f(5000)\nrescue => e\n  0\nend",
    };
    for (overflowing) |src| {
        errdefer std.debug.print("script:\n{s}\n", .{src});
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(@import("vm.zig").InterpretResult.runtime_error, try support.runOn(&vm, src));
        try testing.expect(std.mem.find(u8, vm.last_error.?, "Call stack overflow") != null);
    }
    try expectScripts(&.{
        .{ .src = "def f(n) = n == 0 ? 0 : [1].map { |x| f(n - 1) + x }[0]\nr = f(150)", .expected = .{ .num = 150 } },
    });
}

test "Language: next and break in an ensure body leave the loop as in Ruby" {
    // They were refused as an internal compiler error: an ensure body runs with the begin's
    // value, or its exception, on the stack, and the jump didn't drop it (found by the
    // generated-program fuzz test). `break` there also drops the exception being raised.
    try expectScripts(&.{
        .{ .src = "r = []\nfor v in [1, 2, 3]\n  begin\n    r.push(v)\n  ensure\n    next if v == 1\n    r.push(-v)\n  end\nend", .expected = .{ .nums = &.{ 1, 2, -2, 3, -3 } } },
        .{ .src = "n = 0\nwhile true\n  n += 1\n  begin\n    raise(\"boom\") if n == 2\n  ensure\n    break if n == 2\n  end\nend\nr = n", .expected = .{ .num = 2 } },
        .{ .src = "r = 0\nwhile r < 3\n  r += 1\n  begin\n    x = r * 2\n  ensure\n    next\n  end\nend", .expected = .{ .num = 3 } },
    });
}

test "Language: a map key that is a name or a method call is its value" {
    // A name before `=>` was read as a call without parentheses, `k(=> 1)`, a syntax error
    try expectScripts(&.{
        .{ .src = "k = 2\nm = { k => 1 }\nr = m[2]", .expected = .{ .num = 1 } },
        .{ .src = "class P\n  def k = 3\nend\np = P.new\nm = { p.k => 1 }\nr = m[3]", .expected = .{ .num = 1 } },
        // `key: value` after an expression is the same key as `key => value`
        .{ .src = "class P\n  def k = 3\nend\np = P.new\nr = { p.k: 1 } == { p.k => 1 }", .expected = .{ .boolean = true } },
        // A name before `=>` is its value; before `:` it is a label, the Symbol
        .{ .src = "k = 2\nr = [{ k => 1 }.keys[0], { k: 1 }.keys[0], { k : 1 }.keys[0]].inspect", .expected = .{ .str = "[2, :k, :k]" } },
        // With a `**` splat the map is built entry by entry, the same way
        .{ .src = "k = 2\nm = { k => 1, **{ j: 3 } }\nr = [m[2], m[:j]]", .expected = .{ .nums = &.{ 1, 3 } } },
    });
}

test "Language: a lone target with a comma takes the first element, a lone splat all of them" {
    try expectScripts(&.{
        .{ .src = "a, = [1, 2, 3]\nr = a", .expected = .{ .num = 1 } },
        .{ .src = "*m, = [1, 2, 3]\nr = m", .expected = .{ .nums = &.{ 1, 2, 3 } } },
        .{ .src = "a, *rest = 1, 2, 3\nr = rest", .expected = .{ .nums = &.{ 2, 3 } } },
    });
}

test "Language: a quoted symbol is read as the string in the same quotes" {
    // Its name was its text as written: `:"a\tb"` kept the backslash and `:"p_#{i}"` its
    // `#{i}`, as Ruby doesn't
    try expectScripts(&.{
        .{ .src = "r = :\"a\\\"b\\tc\" == \"a\\\"b\\tc\".to_sym", .expected = .{ .boolean = true } },
        .{ .src = "r = :\"\\u00e9 \\#{x}\".to_s", .expected = .{ .str = "\u{e9} #{x}" } },
        .{ .src = "r = :'a\\'b \\n'.to_s", .expected = .{ .str = "a'b \\n" } },
        .{ .src = "r = :\"x\" == :x", .expected = .{ .boolean = true } },
        .{ .src = "i = 2\nr = :\"part_#{i}\" == :part_2", .expected = .{ .boolean = true } },
        .{ .src = "i = 2\nr = :\"part_#{i}\" == :part_2", .expected = .{ .boolean = true }, .gc_stress = true },
        .{ .src = "r = \"#{:\"#{1}#{\"a\"}\".class} #{:\"#{1}#{\"a\"}\"}\"", .expected = .{ .str = "Symbol 1a" } },
        .{ .src = "k = \"b\"\nr = { :\"a #{k}\" => 1 }[:\"a b\"]", .expected = .{ .num = 1 } },
    });
}
