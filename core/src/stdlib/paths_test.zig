//! Paths: `line`, `polyline` and `arc`, joined by `+`, moved, closed or stroked into a
//! Sketch, labelled and measured.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

const BRACKET = "a = line([0, 0], [10, 0])\nb = arc(center: [10, 5], r: 5, start: -90, sweep: 180)\nc = polyline([[10, 10], [0, 10]])\np = a + b + c\n";

test "paths: a line, an arc and a polyline join where one ends and the next starts" {
    try expectScripts(&.{
        .{ .src = BRACKET ++ "r = p.start + p.end", .expected = .{ .nums = &.{ 0, 0, 0, 10 } } },
        .{ .src = BRACKET ++ "r = p.length", .expected = .{ .num = 10 + 5 * std.math.pi + 10 } },
        .{ .src = BRACKET ++ "r = \"#{p.class} #{p.inspect}\"", .expected = .{ .str = "Path <Path 3 segments from [0, 0] to [0, 10]>" } },
        .{ .src = "r = line([0, 0], [3, 4]).length", .expected = .{ .num = 5 } },
        // The short arc of radius 5 over a chord of 10 is a half circle; the long way is the other half
        .{ .src = "r = arc(r: 5, start: [0, 0], to: [10, 0]).length", .expected = .{ .num = 5 * std.math.pi } },
        .{ .src = "r = arc(r: 5, start: [0, 0], to: [8, 0]).end", .expected = .{ .nums = &.{ 8, 0 } } },
        .{ .src = "r = arc(r: 5, start: [0, 0], to: [8, 0], large: true).length > arc(r: 5, start: [0, 0], to: [8, 0]).length", .expected = .{ .boolean = true } },
        // Clockwise when end is before start
        .{ .src = "r = arc(center: [0, 0], r: 1, start: 90, sweep: -90).start + arc(center: [0, 0], r: 1, start: 90, sweep: -90).end", .expected = .{ .nums = &.{ 6.123233995736766e-17, 1, 1, 0 } } },
    });
}

test "paths: what can't be a path is an error saying why" {
    try expectScripts(&.{
        .{ .src = rescued("line([0, 0], [0, 0])"), .expected = .{ .str = "ValueError: line expects two different points, got [0, 0] twice" } },
        .{ .src = rescued("polyline([[0, 0]])"), .expected = .{ .str = "ValueError: polyline needs at least 2 points, got 1" } },
        .{ .src = rescued("arc(r: 2, start: [0, 0], to: [10, 0])"), .expected = .{ .str = "ValueError: arc of radius 2 can't reach from [0, 0] to [10, 0]: the points are 10 apart, more than twice the radius, or the same point" } },
        .{ .src = rescued("arc(center: [0, 0], r: 1, start: 0, sweep: 0)"), .expected = .{ .str = "ValueError: arc expects a sweep other than 0" } },
        .{ .src = rescued("arc(center: [0, 0], r: 1, start: 0, sweep: 90, to: [0, 0])"), .expected = .{ .str = "ArgumentError: arc takes center: with start: and sweep:, or start: and to:, not both" } },
        .{ .src = rescued("arc(r: 1)"), .expected = .{ .str = "ArgumentError: arc needs start:, an angle in degrees with center: and sweep:, or a point with to:" } },
        .{ .src = rescued("arc(r: 1, start: [0, 0])"), .expected = .{ .str = "ArgumentError: arc needs center: with start: and sweep:, or start: and to:" } },
        .{ .src = rescued("line([0, 0], [1, 0]) + line([5, 5], [6, 5])"), .expected = .{ .str = "ValueError: '+' joins paths where one ends and the next starts: the first ends at [1, 0], the second starts at [5, 5]" } },
        .{ .src = rescued("arc(center: [0, 0], r: 1, start: 0, sweep: 90).scale(2, 1)"), .expected = .{ .str = "ValueError: scale can't scale a Path's arcs unevenly (an arc stays an arc): scale it the same in x and y, or close or stroke it first" } },
        .{ .src = rescued("line([0, 0], [1, 0]).close"), .expected = .{ .str = "ValueError: close needs a Path of at least 2 segments to enclose anything, got 1" } },
        .{ .src = rescued("line([0, 0], [1, 0]).extrude(1)"), .expected = .{ .str = "NoMethodError: undefined method 'extrude' for Path: a Path is open and encloses nothing: close it (.close) into a Sketch or give it a width (.stroke(w)) first" } },
        .{ .src = rescued("line([0, 0], [1, 0]).volume"), .expected = .{ .str = "NoMethodError: undefined method 'volume' for Path" } },
        .{ .src = rescued("line([0, 0], [1, 0]) - line([1, 0], [2, 0])"), .expected = .{ .str = "TypeError: '-' can't combine Path and Path" } },
    });
}

test "paths: moves keep the arcs, a close encloses, a stroke gives a width" {
    try expectScripts(&.{
        .{ .src = BRACKET ++ "r = p.translate(x: 1, y: 2).start + p.rotate(90).end", .expected = .{ .nums = &.{ 1, 2, -10, 0 } } },
        .{ .src = BRACKET ++ "r = p.mirror(1, 0).end", .expected = .{ .nums = &.{ 0, 10 } } },
        .{ .src = BRACKET ++ "r = p.scale(2).length", .expected = .{ .num = 2 * (20 + 5 * std.math.pi) } },
        // The rectangle 10 by 10 with a half disc of radius 5 on its right, the disc drawn
        // with the resolution's chords (a little under the exact 12.5π)
        .{ .src = BRACKET ++ "v = p.close.extrude(1).volume\nr = v > 138 && v < 100 + 12.5 * Math::PI", .expected = .{ .boolean = true } },
        .{ .src = BRACKET ++ "r = \"#{p.close.class} #{p.stroke(2).class}\"", .expected = .{ .str = "CrossSection CrossSection" } },
        // A straight stroke of 10 by 2 with round caps, butt ends, or square ends
        .{ .src = "r = line([0, 0], [10, 0]).stroke(2, cap: :butt).extrude(1).volume", .expected = .{ .num = 20 } },
        .{ .src = "r = line([0, 0], [10, 0]).stroke(2, cap: :square).extrude(1).volume", .expected = .{ .num = 24 } },
        .{ .src = "v = line([0, 0], [10, 0]).stroke(2, segments: 64).extrude(1).volume\nr = v > 23 && v < 20 + Math::PI", .expected = .{ .boolean = true } },
        .{ .src = rescued("line([0, 0], [10, 0]).stroke(2, cap: :fancy)"), .expected = .{ .str = "ValueError: stroke cap must be round, butt or square, got 'fancy'" } },
        // A label stays through moves and a join
        .{ .src = "p = line([0, 0], [1, 0]).named(\"edge\").material(color: \"#00FF00\")\nr = \"#{p.translate(x: 1).inspect}\"", .expected = .{ .str = "<Path 1 segment from [1, 0] to [2, 0]>" } },
    });
}
