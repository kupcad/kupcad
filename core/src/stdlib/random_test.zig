//! Random (classes/random.zig): a seed's numbers, the same every run and pinned here, since
//! a model made with them must stay that model; each form of `rand`, `shuffle` and
//! `sample`, and what a wrong seed or limit is told.

const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

test "Random: a seed gives the same numbers every run, SplitMix64's" {
    try expectScripts(&.{
        // SplitMix64 from 42, its top 53 bits a float: change the generator and every
        // model made with one changes
        .{ .src = "g = Random.new(42)\nr = [g.rand, g.rand]", .expected = .{ .nums = &.{ 0.7415648787718233, 0.1599103928769201 } } },
        .{ .src = "a = Random.new(9)\nb = Random.new(9)\nr = (0...20).map { a.rand(1000) } == (0...20).map { b.rand(1000) }", .expected = .{ .boolean = true } },
        .{ .src = "r = Random.new(1).rand == Random.new(2).rand", .expected = .{ .boolean = false } },
        .{ .src = "r = [Random.new(-3).seed, Random.new(1).inspect, \"#{Random.new(1).class}\"].inspect", .expected = .{ .str = "[-3, \"#<Random seed: 1>\", \"Random\"]" } },
    });
}

test "Random: rand of nothing, a Number or a Range, whole numbers for whole limits" {
    try expectScripts(&.{
        .{ .src = "g = Random.new(5)\nr = (0...200).map { g.rand }.all? { |x| x >= 0 && x < 1 }", .expected = .{ .boolean = true } },
        .{ .src = "g = Random.new(5)\nr = (0...200).map { g.rand(6) }.uniq.sort", .expected = .{ .nums = &.{ 0, 1, 2, 3, 4, 5 } } },
        .{ .src = "g = Random.new(5)\nr = (0...200).map { g.rand(1..3) }.uniq.sort", .expected = .{ .nums = &.{ 1, 2, 3 } } },
        .{ .src = "g = Random.new(5)\nr = (0...200).map { g.rand(1...3) }.uniq.sort", .expected = .{ .nums = &.{ 1, 2 } } },
        .{ .src = "g = Random.new(5)\nr = (0...200).map { g.rand(2.5) }.all? { |x| x >= 0 && x < 2.5 && !x.integer? || x == 0 }", .expected = .{ .boolean = true } },
        .{ .src = "g = Random.new(5)\nr = (0...200).map { g.rand(0.5..1.5) }.all? { |x| x >= 0.5 && x < 1.5 }", .expected = .{ .boolean = true } },
        // Each of n values about as often as the others
        .{ .src = "g = Random.new(123)\nc = [0, 0, 0]\n3000.times { c[g.rand(3)] += 1 }\nr = c.all? { |n| n > 900 && n < 1100 }", .expected = .{ .boolean = true } },
    });
}

test "Random: shuffle and sample draw from an Array, leaving it as it was" {
    try expectScripts(&.{
        .{ .src = "a = [1, 2, 3, 4, 5]\ns = Random.new(7).shuffle(a)\nr = [a == [1, 2, 3, 4, 5], s.sort == a, s != a].inspect", .expected = .{ .str = "[true, true, true]" }, .gc_stress = true },
        .{ .src = "r = Random.new(7).shuffle([1, 2, 3, 4, 5])", .expected = .{ .nums = &.{ 5, 2, 4, 1, 3 } } },
        .{ .src = "g = Random.new(3)\nr = (0...100).map { g.sample([:a, :b, :c]) }.uniq.size", .expected = .{ .num = 3 } },
        .{ .src = "r = Random.new(1).sample([])", .expected = .nil },
    });
}

test "Random: a seed is required and whole, a limit positive and a Range not empty" {
    try expectScripts(&.{
        .{ .src = comptime rescued("Random.new"), .expected = .{ .str = "ArgumentError: Random.new takes a seed, a whole number: the same seed gives the same numbers every run" } },
        .{ .src = comptime rescued("Random.new(1.5)"), .expected = .{ .str = "ArgumentError: Random.new: the seed is a whole number up to 2^53, got 1.5" } },
        .{ .src = comptime rescued("Random.new(1).rand(0)"), .expected = .{ .str = "ArgumentError: rand: the limit is a number greater than 0, got 0" } },
        .{ .src = comptime rescued("Random.new(1).rand(5..1)"), .expected = .{ .str = "ArgumentError: rand: the Range 5..1 is empty" } },
        .{ .src = comptime rescued("Random.new(1).rand(3...3)"), .expected = .{ .str = "ArgumentError: rand: the Range 3...3 is empty" } },
        .{ .src = comptime rescued("Random.new(1).rand((0..1).step(0.5))"), .expected = .{ .str = "ArgumentError: rand: the Range has a step of 0.5; give it one without" } },
        .{ .src = comptime rescued("Random.new(1).rand(\"x\")"), .expected = .{ .str = "TypeError: rand takes nothing, a Number or a Range, got String" } },
        .{ .src = comptime rescued("Random.new(1).shuffle(5)"), .expected = .{ .str = "TypeError: Random#shuffle expects an Array for argument 1, got Number" } },
    });
}
