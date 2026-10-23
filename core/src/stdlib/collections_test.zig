//! The collection methods taken from Ruby's Enumerable that Arrays, Maps and Strings
//! answer (each_cons, sort_by, group_by, fetch, dig, rjust, ...), with what a script that
//! uses them wrong is told.

const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

test "Array: each_with_index, each_cons and each_slice give each item with its index, or windows" {
    try expectScripts(&.{
        .{ .src = "s = []\n[5, 6].each_with_index { |x, i| s.push(x * 10 + i) }\nr = s", .expected = .{ .nums = &.{ 50, 61 } } },
        // Without a block, an Array: there is no Enumerator
        .{ .src = "r = [5, 6].each_with_index.inspect", .expected = .{ .str = "[[5, 0], [6, 1]]" }, .gc_stress = true },
        .{ .src = "r = [1, 2, 3].each_cons(2).inspect", .expected = .{ .str = "[[1, 2], [2, 3]]" }, .gc_stress = true },
        // The window is one argument, taken apart with |(a, b)|
        .{ .src = "s = []\n[1, 2, 4, 7].each_cons(2) { |(a, b)| s.push(b - a) }\nr = s", .expected = .{ .nums = &.{ 1, 2, 3 } }, .gc_stress = true },
        .{ .src = "r = [1, 2, 3, 4, 5].each_slice(2).inspect", .expected = .{ .str = "[[1, 2], [3, 4], [5]]" }, .gc_stress = true },
        .{ .src = "r = [1, 2].each_cons(3).inspect", .expected = .{ .str = "[]" } },
        .{ .src = "r = [1, 2].each_slice(1e300).inspect", .expected = .{ .str = "[[1, 2]]" } },
        .{ .src = "r = [1, 2, 3].each_cons(2) { |w| break w }", .expected = .{ .nums = &.{ 1, 2 } } },
        .{ .src = "r = [1, 2].each_slice(1) { |w| w }", .expected = .{ .nums = &.{ 1, 2 } } },
        .{ .src = comptime rescued("[1].each_cons(0)"), .expected = .{ .str = "ArgumentError: each_cons: the size is a whole number of 1 or more, got 0" } },
        .{ .src = comptime rescued("[1].each_slice(1.5)"), .expected = .{ .str = "ArgumentError: each_slice: the size is a whole number of 1 or more, got 1.5" } },
    });
}

test "Array: zip, uniq, reverse, take and drop make new Arrays" {
    try expectScripts(&.{
        .{ .src = "r = [1, 2, 3].zip([4, 5], [\"a\", \"b\", \"c\", \"d\"]).inspect", .expected = .{ .str = "[[1, 4, \"a\"], [2, 5, \"b\"], [3, nil, \"c\"]]" }, .gc_stress = true },
        .{ .src = comptime rescued("[1].zip(2)"), .expected = .{ .str = "TypeError: zip takes Arrays, got Number as argument 1" } },
        // Equal as == says: Arrays by content
        .{ .src = "r = [3, 1, 3, [1], [1], 2, 1].uniq.inspect", .expected = .{ .str = "[3, 1, [1], 2]" } },
        .{ .src = "r = [\"ab\", \"cd\", \"ae\"].uniq { |s| s[0] }.inspect", .expected = .{ .str = "[\"ab\", \"cd\"]" }, .gc_stress = true },
        .{ .src = "r = [[1, 2], [2, 1]].uniq { |(a, b)| [a + b] }.size", .expected = .{ .num = 1 }, .gc_stress = true },
        .{ .src = "a = [1, 2, 3]\nb = a.reverse\nr = a + b", .expected = .{ .nums = &.{ 1, 2, 3, 3, 2, 1 } } },
        .{ .src = "r = [1, 2, 3].take(2) + [1, 2, 3].take(9) + [1, 2, 3].drop(1) + [1, 2].drop(5)", .expected = .{ .nums = &.{ 1, 2, 1, 2, 3, 2, 3 } } },
        .{ .src = comptime rescued("[1].take(-1)"), .expected = .{ .str = "ArgumentError: take: the count is a whole number of 0 or more, got -1" } },
        .{ .src = comptime rescued("[1].drop(0.5)"), .expected = .{ .str = "ArgumentError: drop: the count is a whole number of 0 or more, got 0.5" } },
    });
}

test "Array: any?, all?, none?, find, include? and count ask about the items" {
    try expectScripts(&.{
        .{ .src = "r = [[nil, false].any?, [nil, 1].any?, [].all?, [1, nil].all?, [nil].none?, [].any?].inspect", .expected = .{ .str = "[false, true, true, false, true, false]" } },
        .{ .src = "r = [[1, 2].any? { |x| x > 1 }, [1, 2].all? { |x| x > 1 }, [1, 2].none? { |x| x > 2 }].inspect", .expected = .{ .str = "[true, false, true]" } },
        // They stop at the item that settles it
        .{ .src = "n = 0\n[1, 2, 3].any? { |x| n += 1\nx == 2 }\nr = n", .expected = .{ .num = 2 } },
        .{ .src = "r = [1, 2, 3, 4].find { |x| x.even? }", .expected = .{ .num = 2 } },
        .{ .src = "r = [1, 2].find { |x| x > 5 }", .expected = .nil },
        .{ .src = comptime rescued("[1].find"), .expected = .{ .str = "ArgumentError: Array#find requires a block" } },
        .{ .src = "r = [[1, 2].include?(2), [[1]].include?([1]), [1].include?(\"1\")].inspect", .expected = .{ .str = "[true, true, false]" } },
        .{ .src = "r = [[1, 2, 2].count, [1, 2, 2].count(2), [1, 2, 3].count { |x| x.odd? }, [[1]].count([1])]", .expected = .{ .nums = &.{ 3, 2, 2, 1 } } },
    });
}

test "Array: flat_map, sort_by, min_by, max_by and group_by call the block once per item" {
    try expectScripts(&.{
        .{ .src = "r = [1, 2].flat_map { |x| [x, x * 10] }", .expected = .{ .nums = &.{ 1, 10, 2, 20 } }, .gc_stress = true },
        // One level, as Ruby's
        .{ .src = "r = [1, 2].flat_map { |x| x == 1 ? [[x]] : x }.inspect", .expected = .{ .str = "[[1], 2]" }, .gc_stress = true },
        .{ .src = "r = [\"ccc\", \"a\", \"bb\"].sort_by { |s| s.size }.join(\",\")", .expected = .{ .str = "a,bb,ccc" } },
        // Items with equal keys keep their order
        .{ .src = "r = [[\"b\", 1], [\"a\", 1], [\"c\", 0]].sort_by { |(n, k)| k }.map { |(n, k)| n }.join(\"\")", .expected = .{ .str = "cba" } },
        .{ .src = "r = [\"b\", \"c\", \"a\"].sort_by { |s| s + \"!\" }.join(\"\")", .expected = .{ .str = "abc" }, .gc_stress = true },
        .{ .src = "n = 0\n[3, 1, 2].sort_by { |x| n += 1\nx }\nr = n", .expected = .{ .num = 3 } },
        .{ .src = "r = [[\"x\", 2], [\"y\", 1], [\"z\", 1]].min_by { |(n, k)| k }[0]", .expected = .{ .str = "y" } },
        .{ .src = "r = [\"a\", \"ccc\", \"bb\"].max_by { |s| s.size }", .expected = .{ .str = "ccc" } },
        .{ .src = "r = [].min_by { |x| x }", .expected = .nil },
        .{ .src = "r = [1, 2, 3, 4].group_by { |x| x.odd? ? :odd : :even }.inspect", .expected = .{ .str = "{odd: [1, 3], even: [2, 4]}" }, .gc_stress = true },
        .{ .src = "g = [\"ab\", \"ac\", \"b\"].group_by { |s| s[0] }\nr = g[\"a\"].size", .expected = .{ .num = 2 }, .gc_stress = true },
        .{ .src = "r = [1, 2].group_by { |x| break 7 }", .expected = .{ .num = 7 } },
        .{ .src = "r = [1, 2].sort_by { |x| break 8 }", .expected = .{ .num = 8 } },
        .{ .src = comptime rescued("[1, \"a\"].sort_by { |x| x }"), .expected = .{ .str = "TypeError: sort_by: the block gave Number and String, which can't be compared" } },
        .{ .src = comptime rescued("[1, 2].max_by { |x| nil }"), .expected = .{ .str = "TypeError: max_by: the block gives Numbers or Strings to compare, got nil for the item at index 0" } },
        .{ .src = comptime rescued("[1, 2].min_by { |x| x == 2 ? Number::NAN : x }"), .expected = .{ .str = "MathError: min_by: the block gave NaN for the item at index 1" } },
    });
}
