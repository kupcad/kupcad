const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");

fn exportSvg(source: []const u8) ![]const u8 {
    return api.buildModel(testing.allocator, testing.io, source, .{ .format = .svg });
}

test "SVG: every named shape's id is a valid one of its own, a repeated or clashing name numbered" {
    // Two shapes named alike, or names spelt alike as ids (a:b and a/b), got the same id,
    // which XML forbids
    const svg = try exportSvg("[square(1).named(\"plate\"), square(1).translate(x: 3).named(\"plate\"), square(1).translate(x: 6).named(\"a:b\"), square(1).translate(x: 9).named(\"a/b\"), square(1).translate(x: 12).named(\"1<&>\")]");
    defer testing.allocator.free(svg);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(testing.allocator);
    var rest = svg;
    while (std.mem.find(u8, rest, " id=\"")) |at| {
        rest = rest[at + " id=\"".len ..];
        try ids.append(testing.allocator, rest[0..std.mem.findScalar(u8, rest, '"').?]);
    }
    const expected = [_][]const u8{ "plate", "plate_2", "a_b", "a_b_2", "_1___" };
    try testing.expectEqual(expected.len, ids.items.len);
    for (expected, ids.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "SVG: the outline is 0.1 mm wide unless the export asks for another width" {
    var vm = try @import("../../test_support.zig").initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try @import("../../test_support.zig").runOn(&vm, "square(10)"));
    const plain = try api.exportModelFromVm(testing.allocator, &vm, .svg, .{});
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.find(u8, plain, "stroke-width=\"0.1\"") != null);
    const hairline = try api.exportModelFromVm(testing.allocator, &vm, .svg, .{ .stroke_width = 0.01 });
    defer testing.allocator.free(hairline);
    try testing.expect(std.mem.find(u8, hairline, "stroke-width=\"0.01\"") != null);
}

/// Checks the `n`th path is one closed contour through `points`, in some order and
/// starting anywhere (the kernel's choice).
fn expectClosedThrough(svg: []const u8, n: usize, points: []const [2]f64) !void {
    const d = pathData(svg, n) orelse return error.NoPath;
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, d, "M "));
    try testing.expect(std.mem.endsWith(u8, d, " Z"));
    var seen: usize = 0;
    var corners = std.mem.tokenizeAny(u8, d[0 .. d.len - " Z".len], "ML");
    while (corners.next()) |corner| : (seen += 1) {
        var coords = std.mem.tokenizeScalar(u8, corner, ' ');
        const x = try std.fmt.parseFloat(f64, coords.next().?);
        const y = try std.fmt.parseFloat(f64, coords.next().?);
        for (points) |p| {
            if (p[0] == x and p[1] == y) break;
        } else {
            std.debug.print("unexpected point {d} {d} in {s}\n", .{ x, y, d });
            return error.UnexpectedPoint;
        }
    }
    try testing.expectEqual(points.len, seen);
}

/// The `d` attribute of the `n`th path (from 0), or null when there is none.
fn pathData(svg: []const u8, n: usize) ?[]const u8 {
    var rest = svg;
    var i: usize = 0;
    while (std.mem.find(u8, rest, "<path")) |at| : (i += 1) {
        rest = rest[at + "<path".len ..];
        if (i < n) continue;
        const d = std.mem.find(u8, rest, " d=\"").? + " d=\"".len;
        return rest[d .. d + std.mem.findScalar(u8, rest[d..], '"').?];
    }
    return null;
}

test "SVG: a sketch is a path in millimetres, Y turned over, in a viewBox of its bounds" {
    const svg = try exportSvg("square(10, 5)");
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.startsWith(u8, svg, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"5mm\" viewBox=\"0 -5 10 5\">\n"));
    // Each y negated (no `-0`)
    try expectClosedThrough(svg, 0, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, -5 }, .{ 0, -5 } });
    try testing.expect(pathData(svg, 1) == null);
    try testing.expect(std.mem.find(u8, svg, "fill=\"#CCCCCC\" fill-rule=\"evenodd\" stroke=\"#000000\" stroke-width=\"0.1\"") != null);
    try testing.expect(std.mem.find(u8, svg, "-0 ") == null and std.mem.find(u8, svg, "-0\"") == null);
    try testing.expect(std.mem.endsWith(u8, svg, "</svg>\n"));
}

test "SVG: a hole is a second subpath, a name the path's id, a colour its fill" {
    const svg = try exportSvg("(square(20, center: true) - square(4, center: true)).named(\"plate 1\").material(color: \"#FF0000\", alpha: 0.5)");
    defer testing.allocator.free(svg);
    const d = pathData(svg, 0).?;
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, d, "M "));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, d, " Z"));
    // The id is an XML name: the space becomes `_`
    try testing.expect(std.mem.find(u8, svg, "<path id=\"plate_1\" fill=\"#FF0000\" fill-opacity=\"0.5\"") != null);
}

test "SVG: a Solid is drawn as its projection onto XY, named after its part, beside the Sketches" {
    // A 3D model exports to a 2D format as its silhouette; a Sketch alone failed, and
    // nothing drew a Solid.
    const svg = try exportSvg("lid = cube(4).named(\"lid\")\n[circle(r: 2, segments: 4).translate(x: 20), lid, lid.translate(z: 10)]");
    defer testing.allocator.free(svg);
    errdefer std.debug.print("svg:\n{s}\n", .{svg});
    // The sketch first, then the two copies of the lid, both the same square (the
    // translate along z changes nothing in the drawing)
    const lid = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, -4 }, .{ 0, -4 } };
    try expectClosedThrough(svg, 1, &lid);
    try expectClosedThrough(svg, 2, &lid);
    try testing.expect(pathData(svg, 3) == null);
    try testing.expect(std.mem.find(u8, svg, "<path id=\"lid\" ") != null);
    try testing.expect(std.mem.find(u8, svg, "<path id=\"lid_2\" ") != null);
    // The diamond reaches y = 2 and the lid y = 4, down to the diamond's -2
    try testing.expect(std.mem.find(u8, svg, "width=\"22mm\" height=\"6mm\" viewBox=\"0 -4 22 6\"") != null);
}

/// The centre of the arc an SVG `A` command describes from `from` to `to` (both in SVG's
/// coordinates), per the SVG specification's conversion from endpoints to centre.
fn svgArcCenter(from: [2]f64, to: [2]f64, r: f64, large: bool, sweep: bool) [2]f64 {
    const dx = (from[0] - to[0]) / 2;
    const dy = (from[1] - to[1]) / 2;
    const rr = r * r;
    const root = @sqrt(@max(0, (rr * rr - rr * dy * dy - rr * dx * dx) / (rr * dy * dy + rr * dx * dx)));
    const sign: f64 = if (large == sweep) -1 else 1;
    const cx1 = sign * root * (r * dy / r);
    const cy1 = sign * root * (-(r * dx) / r);
    return .{ cx1 + (from[0] + to[0]) / 2, cy1 + (from[1] + to[1]) / 2 };
}

test "SVG: a circle is two arcs of its exact radius, a rounded corner an arc, a hole's arcs run the other way" {
    // The kernel's chords were written as lines
    const circle = try exportSvg("circle(r: 5, segments: 8).translate(x: 10)");
    defer testing.allocator.free(circle);
    const d = pathData(circle, 0).?;
    try testing.expectEqualStrings("M 15 0 A 5 5 0 0 0 5 0 A 5 5 0 0 0 15 0 Z", d);
    try testing.expect(std.mem.find(u8, circle, "viewBox=\"5 -5 10 10\"") != null);

    // Four quarter arcs between four lines; each arc bulges away from the plate's middle
    const plate = try exportSvg("square(20, round_r: 4, segments: 16)");
    defer testing.allocator.free(plate);
    const pd = pathData(plate, 0).?;
    errdefer std.debug.print("plate: {s}\n", .{pd});
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, pd, " A "));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, pd, " L "));
    // The bottom-right corner's arc, from (16, 0) up to (20, 4) in the sketch, (16, 0) to
    // (20, -4) on the page, a quarter turn; its centre must be (16, -4), the corner's
    const arc = " A 4 4 0 0 0 20 -4";
    const at = std.mem.find(u8, pd, arc).?;
    try testing.expect(std.mem.endsWith(u8, pd[0..at], " 16 0") or std.mem.endsWith(u8, pd[0..at], "M 16 0"));
    const center = svgArcCenter(.{ 16, 0 }, .{ 20, -4 }, 4, false, false);
    try testing.expectApproxEqAbs(@as(f64, 16), center[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -4), center[1], 1e-9);

    // A hole runs clockwise in the sketch, so its arcs sweep the other way
    const holed = try exportSvg("square(20, center: true) - circle(r: 3, segments: 8)");
    defer testing.allocator.free(holed);
    const hd = pathData(holed, 0).?;
    errdefer std.debug.print("holed: {s}\n", .{hd});
    try testing.expect(std.mem.find(u8, hd, " A 3 3 0 0 1 ") != null);
    try testing.expect(std.mem.find(u8, hd, " A 3 3 0 0 0 ") == null);
}

test "SVG: a text's glyphs are cubic curves, through an uneven scale too, beside an arc" {
    const svg = try exportSvg("[text(\"O\", 10).scale(2, 1), text(\"O\", 10).translate(x: 20) + circle(r: 2).translate(x: 21, y: 4)]");
    defer testing.allocator.free(svg);
    errdefer std.debug.print("svg:\n{s}\n", .{svg});
    const stretched = pathData(svg, 0).?;
    try testing.expect(std.mem.count(u8, stretched, " C ") >= 8);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, stretched, " A "));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, stretched, " Z"));
    const mixed = pathData(svg, 1).?;
    try testing.expect(std.mem.count(u8, mixed, " C ") >= 4);
    try testing.expect(std.mem.count(u8, mixed, " A 2 2 ") >= 1);
}

test "SVG: a cylinder's projection and slice are its circle, a tilted one's a polyline" {
    const svg = try exportSvg("c = cylinder(r: 5, h: 10, segments: 8)\n[c.project, c.slice(5).translate(x: 20), c.rotate(x: 90).translate(x: 40).project]");
    defer testing.allocator.free(svg);
    errdefer std.debug.print("svg:\n{s}\n", .{svg});
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, pathData(svg, 0).?, " A 5 5 "));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, pathData(svg, 1).?, " A 5 5 "));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, pathData(svg, 2).?, " A "));
}

test "SVG: a Path is an open, unfilled path with its arcs exact, a closed one's arcs too" {
    // `end` and `from` are keywords, hence `sweep:` and `start:`/`to:`
    const source = "p = (line([0, 0], [10, 0]) + arc(center: [10, 5], r: 5, start: -90, sweep: 180) + polyline([[10, 10], [0, 10]])).named(\"bracket\").material(color: \"#FF0000\")\n[p, p.close.translate(y: 20)]";
    const svg = try exportSvg(source);
    defer testing.allocator.free(svg);
    errdefer std.debug.print("svg:\n{s}\n", .{svg});
    // The sketches come first, then the paths. The path: no Z, no fill, stroked in its
    // colour, the arc an A of radius 5
    try testing.expectEqualStrings("M 0 0 L 10 0 A 5 5 0 0 0 10 -10 L 0 -10", pathData(svg, 1).?);
    try testing.expect(std.mem.find(u8, svg, "<path id=\"bracket\" fill=\"none\" fill-rule=\"evenodd\" stroke=\"#FF0000\"") != null);
    // Closed, the same outline is filled and its arc stays an arc
    const closed = pathData(svg, 0).?;
    try testing.expect(std.mem.endsWith(u8, closed, " Z"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, closed, " A 5 5 0 0 0 "));
    try testing.expect(std.mem.find(u8, svg, "viewBox=\"0 -30 15 30\"") != null);
}

test "SVG: a polygon's rounded corners and a Path's fillets are arcs, a concave corner's the other way" {
    const source = "[polygon([[0, 0], [20, 0], [20, 5], [5, 5], [5, 20], [0, 20]], round_r: 2), polyline([[0, 0], [10, 0], [10, 10]]).named(\"hook\").fillet(3).translate(x: 30)]";
    const svg = try exportSvg(source);
    defer testing.allocator.free(svg);
    errdefer std.debug.print("svg:\n{s}\n", .{svg});
    // Five outer corners turn left in the sketch (sweep 0 on the page, Y turned over), the
    // inner one right
    const outline = pathData(svg, 0).?;
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, outline, " A 2 2 0 0 0 "));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, outline, " A 2 2 0 0 1 "));
    // The open path keeps its name: along, a quarter arc of radius 3, up
    try testing.expectEqualStrings("M 30 0 L 37 0 A 3 3 0 0 0 40 -3 L 40 -10", pathData(svg, 1).?);
    try testing.expect(std.mem.find(u8, svg, "<path id=\"hook\"") != null);
}

test "SVG: what can't be drawn is refused with a message" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "[]", .message = "GeometryError: the model holds no shape: nothing to draw as svg" },
        .{ .source = "circle(r: 1) - circle(r: 2)", .message = "GeometryError: the model's shapes have no outline (empty sketches): nothing to draw as svg" },
        .{ .source = "CAD.config(engine: :brep)\nsquare(1)", .message = "NotImplementedError: the brep engine can't read a sketch's outlines (SVG and DXF export) yet; build this part with engine: :manifold" },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var diag: api.BuildDiagnostic = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.RuntimeError, api.buildModel(testing.allocator, testing.io, case.source, .{ .format = .svg, .diagnostic = &diag }));
        try testing.expectEqualStrings(case.message, diag.message.?);
    }
}
