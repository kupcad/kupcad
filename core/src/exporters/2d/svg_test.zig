const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");

fn exportSvg(source: []const u8) ![]const u8 {
    return api.buildModel(testing.allocator, testing.io, source, .{ .format = .svg });
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
