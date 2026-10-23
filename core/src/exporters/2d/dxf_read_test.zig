const std = @import("std");
const testing = std.testing;
const dxf_read = @import("dxf_read.zig");
const path = @import("../../core/path.zig");
const EngineConfig = @import("../../core/engine_config.zig").EngineConfig;

const CONFIG = EngineConfig{};

/// A DXF file of `entities` (group codes and values, a line each), in `header`'s units.
fn file(comptime header: []const u8, comptime entities: []const u8) []const u8 {
    return "0\nSECTION\n2\nHEADER\n" ++ header ++ "0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" ++ entities ++ "0\nENDSEC\n0\nEOF\n";
}

fn read(text: []const u8, layers: ?[]const []const u8) !dxf_read.Drawing {
    var diag: dxf_read.Diagnostic = .{};
    return dxf_read.read(testing.allocator, text, .{ .tolerance = 1e-6, .layers = layers, .config = &CONFIG }, &diag) catch |err| {
        std.debug.print("dxf: {s}\n", .{diag.message()});
        return err;
    };
}

fn expectRefused(text: []const u8, message: []const u8) !void {
    var diag: dxf_read.Diagnostic = .{};
    try testing.expectError(error.InvalidDrawing, dxf_read.read(testing.allocator, text, .{ .tolerance = 1e-6, .config = &CONFIG }, &diag));
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
    // The curve's area over its chord is 6/10 of its control polygon's height times its width
    try testing.expectApproxEqAbs(@as(f64, 60), @abs(path.signedArea(drawing.outlines[1].start, drawing.outlines[1].segments)), 0.5);
    try testing.expect(drawing.outlines[1].segments.len > 8);
    // Every point of the ellipse on it
    for (drawing.outlines[2].segments) |segment| {
        try testing.expectApproxEqAbs(@as(f64, 1), (segment.to[0] * segment.to[0]) / 16 + (segment.to[1] * segment.to[1]) / 4, 1e-9);
    }
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
    var drawing = try dxf_read.read(testing.allocator, text, .{ .tolerance = 1e-6, .keep_open = true, .config = &CONFIG }, &diag);
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 1), drawing.outlines.len);
    try testing.expectEqual(@as(usize, 1), drawing.open_paths.len);
    const score = drawing.open_paths[0];
    try expectPoint(.{ 0, 0 }, score.start);
    try testing.expectEqual(@as(usize, 2), score.segments.len);
    try expectPoint(.{ 15, 5 }, score.segments[1].to);
    try expectPoint(.{ 10, 5 }, score.segments[1].arc.?.center);
}

test "DXF read: what can't be read says why and where" {
    try expectRefused("AutoCAD Binary DXF\r\n\x1a\x00", "it is a binary DXF file: save it as an ASCII DXF");
    try expectRefused("0\nSECTION\nx\n", "line 3: 'x' isn't a group code (an ASCII DXF file alternates codes and values)");
    try expectRefused("0\nSECTION\n2\n", "line 3: group code 2 has no value");
    try expectRefused(file("", "0\nINSERT\n8\nparts\n2\nbolt\n10\n0\n20\n0\n"), "line 11: a block reference (INSERT) on layer 'parts' isn't read yet: explode the blocks into their entities first");
    try expectRefused(file("", "0\nLINE\n10\n0\n20\n0\n11\n10\n21\n0\n0\nLINE\n10\n10\n20\n0\n11\n10\n21\n5\n"), "an outline on layer '0' doesn't close: it runs from [0, 0] to [10, 5], 11.180339887498949 apart (import_dxf(path, tolerance:) joins ends that far apart, and paths: true reads open lines as Paths)");
    try expectRefused(file("", "0\nCIRCLE\n10\n0\n20\n0\n40\n1\n210\n1\n220\n0\n230\n0\n"), "line 11: the CIRCLE on layer '0' isn't in the XY plane (its normal is [1, 0, 0])");
    try expectRefused(file("", "0\nCIRCLE\n10\n0\n20\n0\n40\n0\n"), "line 11: the CIRCLE on layer '0' has a radius of 0");
    try expectRefused(file("", "0\nCIRCLE\n10\nx\n20\n0\n40\n1\n"), "line 14: group 10 should be a number, got 'x'");
    try expectRefused(file("", "0\nARC\n10\n0\n20\n0\n40\n1\n50\n0\n"), "line 11: the ARC has no group 51");
    try expectRefused(file("9\n$INSUNITS\n70\n99\n", ""), "line 8: its units ($INSUNITS 99) aren't a unit DXF names");
    try expectRefused(file("", "0\nSPLINE\n71\n3\n72\n4\n10\n0\n20\n0\n10\n1\n20\n1\n10\n2\n20\n0\n10\n3\n20\n1\n40\n0\n40\n0\n40\n1\n40\n1\n"), "line 11: the SPLINE on layer '0' has 4 knots for 4 control points of degree 3: it needs 8");
    try expectRefused(file("", "0\nSPLINE\n71\n3\n74\n2\n11\n0\n21\n0\n11\n1\n21\n1\n"), "line 11: the SPLINE on layer '0' is given by fit points alone, which aren't read yet: give it control points");
}
