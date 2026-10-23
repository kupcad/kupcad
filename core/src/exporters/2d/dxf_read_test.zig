const std = @import("std");
const testing = std.testing;
const dxf_read = @import("dxf_read.zig");
const path = @import("../../core/path.zig");

/// A DXF file of `entities` (group codes and values, a line each), in `header`'s units.
fn file(comptime header: []const u8, comptime entities: []const u8) []const u8 {
    return "0\nSECTION\n2\nHEADER\n" ++ header ++ "0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" ++ entities ++ "0\nENDSEC\n0\nEOF\n";
}

fn read(text: []const u8, layers: ?[]const []const u8) !dxf_read.Drawing {
    var diag: dxf_read.Diagnostic = .{};
    return dxf_read.read(testing.allocator, text, .{ .tolerance = 1e-6, .layers = layers }, &diag) catch |err| {
        std.debug.print("dxf: {s}\n", .{diag.message()});
        return err;
    };
}

fn expectRefused(text: []const u8, message: []const u8) !void {
    var diag: dxf_read.Diagnostic = .{};
    try testing.expectError(error.InvalidDrawing, dxf_read.read(testing.allocator, text, .{ .tolerance = 1e-6 }, &diag));
    try testing.expectEqualStrings(message, diag.message());
}

fn expectPoint(expected: [2]f64, actual: [2]f64) !void {
    try testing.expectApproxEqAbs(expected[0], actual[0], 1e-9);
    try testing.expectApproxEqAbs(expected[1], actual[1], 1e-9);
}

/// A slot: two lines (the top one drawn backwards) and two half circles, as separate entities.
const SLOT =
    "0\nLINE\n8\ncut\n10\n0\n20\n0\n11\n20\n21\n0\n" ++
    "0\nARC\n8\ncut\n10\n20\n20\n5\n40\n5\n50\n270\n51\n90\n" ++
    "0\nLINE\n8\ncut\n10\n0\n20\n10\n11\n20\n21\n10\n" ++
    "0\nARC\n8\ncut\n10\n0\n20\n5\n40\n5\n50\n90\n51\n270\n";

test "DXF read: lines and arcs drawn apart are joined end to end, either way round, into one outline" {
    var drawing = try read(file("", SLOT), null);
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 1), drawing.outlines.len);
    const outline = drawing.outlines[0];
    try testing.expectEqual(@as(usize, 4), outline.segments.len);
    try expectPoint(.{ 0, 0 }, outline.start);
    // Along the bottom, round the right end, back along the top (turned around), round the left
    try expectPoint(.{ 20, 0 }, outline.segments[0].to);
    try expectPoint(.{ 20, 5 }, outline.segments[1].arc.?.center);
    try testing.expect(outline.segments[1].ccw);
    try expectPoint(.{ 0, 10 }, outline.segments[2].to);
    try testing.expect(outline.segments[2].isLine());
    try testing.expectEqual([2]f64{ 0, 0 }, outline.segments[3].to);
    try testing.expectApproxEqAbs(200 + 25 * std.math.pi, path.signedArea(outline.start, outline.segments), 1e-9);
    try testing.expectEqualStrings("cut", drawing.layers[0]);
}

test "DXF read: a polyline's bulges are arcs, its closing segment too, and a circle is whole" {
    // A 10 by 10 square whose right side bulges out into a half circle, and whose closing
    // side (from the last vertex back to the first) bulges in by a quarter turn
    const polyline = "0\nLWPOLYLINE\n8\n0\n90\n4\n70\n1\n10\n0\n20\n0\n10\n10\n20\n0\n42\n1\n10\n10\n20\n10\n10\n0\n20\n10\n42\n-0.41421356237309503\n";
    var drawing = try read(file("", polyline ++ "0\nCIRCLE\n8\n0\n10\n30\n20\n5\n40\n2\n"), null);
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 2), drawing.outlines.len);
    const square = drawing.outlines[0];
    try testing.expectEqual(@as(usize, 4), square.segments.len);
    const half = square.segments[1];
    try expectPoint(.{ 10, 5 }, half.arc.?.center);
    try testing.expectApproxEqAbs(@as(f64, 5), half.arc.?.radius, 1e-9);
    try testing.expectApproxEqAbs(std.math.pi, half.angle, 1e-9);
    try testing.expect(half.ccw);
    // The closing side, the left one: a clockwise quarter turn about (-5, 5), bulging in
    const closing = square.segments[3];
    try expectPoint(.{ 0, 0 }, closing.to);
    try expectPoint(.{ -5, 5 }, closing.arc.?.center);
    try testing.expect(!closing.ccw);
    try testing.expectApproxEqAbs(std.math.pi / 2.0, closing.angle, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10) / std.math.sqrt2, closing.arc.?.radius, 1e-9);
    // A circle: two half turns about its centre, from its rightmost point
    const circle = drawing.outlines[1];
    try expectPoint(.{ 32, 5 }, circle.start);
    try testing.expectEqual(@as(usize, 2), circle.segments.len);
    try expectPoint(.{ 30, 5 }, circle.segments[0].arc.?.center);
}

test "DXF read: the file's units become millimetres, and a plane turned over mirrors x" {
    var inches = try read(file("9\n$INSUNITS\n70\n1\n", "0\nCIRCLE\n10\n1\n20\n2\n40\n0.5\n"), null);
    defer inches.deinit();
    try expectPoint(.{ 25.4, 50.8 }, inches.outlines[0].segments[0].arc.?.center);
    try testing.expectApproxEqAbs(@as(f64, 12.7), inches.outlines[0].segments[0].arc.?.radius, 1e-9);

    // An arc whose normal is -z: in its own plane from 0 to 90 degrees about (5, 0), which
    // is about (-5, 0) seen from above, from (-6, 0) to (-5, 1), clockwise
    const arc = "0\nARC\n10\n5\n20\n0\n40\n1\n50\n0\n51\n90\n210\n0\n220\n0\n230\n-1\n" ++ "0\nLINE\n10\n-5\n20\n1\n11\n-6\n21\n0\n";
    var mirrored = try read(file("", arc), null);
    defer mirrored.deinit();
    const outline = mirrored.outlines[0];
    try expectPoint(.{ -6, 0 }, outline.start);
    try expectPoint(.{ -5, 0 }, outline.segments[0].arc.?.center);
    try testing.expect(!outline.segments[0].ccw);
    try expectPoint(.{ -5, 1 }, outline.segments[0].to);
}

test "DXF read: an old-style POLYLINE, a spline and an ellipse" {
    const polyline = "0\nPOLYLINE\n8\n0\n66\n1\n70\n1\n0\nVERTEX\n10\n0\n20\n0\n0\nVERTEX\n10\n4\n20\n0\n0\nVERTEX\n10\n0\n20\n3\n0\nSEQEND\n";
    // A cubic of one piece (a Bézier) from (0, 0) to (10, 0), closed by a line under it
    const spline = "0\nSPLINE\n70\n8\n71\n3\n72\n8\n73\n4\n40\n0\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n40\n1\n10\n0\n20\n0\n10\n0\n20\n10\n10\n10\n20\n10\n10\n10\n20\n0\n" ++ "0\nLINE\n10\n0\n20\n0\n11\n10\n21\n0\n";
    // A full ellipse of half axes 4 and 2
    const ellipse = "0\nELLIPSE\n10\n0\n20\n0\n11\n4\n21\n0\n40\n0.5\n41\n0\n42\n6.283185307179586\n";
    var drawing = try read(file("", polyline ++ spline ++ ellipse), null);
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 3), drawing.outlines.len);
    try testing.expectEqual(@as(f64, 6), @abs(path.signedArea(drawing.outlines[0].start, drawing.outlines[0].segments)));
    // The spline is its one cubic, exact: its area over its chord 6/10 of its control
    // polygon's height times its width
    const bump = drawing.outlines[1];
    try testing.expectEqual(@as(usize, 2), bump.segments.len);
    try expectPoint(.{ 0, 10 }, bump.segments[0].cubic.?.c1);
    try expectPoint(.{ 10, 10 }, bump.segments[0].cubic.?.c2);
    try testing.expectApproxEqAbs(@as(f64, 60), @abs(path.signedArea(bump.start, bump.segments)), 1e-9);
    // The ellipse: cubics of an eighth of a turn, ending on it, as near it as a circle's
    const ellipse_outline = drawing.outlines[2];
    try testing.expectEqual(@as(usize, 8), ellipse_outline.segments.len);
    for (ellipse_outline.segments) |segment| {
        try testing.expect(segment.cubic != null);
        try testing.expectApproxEqAbs(@as(f64, 1), (segment.to[0] * segment.to[0]) / 16 + (segment.to[1] * segment.to[1]) / 4, 1e-9);
    }
    try testing.expectApproxEqAbs(8 * std.math.pi, @abs(path.signedArea(ellipse_outline.start, ellipse_outline.segments)), 1e-3);
}

test "DXF read: a spline of degree 3 at most is its Bézier pieces, any other cubics within the tolerance of it" {
    // Each closed by a line back along y = 0
    const back = "0\nLINE\n10\n0\n20\n0\n11\n20\n21\n0\n";
    // Of degree 3, two spans: its pieces' controls the blossoms of the knots 0, 1, 2
    const two = "0\nSPLINE\n71\n3\n40\n0\n40\n0\n40\n0\n40\n0\n40\n1\n40\n2\n40\n2\n40\n2\n40\n2\n" ++
        "10\n0\n20\n0\n10\n0\n20\n10\n10\n10\n20\n10\n10\n20\n20\n10\n10\n20\n20\n0\n";
    var cubic = try read(file("", two ++ back), null);
    defer cubic.deinit();
    const s = cubic.outlines[0].segments;
    try testing.expectEqual(@as(usize, 3), s.len);
    try expectPoint(.{ 0, 10 }, s[0].cubic.?.c1);
    try expectPoint(.{ 5, 10 }, s[0].cubic.?.c2);
    try expectPoint(.{ 10, 10 }, s[0].to);
    try expectPoint(.{ 15, 10 }, s[1].cubic.?.c1);
    try expectPoint(.{ 20, 10 }, s[1].cubic.?.c2);
    try expectPoint(.{ 20, 0 }, s[1].to);
    // Of degree 2, raised to a cubic; of degree 1, its lines; with weights all the same,
    // as if it had none
    const quadratic = "0\nSPLINE\n71\n2\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n10\n0\n20\n0\n10\n10\n20\n15\n10\n20\n20\n0\n41\n2\n41\n2\n41\n2\n";
    const lines = "0\nSPLINE\n71\n1\n40\n0\n40\n0\n40\n1\n40\n2\n40\n2\n10\n0\n20\n0\n10\n10\n20\n5\n10\n20\n20\n0\n";
    var raised = try read(file("", quadratic ++ back), null);
    defer raised.deinit();
    try testing.expectEqual(@as(usize, 2), raised.outlines[0].segments.len);
    try expectPoint(.{ 20.0 / 3.0, 10 }, raised.outlines[0].segments[0].cubic.?.c1);
    try expectPoint(.{ 40.0 / 3.0, 10 }, raised.outlines[0].segments[0].cubic.?.c2);
    var straight = try read(file("", lines ++ back), null);
    defer straight.deinit();
    try testing.expectEqual(@as(usize, 3), straight.outlines[0].segments.len);
    try testing.expect(straight.outlines[0].segments[0].isLine());
    try expectPoint(.{ 10, 5 }, straight.outlines[0].segments[0].to);
    // A rational quadratic, a quarter of a circle of radius 20 about (0, 0), closed by
    // the radii: cubics on the circle within the tolerance, a hair inside it
    const quarter = "0\nSPLINE\n71\n2\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n10\n20\n20\n0\n10\n20\n20\n20\n10\n0\n20\n20\n" ++
        "41\n1\n41\n0.7071067811865476\n41\n1\n" ++ "0\nLINE\n10\n0\n20\n20\n11\n0\n21\n0\n" ++ "0\nLINE\n10\n0\n20\n0\n11\n20\n21\n0\n";
    var circle = try read(file("", quarter), null);
    defer circle.deinit();
    const arc = circle.outlines[0];
    var from = arc.start;
    var fitted: usize = 0;
    for (arc.segments) |segment| {
        defer from = segment.to;
        const c = segment.cubic orelse continue;
        fitted += 1;
        for (1..8) |k| {
            const p = @import("../../core/bezier.zig").pointOn(from, c, segment.to, @as(f64, @floatFromInt(k)) / 8);
            try testing.expectApproxEqAbs(@as(f64, 20), std.math.hypot(p[0], p[1]), 1e-6);
        }
    }
    try testing.expect(fitted > 1);
    try testing.expectApproxEqAbs(100 * std.math.pi, @abs(path.signedArea(arc.start, arc.segments)), 1e-4);
}

test "DXF read: a SPLINE of fit points alone is the cubic through them, along its end tangents" {
    // Four points, 5, 6 and 5 apart: one Bézier, through each at its share of the 16
    const four = "0\nSPLINE\n71\n3\n74\n4\n11\n0\n21\n0\n11\n3\n21\n4\n11\n9\n21\n4\n11\n12\n21\n0\n" ++ "0\nLINE\n10\n12\n20\n0\n11\n0\n21\n0\n";
    var drawing = try read(file("", four), null);
    defer drawing.deinit();
    const outline = drawing.outlines[0];
    try testing.expectEqual(@as(usize, 2), outline.segments.len);
    const bump = outline.segments[0];
    const bezier = @import("../../core/bezier.zig");
    for ([_][2]f64{ .{ 0, 0 }, .{ 3, 4 }, .{ 9, 4 }, .{ 12, 0 } }, [_]f64{ 0, 5.0 / 16.0, 11.0 / 16.0, 1 }) |q, u| {
        try expectPoint(q, bezier.pointOn(outline.start, bump.cubic.?, bump.to, u));
    }
    // Leaving straight up (12, 22) and arriving straight down (13, 23)
    const arch = "0\nSPLINE\n71\n3\n12\n0\n22\n1\n13\n0\n23\n-1\n11\n0\n21\n0\n11\n5\n21\n5\n11\n10\n21\n0\n" ++ "0\nLINE\n10\n10\n20\n0\n11\n0\n21\n0\n";
    var tangent = try read(file("", arch), null);
    defer tangent.deinit();
    const first = tangent.outlines[0].segments[0].cubic.?;
    try testing.expectApproxEqAbs(@as(f64, 0), first.c1[0], 1e-12);
    try testing.expect(first.c1[1] > 0);
    // Closed (flag 1) through eight points of a circle, not given its first again: one
    // outline, near the circle
    const ring = comptime blk: {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = "0\nSPLINE\n70\n9\n71\n3\n";
        for (0..8) |k| {
            const a = @as(f64, @floatFromInt(k)) * std.math.pi / 4;
            text = text ++ std.fmt.comptimePrint("11\n{d}\n21\n{d}\n", .{ 10 * @cos(a), 10 * @sin(a) });
        }
        break :blk text;
    };
    var loop = try read(file("", ring), null);
    defer loop.deinit();
    try testing.expectEqual(@as(usize, 1), loop.outlines.len);
    try testing.expectApproxEqRel(100 * std.math.pi, @abs(path.signedArea(loop.outlines[0].start, loop.outlines[0].segments)), 3e-3);
}

test "DXF read: only the layers asked for, every layer read named, and what isn't an outline left out" {
    // A text, a dimension, and a layout's frame (paper space) beside the slot and the hole
    const text = file("", SLOT ++ "0\nCIRCLE\n8\nholes\n10\n10\n20\n5\n40\n1\n" ++ "0\nTEXT\n8\nnotes\n10\n0\n20\n0\n40\n2\n1\nhello\n" ++ "0\nDIMENSION\n8\ndims\n" ++ "0\nLINE\n67\n1\n8\nframe\n10\n0\n20\n0\n11\n100\n21\n0\n");
    var holes = try read(text, &.{"holes"});
    defer holes.deinit();
    try testing.expectEqual(@as(usize, 1), holes.outlines.len);
    try testing.expectEqual(@as(usize, 2), holes.layers.len);
    try testing.expectEqualStrings("cut", holes.layers[0]);
    try testing.expectEqualStrings("holes", holes.layers[1]);
    var all = try read(text, null);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 2), all.outlines.len);
}

test "DXF read: pieces that join into no outline are open paths, when the reader keeps them" {
    // A score line of two pieces drawn apart, beside a closed square
    const text = file("", "0\nLINE\n8\nscore\n10\n0\n20\n0\n11\n10\n21\n0\n" ++ "0\nARC\n8\nscore\n10\n10\n20\n5\n40\n5\n50\n270\n51\n0\n" ++
        "0\nLWPOLYLINE\n8\ncut\n70\n1\n10\n0\n20\n20\n10\n4\n20\n20\n10\n4\n20\n24\n10\n0\n20\n24\n");
    var diag: dxf_read.Diagnostic = .{};
    var drawing = try dxf_read.read(testing.allocator, text, .{ .tolerance = 1e-6, .keep_open = true }, &diag);
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 1), drawing.outlines.len);
    try testing.expectEqual(@as(usize, 1), drawing.open_paths.len);
    const score = drawing.open_paths[0];
    try expectPoint(.{ 0, 0 }, score.start);
    try testing.expectEqual(@as(usize, 2), score.segments.len);
    try expectPoint(.{ 15, 5 }, score.segments[1].to);
    try expectPoint(.{ 10, 5 }, score.segments[1].arc.?.center);
}

/// A file whose BLOCKS section defines `blocks` (BLOCK ... ENDBLK each) and whose
/// ENTITIES are `entities`.
fn withBlocks(comptime blocks: []const u8, comptime entities: []const u8) []const u8 {
    return "0\nSECTION\n2\nBLOCKS\n" ++ blocks ++ "0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" ++ entities ++ "0\nENDSEC\n0\nEOF\n";
}

/// A block of one circle of radius 1 about (0, 0), on layer 0.
const BOLT = "0\nBLOCK\n8\n0\n2\nbolt\n10\n0\n20\n0\n0\nCIRCLE\n8\n0\n10\n0\n20\n0\n40\n1\n0\nENDBLK\n";

fn center(drawing: dxf_read.Drawing, i: usize) [2]f64 {
    return drawing.outlines[i].segments[0].arc.?.center;
}

test "DXF read: an INSERT places its block's entities: moved, scaled, turned, copied" {
    // At (10, 5), twice the size, turned a quarter, on the layer "parts" (its circle is
    // on layer 0, so it takes the INSERT's)
    var one = try read(withBlocks(BOLT, "0\nINSERT\n8\nparts\n2\nbolt\n10\n10\n20\n5\n41\n2\n42\n2\n50\n90\n"), &.{"parts"});
    defer one.deinit();
    try testing.expectEqual(@as(usize, 1), one.outlines.len);
    try expectPoint(.{ 10, 5 }, center(one, 0));
    try testing.expectApproxEqAbs(@as(f64, 2), one.outlines[0].segments[0].arc.?.radius, 1e-9);
    try testing.expectEqualStrings("parts", one.layers[0]);
    // Three columns 20 apart along its turned x (up), two rows 10 apart (to the left)
    var array = try read(withBlocks(BOLT, "0\nINSERT\n2\nbolt\n10\n0\n20\n0\n50\n90\n70\n3\n71\n2\n44\n20\n45\n10\n"), null);
    defer array.deinit();
    try testing.expectEqual(@as(usize, 6), array.outlines.len);
    try expectPoint(.{ 0, 40 }, center(array, 2));
    try expectPoint(.{ -10, 0 }, center(array, 3));
    // A block's base point goes to the insertion point: a square of 10 from (5, 5)
    const square = "0\nBLOCK\n2\nplate\n10\n5\n20\n5\n0\nLWPOLYLINE\n70\n1\n10\n5\n20\n5\n10\n15\n20\n5\n10\n15\n20\n15\n10\n5\n20\n15\n0\nENDBLK\n";
    var placed = try read(withBlocks(square, "0\nINSERT\n2\nplate\n10\n100\n20\n0\n"), null);
    defer placed.deinit();
    try expectPoint(.{ 100, 0 }, placed.outlines[0].start);
}

test "DXF read: blocks within blocks, uneven scales, mirrors, and a turned-over plane" {
    // A pair of bolts 10 apart, placed twice
    const pair = BOLT ++ "0\nBLOCK\n2\npair\n10\n0\n20\n0\n0\nINSERT\n2\nbolt\n10\n0\n20\n0\n0\nINSERT\n2\nbolt\n10\n10\n20\n0\n0\nENDBLK\n";
    var nested = try read(withBlocks(pair, "0\nINSERT\n2\npair\n10\n0\n20\n0\n0\nINSERT\n2\npair\n10\n0\n20\n50\n"), null);
    defer nested.deinit();
    try testing.expectEqual(@as(usize, 4), nested.outlines.len);
    try expectPoint(.{ 10, 50 }, center(nested, 3));
    // Scaled 3 in x and 1 in y, the circle is an ellipse: cubics of an eighth of a turn on it
    var stretched = try read(withBlocks(BOLT, "0\nINSERT\n2\nbolt\n10\n0\n20\n0\n41\n3\n"), null);
    defer stretched.deinit();
    const stretched_outline = stretched.outlines[0];
    try testing.expectEqual(@as(usize, 8), stretched_outline.segments.len);
    for (stretched_outline.segments) |segment| {
        try testing.expect(segment.cubic != null);
        try testing.expectApproxEqAbs(@as(f64, 1), segment.to[0] * segment.to[0] / 9 + segment.to[1] * segment.to[1], 1e-9);
    }
    try testing.expectApproxEqAbs(3 * std.math.pi, @abs(path.signedArea(stretched_outline.start, stretched_outline.segments)), 1e-4);
    // Mirrored by a negative scale, and by a plane turned over: still arcs, about (-4, 0)
    inline for (.{ "41\n-1\n", "210\n0\n220\n0\n230\n-1\n" }) |mirror| {
        var mirrored = try read(withBlocks(BOLT, "0\nINSERT\n2\nbolt\n10\n4\n20\n0\n" ++ mirror), null);
        defer mirrored.deinit();
        try testing.expect(mirrored.outlines[0].segments[0].arc != null);
        try expectPoint(.{ if (std.mem.startsWith(u8, mirror, "41")) 4 else -4, 0 }, center(mirrored, 0));
    }
}

test "DXF read: what can't be read says why and where" {
    try expectRefused("AutoCAD Binary DXF\r\n\x1a\x00", "it is a binary DXF file: save it as an ASCII DXF");
    // A block that inserts itself, and an INSERT that scales its block to nothing
    try expectRefused(withBlocks("0\nBLOCK\n2\nloop\n0\nINSERT\n2\nloop\n10\n1\n20\n0\n0\nENDBLK\n", "0\nINSERT\n2\nloop\n10\n0\n20\n0\n"), "line 9: blocks nest deeper than 64 in the block 'loop', which may insert itself");
    try expectRefused(withBlocks(BOLT, "0\nINSERT\n2\nbolt\n10\n0\n20\n0\n41\n0\n"), "line 33: the INSERT of the block 'bolt' scales it to nothing");
    try expectRefused("0\nSECTION\nx\n", "line 3: 'x' isn't a group code (an ASCII DXF file alternates codes and values)");
    try expectRefused("0\nSECTION\n2\n", "line 3: group code 2 has no value");
    try expectRefused(file("", "0\nINSERT\n8\nparts\n2\nbolt\n10\n0\n20\n0\n"), "line 11: an INSERT of the block 'bolt', which the file doesn't define");
    try expectRefused(file("", "0\nLINE\n10\n0\n20\n0\n11\n10\n21\n0\n0\nLINE\n10\n10\n20\n0\n11\n10\n21\n5\n"), "an outline on layer '0' doesn't close: it runs from [0, 0] to [10, 5], 11.180339887498949 apart (import_dxf(path, tolerance:) joins ends that far apart, and paths: true reads open lines as Paths)");
    try expectRefused(file("", "0\nCIRCLE\n10\n0\n20\n0\n40\n1\n210\n1\n220\n0\n230\n0\n"), "line 11: the CIRCLE on layer '0' isn't in the XY plane (its normal is [1, 0, 0])");
    try expectRefused(file("", "0\nCIRCLE\n10\n0\n20\n0\n40\n0\n"), "line 11: the CIRCLE on layer '0' has a radius of 0");
    try expectRefused(file("", "0\nCIRCLE\n10\nx\n20\n0\n40\n1\n"), "line 14: group 10 should be a number, got 'x'");
    try expectRefused(file("", "0\nARC\n10\n0\n20\n0\n40\n1\n50\n0\n"), "line 11: the ARC has no group 51");
    try expectRefused(file("9\n$INSUNITS\n70\n99\n", ""), "line 8: its units ($INSUNITS 99) aren't a unit DXF names");
    try expectRefused(file("", "0\nSPLINE\n71\n3\n72\n4\n10\n0\n20\n0\n10\n1\n20\n1\n10\n2\n20\n0\n10\n3\n20\n1\n40\n0\n40\n0\n40\n1\n40\n1\n"), "line 11: the SPLINE on layer '0' has 4 knots for 4 control points of degree 3: it needs 8");
}
