//! Paths: `line`, `polyline` and `arc`, joined by `+`, moved, closed or stroked into a
//! Sketch, labelled and measured.

const std = @import("std");
const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

const BRACKET = "a = line([0, 0], [10, 0])\nb = arc(center: [10, 5], r: 5, start: -90, sweep: 180)\nc = polyline([[10, 10], [0, 10]])\np = a + b + c\n";

test "paths: a line, an arc and a polyline join where one ends and the next starts" {
    try expectScripts(&.{
        .{ .src = BRACKET ++ "r = p.start + p.end", .expected = .{ .nums = &.{ 0, 0, 0, 10 } } },
        .{ .src = BRACKET ++ "r = p.length", .expected = .{ .num = 10 + 5 * std.math.pi + 10 } },
        .{ .src = BRACKET ++ "r = \"#{p.class} #{p.inspect}\"", .expected = .{ .str = "Path #<Path 3 segments from [0, 0] to [0, 10]>" } },
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
        // What each constructor needs, and where a Path can't go
        .{ .src = rescued("line([0, 0])"), .expected = .{ .str = "ArgumentError: line expects two points, [x, y] each, got 1 argument" } },
        .{ .src = rescued("polyline()"), .expected = .{ .str = "ArgumentError: polyline expects an Array of [x, y] points" } },
        .{ .src = rescued("polyline(5)"), .expected = .{ .str = "TypeError: polyline expects an Array for points, got Number" } },
        .{ .src = rescued("polyline([[0, 0], [0, 0], [1, 1]])"), .expected = .{ .str = "ValueError: polyline point 1 repeats the one before it, [0, 0]" } },
        .{ .src = rescued("arc()"), .expected = .{ .str = "ArgumentError: arc needs a radius (r:)" } },
        .{ .src = rescued("arc(5)"), .expected = .{ .str = "ArgumentError: arc takes no positional arguments, got 1" } },
        .{ .src = rescued("arc(center: [0, 0], r: 5, start: 0)"), .expected = .{ .str = "ArgumentError: arc with center: needs sweep: (degrees, counter-clockwise when positive)" } },
        .{ .src = rescued("arc(center: [0, 0], r: 5, start: 0, sweep: 400)"), .expected = .{ .str = "ValueError: arc sweeps at most a full turn, got 400 degrees" } },
        .{ .src = rescued("line([0, 0], [1, 0]).translate(0, 0, 1)"), .expected = .{ .str = "ValueError: a Path can only translate in x and y (it lies in the XY plane), got z 1" } },
        .{ .src = rescued("line([0, 0], [1, 0]).rotate(1, 0, 0)"), .expected = .{ .str = "ValueError: a Path can only rotate about z (it lies in the XY plane), got x 1 and y 0" } },
        .{ .src = rescued("line([0, 0], [1, 0]).mirror(0, 0, 1)"), .expected = .{ .str = "ValueError: a Path can only mirror across a line in the XY plane, got a normal with z 1" } },
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
        .{ .src = BRACKET ++ "r = \"#{p.close.class} #{p.stroke(2).class}\"", .expected = .{ .str = "Sketch Sketch" } },
        // A straight stroke of 10 by 2 with round caps, butt ends, or square ends
        .{ .src = "r = line([0, 0], [10, 0]).stroke(2, cap: :butt).extrude(1).volume", .expected = .{ .num = 20 } },
        .{ .src = "r = line([0, 0], [10, 0]).stroke(2, cap: :square).extrude(1).volume", .expected = .{ .num = 24 } },
        .{ .src = "v = line([0, 0], [10, 0]).stroke(2, segments: 64).extrude(1).volume\nr = v > 23 && v < 20 + Math::PI", .expected = .{ .boolean = true } },
        .{ .src = rescued("line([0, 0], [10, 0]).stroke(2, cap: :fancy)"), .expected = .{ .str = "ValueError: stroke cap must be round, butt or square, got 'fancy'" } },
        // A label stays through moves and a join
        .{ .src = "p = line([0, 0], [1, 0]).named(\"edge\").material(color: \"#00FF00\")\nr = \"#{p.translate(x: 1).inspect}\"", .expected = .{ .str = "#<Path 1 segment from [1, 0] to [2, 0]>" } },
    });
}

test "paths: line_to, arc_to and tangent_arc_to go on from the end, a tangent arc with no corner" {
    const SLOT = "p = line([0, 0], [10, 0]).line_to([10, 5]).tangent_arc_to([5, 10]).line_to([0, 10])\n";
    try expectScripts(&.{
        // 10 + 5 + a quarter of the circle of radius 5 + 5
        .{ .src = SLOT ++ "r = p.length", .expected = .{ .num = 20 + 5 * std.math.pi / 2.0 } },
        .{ .src = SLOT ++ "r = p.end", .expected = .{ .nums = &.{ 0, 10 } } },
        // Closed, the arc drawn in chords: just under the exact 50 + 25 + 25π/4
        .{ .src = SLOT ++ "v = p.close.extrude(1).volume\nr = v > 94 && v < 50 + 25 + 25 * Math::PI / 4", .expected = .{ .boolean = true } },
        .{ .src = "r = line([0, 0], [10, 0]).arc_to([10, 10], r: 5).length", .expected = .{ .num = 10 + 5 * std.math.pi } },
        .{ .src = "r = line([0, 0], [10, 0]).arc_to([10, 10], r: 5, ccw: false).end", .expected = .{ .nums = &.{ 10, 10 } } },
        // From an arc's end, along its tangent: the second arc's centre is (0, -7.5)
        .{ .src = "a = arc(center: [0, 0], r: 5, start: 0, sweep: 90).tangent_arc_to([-10, 0])\nr = (a.length - 5 * Math::PI / 2).round(9)", .expected = .{ .num = 11.591190225 } },
        // The name and material stay
        .{ .src = "r = line([0, 0], [1, 0]).named(\"rail\").line_to([1, 1]).close.bbox.size[0]", .expected = .{ .num = 1 } },
        .{ .src = comptime rescued("line([0, 0], [10, 0]).tangent_arc_to([20, 0])"), .expected = .{ .str = "ValueError: tangent_arc_to: [20, 0] is on the line the path leaves [10, 0] along, where no arc turns; line_to goes there" } },
        .{ .src = comptime rescued("line([0, 0], [10, 0]).line_to([10, 0])"), .expected = .{ .str = "ValueError: line_to: the path already ends at [10, 0]" } },
        .{ .src = comptime rescued("line([0, 0], [10, 0]).arc_to([100, 0], r: 5)"), .expected = .{ .str = "ValueError: arc_to of radius 5 can't reach from [10, 0] to [100, 0]: the points are 90 apart, more than twice the radius, or the same point" } },
        .{ .src = comptime rescued("line([0, 0], [10, 0]).arc_to([10, 5])"), .expected = .{ .str = "ArgumentError: arc_to needs a radius (r:)" } },
        .{ .src = comptime rescued("line([0, 0], [10, 0]).line_to(5)"), .expected = .{ .str = "TypeError: line_to expects an Array for point 0, got Number" } },
    });
}

test "paths: fillet and chamfer round or cut each corner where two lines meet" {
    const ELL = "p = polyline([[0, 0], [10, 0], [10, 10]])\n";
    try expectScripts(&.{
        // 7 along, a quarter of the circle of radius 3, 7 up
        .{ .src = ELL ++ "r = p.fillet(3).length", .expected = .{ .num = 14 + 1.5 * std.math.pi } },
        .{ .src = ELL ++ "r = p.fillet(r: 3).inspect", .expected = .{ .str = "#<Path 3 segments from [0, 0] to [10, 10]>" } },
        // 7 along, across a corner of 3 by 3, 7 up
        .{ .src = ELL ++ "r = p.chamfer(3).length", .expected = .{ .num = 14 + 3 * std.math.sqrt2 } },
        .{ .src = ELL ++ "r = p.chamfer(size: 3).bbox.size", .expected = .{ .nums = &.{ 10, 10, 0 } } },
        // Turning right, the arc turns right too; a keyword wins over the same size given positionally
        .{ .src = "r = polyline([[0, 0], [10, 0], [10, -10]]).fillet(1, r: 3).length", .expected = .{ .num = 14 + 1.5 * std.math.pi } },
        // Beside an arc: the line, the fillet and what is left of the arc
        .{ .src = "r = line([0, 0], [10, 0]).arc_to([15, -5], r: 5).fillet(1).inspect", .expected = .{ .str = "#<Path 3 segments from [0, 0] to [15, -5]>" } },
        .{ .src = comptime rescued("line([0, 0], [10, 0]).arc_to([7, 3], r: 3).fillet(4)"), .expected = .{ .str = "ValueError: fillet: no arc of r = 4 touches both sides at point 1, [10, 0]: an arc there turns that way more tightly, or the sides don't come that close" } },
        // No corner where the path goes on straight, nor where an arc goes on smoothly
        .{ .src = "r = polyline([[0, 0], [5, 0], [10, 0]]).fillet(1).inspect", .expected = .{ .str = "#<Path 2 segments from [0, 0] to [10, 0]>" } },
        .{ .src = BRACKET ++ "r = p.fillet(1).length == p.length", .expected = .{ .boolean = true } },
        // Closed, the ends meet at a sharp corner: two rounded corners and two sharp ones
        .{ .src = "r = polyline([[0, 0], [10, 0], [10, 10], [0, 10]]).fillet(5).close.extrude(1).volume < 100", .expected = .{ .boolean = true } },
        .{ .src = comptime rescued(ELL ++ "p.fillet"), .expected = .{ .str = "ArgumentError: fillet needs its r: fillet(r)" } },
        .{ .src = comptime rescued(ELL ++ "p.fillet(1, 2)"), .expected = .{ .str = "ArgumentError: fillet takes at most 1 positional argument (r), got 2" } },
        .{ .src = comptime rescued(ELL ++ "p.fillet(radius: 1)"), .expected = .{ .str = "ArgumentError: fillet does not take a keyword 'radius' (it accepts: r)" } },
        .{ .src = comptime rescued(ELL ++ "p.chamfer(-1)"), .expected = .{ .str = "ValueError: chamfer expects size to be a finite number greater than zero, got -1" } },
        .{ .src = comptime rescued("polyline([[0, 0], [10, 0], [5, 0]]).fillet(1)"), .expected = .{ .str = "ValueError: fillet: the sides double back at point 1, [10, 0], where no corner can be rounded" } },
        .{ .src = comptime rescued("polyline([[0, 0], [10, 0], [5, 0]]).chamfer(1)"), .expected = .{ .str = "ValueError: chamfer: the sides double back at point 1, [10, 0], where no corner can be cut" } },
        .{ .src = comptime rescued("polyline([[0, 0], [2, 0], [2, 10]]).fillet(3)"), .expected = .{ .str = "ValueError: fillet: the side from point 0 is 2 long, too short for the corners at its ends, which take 3 of it (r = 3)" } },
        .{ .src = comptime rescued("polyline([[0, 0], [10, 0], [10, 5], [0, 5]]).chamfer(3)"), .expected = .{ .str = "ValueError: chamfer: the side from point 1 is 5 long, too short for the corners at its ends, which take 6 of it (size = 3)" } },
    });
}

test "paths: a path's bbox is its own, an arc's bend included" {
    try expectScripts(&.{
        .{ .src = "r = arc(center: [0, 0], r: 5, start: 0, sweep: 90).bbox.size", .expected = .{ .nums = &.{ 5, 5, 0 } } },
        .{ .src = "r = (line([-1, 0], [1, 0]) + arc(r: 1, start: [1, 0], to: [-1, 0])).bbox.max", .expected = .{ .nums = &.{ 1, 1, 0 } } },
        .{ .src = "r = polyline([[0, 0], [3, 4], [6, 0]]).bbox.size", .expected = .{ .nums = &.{ 6, 4, 0 } } },
    });
}
