const std = @import("std");
const testing = std.testing;
const svg_read = @import("svg_read.zig");
const path = @import("../../core/path.zig");
/// A drawing in millimetres, a user unit each.
const MM = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\">";

fn read(text: []const u8) !svg_read.Drawing {
    var diag: svg_read.Diagnostic = .{};
    return svg_read.read(testing.allocator, text, .{ .tolerance = 1e-6 }, &diag) catch |err| {
        std.debug.print("svg: {s}\n", .{diag.message()});
        return err;
    };
}

fn expectRefused(text: []const u8, message: []const u8) !void {
    var diag: svg_read.Diagnostic = .{};
    try testing.expectError(error.Unreadable, svg_read.read(testing.allocator, text, .{ .tolerance = 1e-6 }, &diag));
    try testing.expectEqualStrings(message, diag.message());
}

fn expectPoint(expected: [2]f64, actual: [2]f64) !void {
    try testing.expectApproxEqAbs(expected[0], actual[0], 1e-9);
    try testing.expectApproxEqAbs(expected[1], actual[1], 1e-9);
}

fn area(outline: path.Run) f64 {
    return @abs(path.signedArea(outline.start, outline.segments));
}

test "SVG read: user units become millimetres by the width and the viewBox, y turned over" {
    // Two user units a millimetre; without a size, a user unit is a CSS pixel
    const cases = [_]struct { svg: []const u8, mm: f64 }{
        .{ .svg = "<svg width=\"100mm\" height=\"50mm\" viewBox=\"0 0 50 25\"><rect width=\"10\" height=\"10\"/></svg>", .mm = 2 },
        .{ .svg = "<svg width=\"2in\" viewBox=\"0 0 2 1\"><rect width=\"10\" height=\"10\"/></svg>", .mm = 25.4 },
        .{ .svg = "<svg viewBox=\"0 0 2 1\"><rect width=\"10\" height=\"10\"/></svg>", .mm = 25.4 / 96.0 },
        .{ .svg = "<svg width=\"100%\" viewBox=\"0 0 2 1\"><rect width=\"10\" height=\"10\"/></svg>", .mm = 25.4 / 96.0 },
        // A shape's length with a unit is in CSS pixels of user space, as SVG has it:
        // 2.6458 mm is 10 user units, here 10 mm
        .{ .svg = MM ++ "<rect width=\"2.6458333333333335mm\" height=\"2.6458333333333335mm\"/></svg>", .mm = 1 },
    };
    for (cases) |case| {
        errdefer std.debug.print("svg: {s}\n", .{case.svg});
        var drawing = try read(case.svg);
        defer drawing.deinit();
        const outline = drawing.outlines[0];
        try expectPoint(.{ 0, 0 }, outline.start);
        try expectPoint(.{ 10 * case.mm, 0 }, outline.segments[0].to);
        try expectPoint(.{ 10 * case.mm, -10 * case.mm }, outline.segments[1].to);
    }
}

test "SVG read: a path's commands, absolute and relative, and its subpaths each an outline" {
    // A 10 mm square drawn with H and V, then one with relative lines after a Z, the
    // implicit lines after an m, and numbers run together
    var drawing = try read(MM ++ "<path d=\"M0 0H10V10H0Z m20 0 10 0l0 10-10 0z\"/></svg>");
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 2), drawing.outlines.len);
    try testing.expectApproxEqAbs(@as(f64, 100), area(drawing.outlines[0]), 1e-9);
    try expectPoint(.{ 20, 0 }, drawing.outlines[1].start);
    try testing.expectApproxEqAbs(@as(f64, 100), area(drawing.outlines[1]), 1e-9);

    // A half circle by an arc of equal radii, its flags run together: exact, an arc
    var arc = try read(MM ++ "<path d=\"M0 0a5 5 0 0010 0z\"/></svg>");
    defer arc.deinit();
    const half = arc.outlines[0].segments[0];
    try expectPoint(.{ 5, 0 }, half.arc.?.center);
    try testing.expectApproxEqAbs(@as(f64, 5), half.arc.?.radius, 1e-9);
    try testing.expectApproxEqAbs(std.math.pi, half.angle, 1e-9);
    try testing.expectApproxEqAbs(12.5 * std.math.pi, area(arc.outlines[0]), 1e-9);

    // Curves stay cubics: C, S's reflection, Q and T's raised to cubics, then the line back
    var curves = try read(MM ++ "<path d=\"M0 0C0 10 10 10 10 0S20 -10 20 0Q25 10 30 0T40 0Z\"/></svg>");
    defer curves.deinit();
    const c = curves.outlines[0].segments;
    try testing.expectEqual(@as(usize, 5), c.len);
    for (c[0..4]) |segment| try testing.expect(segment.cubic != null);
    // S mirrors C's second control (10, 10) about (10, 0): (10, -10), y turned over
    try expectPoint(.{ 10, 10 }, c[1].cubic.?.c1);
    try testing.expect(c[4].isLine());
    // A cubic whose controls are on its chord is the line it draws
    var straight = try read(MM ++ "<path d=\"M0 0C5 0 10 0 15 0L15 5Z\"/></svg>");
    defer straight.deinit();
    try testing.expect(straight.outlines[0].segments[0].isLine());
    // S and T mirror the C and the Q below the line, so their areas cancel
    try testing.expectApproxEqAbs(@as(f64, 0), path.signedArea(curves.outlines[0].start, curves.outlines[0].segments), 0.05);
}

test "SVG read: shapes, transforms, and an ellipse's arcs as lines" {
    var drawing = try read(MM ++ "<g transform=\"translate(10 5)\"><rect x=\"0\" y=\"0\" width=\"40\" height=\"20\" rx=\"5\"/>" ++
        "<circle cx=\"20\" cy=\"10\" r=\"4\" transform=\"rotate(30 20 10)\"/><polygon points=\"60,0 80,0 70,10\"/></g>" ++
        "<ellipse cx=\"0\" cy=\"50\" rx=\"10\" ry=\"5\"/><circle cx=\"50\" cy=\"50\" r=\"2\" transform=\"scale(2 1)\"/></svg>");
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 5), drawing.outlines.len);
    // The rounded rect: four quarter arcs of radius 5, moved by the group
    const rect = drawing.outlines[0];
    var arcs: usize = 0;
    for (rect.segments) |segment| if (segment.arc) |a| {
        try testing.expectApproxEqAbs(@as(f64, 5), a.radius, 1e-9);
        arcs += 1;
    };
    try testing.expectEqual(@as(usize, 4), arcs);
    try testing.expectApproxEqAbs(800 - 25 * (4 - std.math.pi), area(rect), 1e-9);
    try expectPoint(.{ 15, -5 }, rect.start);
    // Turned about its own centre, the circle stays where it was, exact
    try expectPoint(.{ 30, -15 }, drawing.outlines[1].segments[0].arc.?.center);
    try testing.expectApproxEqAbs(@as(f64, 100), area(drawing.outlines[2]), 1e-9);
    // The ellipse and the circle scaled unevenly: cubics of an eighth of a turn, ending on it
    for (drawing.outlines[3..]) |outline| {
        try testing.expectEqual(@as(usize, 8), outline.segments.len);
        for (outline.segments) |segment| try testing.expect(segment.cubic != null);
    }
    for (drawing.outlines[3].segments) |segment| {
        try testing.expectApproxEqAbs(@as(f64, 1), (segment.to[0] * segment.to[0]) / 100 + ((segment.to[1] + 50) * (segment.to[1] + 50)) / 25, 1e-3);
    }
    try testing.expectApproxEqAbs(@as(f64, 8) * std.math.pi, area(drawing.outlines[4]), 1e-3);
}

test "SVG read: a filled open subpath is closed for its fill, an unfilled one is a stroke, an open path" {
    var drawing = try read(MM ++ "<path d=\"M0 0L10 0L10 10\"/><path d=\"M20 0L30 0L30 10\" fill=\"none\"/>" ++
        "<g style=\"fill:none\"><path d=\"M40 0L50 0L50 10Z\"/><polyline points=\"60,0 70,0 70,10\"/></g>" ++
        "<line x1=\"0\" y1=\"20\" x2=\"10\" y2=\"20\" fill=\"red\"/><path d=\"M0 30A5 5 0 0 1 10 30\" fill=\"none\"/></svg>");
    defer drawing.deinit();
    // The filled triangle, and the closed one in the unfilled group
    try testing.expectEqual(@as(usize, 2), drawing.outlines.len);
    try testing.expectApproxEqAbs(@as(f64, 50), area(drawing.outlines[0]), 1e-9);
    try expectPoint(.{ 40, 0 }, drawing.outlines[1].start);
    // The strokes alone, open as they were drawn: two corners, a line (filled or not, it
    // encloses nothing) and an arc, exact
    const open = drawing.open_paths;
    try testing.expectEqual(@as(usize, 4), open.len);
    try expectPoint(.{ 20, 0 }, open[0].start);
    try testing.expectEqual(@as(usize, 2), open[0].segments.len);
    try expectPoint(.{ 30, -10 }, open[0].segments[1].to);
    try expectPoint(.{ 60, 0 }, open[1].start);
    try expectPoint(.{ 10, -20 }, open[2].segments[0].to);
    try expectPoint(.{ 5, -30 }, open[3].segments[0].arc.?.center);
    try expectPoint(.{ 10, -30 }, open[3].segments[0].to);
}

test "SVG read: what isn't drawn is left out, and a line is an open path" {
    var drawing = try read("<?xml version=\"1.0\"?>\n<!DOCTYPE svg [ <!ENTITY a \"b\"> ]>\n<!-- a <rect> in a comment -->\n" ++ MM ++
        "<sodipodi:namedview/><defs><rect width=\"5\" height=\"5\"/></defs><title>t</title><text x=\"0\">hi</text><line x1=\"0\" y1=\"0\" x2=\"5\" y2=\"5\"/>" ++
        "<rect width=\"5\" height=\"5\" display=\"none\"/><g style=\"display: none\"><rect width=\"5\" height=\"5\"/></g><![CDATA[<rect/>]]>" ++
        "<rect width=\"7\" height=\"7\"/></svg>");
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 1), drawing.outlines.len);
    try testing.expectApproxEqAbs(@as(f64, 49), area(drawing.outlines[0]), 1e-9);
    // The line is a stroke: an open path, nothing else
    try testing.expectEqual(@as(usize, 1), drawing.open_paths.len);
}

test "SVG read: a use draws the element it names where it is, through its move and style" {
    // A square defined once and drawn twice, by x and y and by a transform
    var squares = try read(MM ++ "<defs><rect id=\"sq\" width=\"10\" height=\"10\"/></defs><use href=\"#sq\" x=\"20\"/><use xlink:href=\"#sq\" transform=\"translate(0 30)\"/></svg>");
    defer squares.deinit();
    try testing.expectEqual(@as(usize, 2), squares.outlines.len);
    try expectPoint(.{ 20, 0 }, squares.outlines[0].start);
    try expectPoint(.{ 0, -30 }, squares.outlines[1].start);
    // A pair of them in a group, drawn twice: uses within uses; and one drawn where it is too
    var pairs = try read(MM ++ "<defs><rect id=\"sq\" width=\"1\" height=\"1\"/><g id=\"pair\"><use href=\"#sq\"/><use href=\"#sq\" x=\"5\"/></g></defs>" ++
        "<use href=\"#pair\"/><use href=\"#pair\" y=\"10\"/><circle id=\"dot\" cx=\"50\" r=\"1\"/><use href=\"#dot\" x=\"10\"/></svg>");
    defer pairs.deinit();
    try testing.expectEqual(@as(usize, 6), pairs.outlines.len);
    try expectPoint(.{ 5, -10 }, pairs.outlines[3].start);
    try expectPoint(.{ 60, 0 }, pairs.outlines[5].segments[0].arc.?.center);
    // The style comes from the use: unfilled, the open path is a stroke; a symbol is a group
    var styled = try read(MM ++ "<defs><path id=\"l\" d=\"M0 0L10 0L10 10\"/></defs><use href=\"#l\" fill=\"none\"/><use href=\"#l\"/>" ++
        "<symbol id=\"s\"><circle r=\"2\"/></symbol><use href=\"#s\" x=\"5\" y=\"5\"/></svg>");
    defer styled.deinit();
    try testing.expectEqual(@as(usize, 1), styled.open_paths.len);
    try testing.expectEqual(@as(usize, 2), styled.outlines.len);
    try expectPoint(.{ 5, -5 }, styled.outlines[1].segments[0].arc.?.center);
}

/// The box `drawing`'s outline `i` spans: its least x and y, then its greatest.
fn boxOf(drawing: svg_read.Drawing, i: usize) [4]f64 {
    const box = path.bounds(drawing.outlines[i].start, drawing.outlines[i].segments);
    return .{ box.min[0], box.min[1], box.max[0], box.max[1] };
}

fn expectBox(expected: [4]f64, actual: [4]f64) !void {
    for (expected, actual) |e, a| try testing.expectApproxEqAbs(e, a, 1e-9);
}

test "SVG read: a symbol's and a nested svg's viewBox fit it to their box, as preserveAspectRatio says" {
    // An icon of 24 drawn 12 wide at (10, 10), the y of the drawing turned over
    const icon = "<symbol id=\"i\" viewBox=\"0 0 24 24\"><rect width=\"24\" height=\"24\"/></symbol>";
    var sprite = try read(MM ++ icon ++ "<use href=\"#i\" x=\"10\" y=\"10\" width=\"12\" height=\"12\"/><use href=\"#i\"/><use href=\"#i\" width=\"0\"/></svg>");
    defer sprite.deinit();
    try expectBox(.{ 10, -22, 22, -10 }, boxOf(sprite, 0));
    // Without a size, all of the drawing's viewport; of no size, nothing
    try expectBox(.{ 0, -100, 100, 0 }, boxOf(sprite, 1));
    try testing.expectEqual(@as(usize, 2), sprite.outlines.len);
    // A box twice as wide as it is high in a square: met (in the middle, or at the start),
    // sliced, or stretched
    const wide = "<symbol id=\"w\" viewBox=\"0 0 20 10\"{s}><rect width=\"20\" height=\"10\"/></symbol><use href=\"#w\" width=\"10\" height=\"10\"/></svg>";
    const fits = [_]struct { attribute: []const u8, box: [4]f64 }{
        .{ .attribute = "", .box = .{ 0, -7.5, 10, -2.5 } },
        .{ .attribute = " preserveAspectRatio=\"xMinYMin\"", .box = .{ 0, -5, 10, 0 } },
        .{ .attribute = " preserveAspectRatio=\"xMidYMid slice\"", .box = .{ -5, -10, 15, 0 } },
        .{ .attribute = " preserveAspectRatio=\"none\"", .box = .{ 0, -10, 10, 0 } },
    };
    for (fits) |fit| {
        const text = try std.fmt.allocPrint(testing.allocator, MM ++ wide, .{fit.attribute});
        defer testing.allocator.free(text);
        var drawing = try read(text);
        defer drawing.deinit();
        try expectBox(fit.box, boxOf(drawing, 0));
    }
    // A nested svg: at its x and y, scaled into its box; a percentage is of the viewport
    // it is in
    var nested = try read(MM ++ "<svg x=\"50\" width=\"20\" height=\"20\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>" ++
        "<svg x=\"50%\" y=\"50%\" width=\"10%\" height=\"10%\" viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\"/></svg></svg>");
    defer nested.deinit();
    try expectBox(.{ 50, -20, 70, 0 }, boxOf(nested, 0));
    try expectBox(.{ 50, -60, 60, -50 }, boxOf(nested, 1));
    // Stretched unevenly, a circle is an ellipse's cubics
    var stretched = try read(MM ++ "<symbol id=\"c\" viewBox=\"-1 -1 2 2\" preserveAspectRatio=\"none\"><circle r=\"1\"/></symbol><use href=\"#c\" width=\"4\" height=\"2\"/></svg>");
    defer stretched.deinit();
    try expectBox(.{ 0, -2, 4, 0 }, boxOf(stretched, 0));
    try testing.expect(stretched.outlines[0].segments[0].cubic != null);

    try expectRefused("<svg>" ++ icon ++ "<use href=\"#i\"/></svg>", "line 1: the width of a <symbol> is the drawing's or a share of it, and the drawing has no size: give the <svg> a viewBox");
    try expectRefused(MM ++ "<svg viewBox=\"0 0 1 1\" preserveAspectRatio=\"xMidYMid sometimes\"></svg></svg>", "line 1: the preserveAspectRatio \"xMidYMid sometimes\" of a <svg> isn't SVG's");
}

test "SVG read: uses that draw themselves, or more than they may, are refused" {
    try expectRefused(MM ++ "<g id=\"a\"><use href=\"#a\"/></g></svg>", "line 1: a <use> of \"#a\" within that element, which would draw itself forever");
    try expectRefused(MM ++ "<use href=\"parts.svg#bolt\"/></svg>", "line 1: a <use> of \"parts.svg#bolt\": only an element of the same file (\"#id\") is read");
    // Three uses of two of three squares each: 18 elements drawn, of a cap of 10
    var diag: svg_read.Diagnostic = .{};
    const nested = MM ++ "<defs><g id=\"a\"><rect width=\"1\" height=\"1\"/><rect width=\"1\" height=\"1\"/><rect width=\"1\" height=\"1\"/></g>" ++
        "<g id=\"b\"><use href=\"#a\"/><use href=\"#a\"/></g></defs><use href=\"#b\"/><use href=\"#b\"/><use href=\"#b\"/></svg>";
    try testing.expectError(error.Unreadable, svg_read.read(testing.allocator, nested, .{ .tolerance = 1e-6, .max_cloned = 10 }, &diag));
    try testing.expectEqualStrings("its <use>s would draw more than 10 elements; a script reads at most that", diag.message());
}

test "SVG read: what can't be read says why and where" {
    try expectRefused("<html></html>", "line 1: a <html> comes before the <svg> element");
    try expectRefused("", "it has no <svg> element");
    try expectRefused(MM ++ "<use href=\"#a\"/></svg>", "line 1: a <use> of \"#a\", which no element of the file is");
    try expectRefused(MM ++ "\n<path d=\"M0 0 L 10 X\"/></svg>", "line 2: the path data of a <path> isn't SVG's at character 11: \"X\"");
    try expectRefused(MM ++ "<path d=\"10 10\"/></svg>", "line 1: the path data of a <path> isn't SVG's at character 1: \"10 10\"");
    try expectRefused(MM ++ "<g transform=\"spin(4)\"></g></svg>", "line 1: the transform \"spin(4)\" of a <g> isn't one SVG has");
    try expectRefused(MM ++ "<g></svg>", "line 1: </svg> closes a <g>");
    try expectRefused(MM ++ "<!-- open", "line 1: a comment doesn't end");
    try expectRefused(MM ++ "<polygon points=\"0 0 1\"/></svg>", "line 1: the points of a <polygon> are an odd count of numbers");
    try expectRefused(MM ++ "<rect width=\"-1\" height=\"1\"/></svg>", "line 1: a <rect> has a negative width or height");
    try expectRefused(MM ++ "<rect width=\"1cubit\" height=\"1\"/></svg>", "line 1: the width \"1cubit\" of a <rect> isn't a length");
    try expectRefused("<svg viewBox=\"0 0 0 1\"></svg>", "line 1: its viewBox \"0 0 0 1\" has no area");
}
