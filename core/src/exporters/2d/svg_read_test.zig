const std = @import("std");
const testing = std.testing;
const svg_read = @import("svg_read.zig");
const path = @import("../../core/path.zig");
const EngineConfig = @import("../../core/engine_config.zig").EngineConfig;

const CONFIG = EngineConfig{};
/// A resolution fine enough that a curve's lines measure as the curve.
const FINE = EngineConfig{ .resolution = .{ .segments = 1024 } };
/// A drawing in millimetres, a user unit each.
const MM = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\">";

fn read(text: []const u8) !svg_read.Drawing {
    return readAt(text, &CONFIG);
}

fn readAt(text: []const u8, config: *const EngineConfig) !svg_read.Drawing {
    var diag: svg_read.Diagnostic = .{};
    return svg_read.read(testing.allocator, text, .{ .tolerance = 1e-6, .config = config }, &diag) catch |err| {
        std.debug.print("svg: {s}\n", .{diag.message()});
        return err;
    };
}

fn expectRefused(text: []const u8, message: []const u8) !void {
    var diag: svg_read.Diagnostic = .{};
    try testing.expectError(error.InvalidDrawing, svg_read.read(testing.allocator, text, .{ .tolerance = 1e-6, .config = &CONFIG }, &diag));
    try testing.expectEqualStrings(message, diag.message());
}

fn expectPoint(expected: [2]f64, actual: [2]f64) !void {
    try testing.expectApproxEqAbs(expected[0], actual[0], 1e-9);
    try testing.expectApproxEqAbs(expected[1], actual[1], 1e-9);
}

fn area(outline: path.Loop) f64 {
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

    // Curves become lines along them: C, S's reflection, Q and T's
    var curves = try read(MM ++ "<path d=\"M0 0C0 10 10 10 10 0S20 -10 20 0Q25 10 30 0T40 0Z\"/></svg>");
    defer curves.deinit();
    for (curves.outlines[0].segments) |segment| try testing.expect(segment.isLine());
    try testing.expect(curves.outlines[0].segments.len > 20);
    // S and T mirror the C and the Q below the line, so their areas cancel
    try testing.expectApproxEqAbs(@as(f64, 0), path.signedArea(curves.outlines[0].start, curves.outlines[0].segments), 0.05);
}

test "SVG read: shapes, transforms, and an ellipse's arcs as lines" {
    var drawing = try readAt(MM ++ "<g transform=\"translate(10 5)\"><rect x=\"0\" y=\"0\" width=\"40\" height=\"20\" rx=\"5\"/>" ++
        "<circle cx=\"20\" cy=\"10\" r=\"4\" transform=\"rotate(30 20 10)\"/><polygon points=\"60,0 80,0 70,10\"/></g>" ++
        "<ellipse cx=\"0\" cy=\"50\" rx=\"10\" ry=\"5\"/><circle cx=\"50\" cy=\"50\" r=\"2\" transform=\"scale(2 1)\"/></svg>", &FINE);
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
    // The ellipse and the circle scaled unevenly: lines on the ellipse
    for (drawing.outlines[3..]) |outline| {
        for (outline.segments) |segment| try testing.expect(segment.isLine());
    }
    for (drawing.outlines[3].segments) |segment| {
        try testing.expectApproxEqAbs(@as(f64, 1), (segment.to[0] * segment.to[0]) / 100 + ((segment.to[1] + 50) * (segment.to[1] + 50)) / 25, 1e-3);
    }
    try testing.expectApproxEqAbs(@as(f64, 8) * std.math.pi, area(drawing.outlines[4]), 1e-3);
}

test "SVG read: a filled open subpath is closed for its fill, an unfilled one is a stroke and left out" {
    var drawing = try read(MM ++ "<path d=\"M0 0L10 0L10 10\"/><path d=\"M20 0L30 0L30 10\" fill=\"none\"/>" ++
        "<g style=\"fill:none\"><path d=\"M40 0L50 0L50 10Z\"/><polyline points=\"60,0 70,0 70,10\"/></g></svg>");
    defer drawing.deinit();
    // The filled triangle, and the closed one in the unfilled group
    try testing.expectEqual(@as(usize, 2), drawing.outlines.len);
    try testing.expectApproxEqAbs(@as(f64, 50), area(drawing.outlines[0]), 1e-9);
    try expectPoint(.{ 40, 0 }, drawing.outlines[1].start);
}

test "SVG read: what isn't drawn is left out" {
    var drawing = try read("<?xml version=\"1.0\"?>\n<!DOCTYPE svg [ <!ENTITY a \"b\"> ]>\n<!-- a <rect> in a comment -->\n" ++ MM ++
        "<sodipodi:namedview/><defs><rect width=\"5\" height=\"5\"/></defs><title>t</title><text x=\"0\">hi</text><line x1=\"0\" y1=\"0\" x2=\"5\" y2=\"5\"/>" ++
        "<rect width=\"5\" height=\"5\" display=\"none\"/><g style=\"display: none\"><rect width=\"5\" height=\"5\"/></g><![CDATA[<rect/>]]>" ++
        "<rect width=\"7\" height=\"7\"/></svg>");
    defer drawing.deinit();
    try testing.expectEqual(@as(usize, 1), drawing.outlines.len);
    try testing.expectApproxEqAbs(@as(f64, 49), area(drawing.outlines[0]), 1e-9);
}

test "SVG read: what can't be read says why and where" {
    try expectRefused("<html></html>", "line 1: a <html> comes before the <svg> element");
    try expectRefused("", "it has no <svg> element");
    try expectRefused(MM ++ "<use href=\"#a\"/></svg>", "line 1: a <use> isn't read yet: unlink the clone (Inkscape's Edit > Clone > Unlink) first");
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
