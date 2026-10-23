const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");
const dxf_exporter = @import("dxf.zig");
const bezier = @import("../../core/bezier.zig");

fn exportDxf(source: []const u8) ![]const u8 {
    return api.buildModel(testing.allocator, testing.io, source, .{ .format = .dxf });
}

/// A DXF read back as its group code and value pairs.
const Pair = struct { code: u16, value: []const u8 };

fn readPairs(dxf: []const u8) !std.ArrayList(Pair) {
    var pairs: std.ArrayList(Pair) = .empty;
    errdefer pairs.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, dxf, '\n');
    while (lines.next()) |code_line| {
        if (code_line.len == 0) break;
        const value = lines.next() orelse return error.OddLines;
        try pairs.append(testing.allocator, .{ .code = try std.fmt.parseInt(u16, std.mem.trim(u8, code_line, " "), 10), .value = value });
    }
    return pairs;
}

/// The value after `$name` in the header's `9` group.
fn headerValue(pairs: []const Pair, name: []const u8) ?[]const u8 {
    for (pairs, 0..) |p, i| {
        if (p.code == 9 and std.mem.eql(u8, p.value, name)) return pairs[i + 1].value;
    }
    return null;
}

/// One closed polyline of the file, as read.
const Polyline = struct { layer: []const u8, points: std.ArrayList([2]f64) };

fn polylines(pairs: []const Pair) !std.ArrayList(Polyline) {
    var found: std.ArrayList(Polyline) = .empty;
    errdefer {
        for (found.items) |*p| p.points.deinit(testing.allocator);
        found.deinit(testing.allocator);
    }
    var i: usize = 0;
    while (i < pairs.len) : (i += 1) {
        if (!(pairs[i].code == 0 and std.mem.eql(u8, pairs[i].value, "LWPOLYLINE"))) continue;
        var line: Polyline = .{ .layer = "", .points = .empty };
        errdefer line.points.deinit(testing.allocator);
        var count: ?usize = null;
        var closed = false;
        i += 1;
        while (i < pairs.len and pairs[i].code != 0) : (i += 1) {
            switch (pairs[i].code) {
                8 => line.layer = pairs[i].value,
                90 => count = try std.fmt.parseInt(usize, pairs[i].value, 10),
                70 => closed = std.mem.eql(u8, pairs[i].value, "1"),
                10 => {
                    try testing.expectEqual(@as(u16, 20), pairs[i + 1].code);
                    try line.points.append(testing.allocator, .{ try std.fmt.parseFloat(f64, pairs[i].value), try std.fmt.parseFloat(f64, pairs[i + 1].value) });
                    i += 1;
                },
                else => {},
            }
        }
        i -= 1;
        try testing.expect(closed);
        try testing.expectEqual(count.?, line.points.items.len);
        try found.append(testing.allocator, line);
    }
    return found;
}

fn freePolylines(lines: *std.ArrayList(Polyline)) void {
    for (lines.items) |*p| p.points.deinit(testing.allocator);
    lines.deinit(testing.allocator);
}

test "DXF: a sketch is a closed LWPOLYLINE in millimetres, Y up, within the header's extents" {
    const dxf = try exportDxf("square(10, 5).translate(x: 1)");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    try testing.expectEqualStrings("AC1018", headerValue(pairs.items, "$ACADVER").?);
    try testing.expectEqualStrings("4", headerValue(pairs.items, "$INSUNITS").?);
    try testing.expectEqualStrings("1", headerValue(pairs.items, "$EXTMIN").?);
    try testing.expectEqualStrings("11", headerValue(pairs.items, "$EXTMAX").?);
    try testing.expectEqualStrings("EOF", pairs.items[pairs.items.len - 1].value);

    var lines = try polylines(pairs.items);
    defer freePolylines(&lines);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectEqualStrings("0", lines.items[0].layer);
    try testing.expectEqual(@as(usize, 4), lines.items[0].points.items.len);
    var max_y: f64 = 0;
    for (lines.items[0].points.items) |p| max_y = @max(max_y, p[1]);
    try testing.expectEqual(@as(f64, 5), max_y); // not turned over, as SVG's is
}

test "DXF: a hole is a polyline of its own, a name a layer in the shape's colour, a Solid its projection" {
    const dxf = try exportDxf("plate = (square(20, center: true) - circle(r: 2, segments: 8)).named(\"plate/1\").material(color: \"#FF2000\")\n[plate, cube(4).translate(x: 30).named(\"lid\")]");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    // The plate and the lid; the plate's hole is a CIRCLE
    var lines = try polylines(pairs.items);
    defer freePolylines(&lines);
    try testing.expectEqual(@as(usize, 2), lines.items.len);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dxf, "\nCIRCLE\n"));
    // The forbidden `/` becomes `_`
    try testing.expectEqualStrings("plate_1", lines.items[0].layer);
    try testing.expectEqualStrings("lid", lines.items[1].layer);
    try testing.expectEqual(@as(usize, 4), lines.items[1].points.items.len);
    // The layer table: `0`, then each name once, the plate's with its true colour and the
    // nearest index colour (red)
    var layers: usize = 0;
    var plate_color: ?[]const u8 = null;
    var plate_true: ?[]const u8 = null;
    for (pairs.items, 0..) |p, i| {
        if (p.code == 0 and std.mem.eql(u8, p.value, "LAYER")) {
            layers += 1;
            var j = i + 1;
            var is_plate = false;
            while (j < pairs.items.len and pairs.items[j].code != 0) : (j += 1) {
                if (pairs.items[j].code == 2) is_plate = std.mem.eql(u8, pairs.items[j].value, "plate_1");
                if (is_plate and pairs.items[j].code == 62) plate_color = pairs.items[j].value;
                if (is_plate and pairs.items[j].code == 420) plate_true = pairs.items[j].value;
            }
        }
    }
    try testing.expectEqual(@as(usize, 3), layers);
    try testing.expectEqualStrings("1", plate_color.?);
    try testing.expectEqualStrings("16719872", plate_true.?); // 0xFF2000
}

test "DXF: a half circle is a bulge of 1, a rounded corner a bulge of its angle, a line none" {
    const dxf = try exportDxf("[circle(r: 5, segments: 8) & square(10, 5).translate(x: -5), square(20, round_r: 4, segments: 16).translate(x: 20)]");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    var bulges: std.ArrayList([]const u8) = .empty;
    defer bulges.deinit(testing.allocator);
    for (pairs.items) |p| {
        if (p.code == 42) try bulges.append(testing.allocator, p.value);
    }
    // The half disc's half turn, then the plate's four quarter turns (tan 22.5°)
    try testing.expectEqual(@as(usize, 5), bulges.items.len);
    try testing.expectEqualStrings("1", bulges.items[0]);
    for (bulges.items[1..]) |b| try testing.expectApproxEqAbs(@tan(std.math.pi / 8.0), try std.fmt.parseFloat(f64, b), 1e-12);
    var lines = try polylines(pairs.items);
    defer freePolylines(&lines);
    try testing.expectEqual(@as(usize, 2), lines.items[0].points.items.len); // the arc and the chord
    try testing.expectEqual(@as(usize, 8), lines.items[1].points.items.len);
    // A hole's bulges are negative: it runs clockwise
    const holed = try exportDxf("square(20, center: true) - square(6, round_r: 2, center: true)");
    defer testing.allocator.free(holed);
    try testing.expect(std.mem.find(u8, holed, "\n42\n-") != null);
}

test "DXF: a Path is an open polyline with its end as a vertex, its arcs as bulges" {
    const dxf = try exportDxf("line([0, 0], [10, 0]) + arc(center: [10, 5], r: 5, start: -90, sweep: 180) + polyline([[10, 10], [0, 10]])");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    // Open (70 = 0) with 4 vertices: the start, the arc's start and end, and the end
    var open = false;
    var count: ?[]const u8 = null;
    for (pairs.items, 0..) |p, i| {
        if (p.code == 0 and std.mem.eql(u8, p.value, "LWPOLYLINE")) {
            var j = i + 1;
            while (pairs.items[j].code != 0) : (j += 1) {
                if (pairs.items[j].code == 70) open = std.mem.eql(u8, pairs.items[j].value, "0");
                if (pairs.items[j].code == 90) count = pairs.items[j].value;
            }
        }
    }
    try testing.expect(open);
    try testing.expectEqualStrings("4", count.?);
    try testing.expect(std.mem.find(u8, dxf, "\n42\n1\n") != null); // the half turn
}

test "DXF: an outline that is one circle is a CIRCLE entity" {
    const dxf = try exportDxf("[circle(r: 5, segments: 8).named(\"hole\"), square(20, center: true).translate(x: 30) - circle(r: 3).translate(x: 30)]");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    var circles: usize = 0;
    var radius: ?[]const u8 = null;
    var layer: ?[]const u8 = null;
    for (pairs.items, 0..) |p, i| {
        if (p.code == 0 and std.mem.eql(u8, p.value, "CIRCLE")) {
            circles += 1;
            var j = i + 1;
            while (pairs.items[j].code != 0) : (j += 1) {
                if (circles == 1 and pairs.items[j].code == 40) radius = pairs.items[j].value;
                if (circles == 1 and pairs.items[j].code == 8) layer = pairs.items[j].value;
            }
        }
    }
    // The named circle, and the plate's hole; the plate itself is a polyline
    try testing.expectEqual(@as(usize, 2), circles);
    try testing.expectEqualStrings("5", radius.?);
    try testing.expectEqualStrings("hole", layer.?);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dxf, "\nLWPOLYLINE\n"));
}

/// The splines of the file: each one's layer, degree, knots and control points.
const Spline = struct { layer: []const u8, degree: usize, knots: usize, controls: std.ArrayList([2]f64) };

fn splines(pairs: []const Pair) !std.ArrayList(Spline) {
    var found: std.ArrayList(Spline) = .empty;
    errdefer {
        for (found.items) |*s| s.controls.deinit(testing.allocator);
        found.deinit(testing.allocator);
    }
    var i: usize = 0;
    while (i < pairs.len) : (i += 1) {
        if (!(pairs[i].code == 0 and std.mem.eql(u8, pairs[i].value, "SPLINE"))) continue;
        var spline: Spline = .{ .layer = "", .degree = 0, .knots = 0, .controls = .empty };
        errdefer spline.controls.deinit(testing.allocator);
        var declared_controls: usize = 0;
        var declared_knots: usize = 0;
        i += 1;
        while (i < pairs.len and pairs[i].code != 0) : (i += 1) {
            switch (pairs[i].code) {
                8 => spline.layer = pairs[i].value,
                71 => spline.degree = try std.fmt.parseInt(usize, pairs[i].value, 10),
                72 => declared_knots = try std.fmt.parseInt(usize, pairs[i].value, 10),
                73 => declared_controls = try std.fmt.parseInt(usize, pairs[i].value, 10),
                40 => spline.knots += 1,
                10 => {
                    try testing.expectEqual(@as(u16, 20), pairs[i + 1].code);
                    try spline.controls.append(testing.allocator, .{ try std.fmt.parseFloat(f64, pairs[i].value), try std.fmt.parseFloat(f64, pairs[i + 1].value) });
                    i += 1;
                },
                else => {},
            }
        }
        i -= 1;
        try testing.expectEqual(declared_knots, spline.knots);
        try testing.expectEqual(declared_controls, spline.controls.items.len);
        try found.append(testing.allocator, spline);
    }
    return found;
}

fn freeSplines(found: *std.ArrayList(Spline)) void {
    for (found.items) |*s| s.controls.deinit(testing.allocator);
    found.deinit(testing.allocator);
}

test "DXF: an outline with a glyph's curve is a closed cubic SPLINE on its layer, an arc in it quarter-turn pieces" {
    const dxf = try exportDxf("[text(\"O\", 10).named(\"o\"), text(\"O\", 10).translate(x: 20) + circle(r: 2).translate(x: 21, y: 4), square(5).translate(y: 20)]");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    var found = try splines(pairs.items);
    defer freeSplines(&found);
    // The O's two contours and the union's two; the square stays a polyline
    try testing.expectEqual(@as(usize, 4), found.items.len);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, dxf, "\nLWPOLYLINE\n"));
    try testing.expectEqualStrings("o", found.items[0].layer);
    try testing.expectEqualStrings("0", found.items[2].layer);
    for (found.items) |spline| {
        try testing.expectEqual(@as(usize, 3), spline.degree);
        // Cubic pieces: 3 controls per piece after the start, a knot per control and 4 more
        const controls = spline.controls.items;
        try testing.expectEqual(@as(usize, 1), controls.len % 3);
        try testing.expectEqual(controls.len + 4, spline.knots);
        try testing.expectEqual(controls[0], controls[controls.len - 1]);
    }
}

test "DXF: an arc's cubic pieces stray from it by the bound, and are as few as keep within the tolerance" {
    // The usual cubic for a quarter of the unit circle, sampled: its worst radial error is
    // the bound, 2.7e-4
    const k = 4.0 / 3.0 * @tan(std.math.pi / 8.0);
    const cubic = bezier.Cubic{ .c1 = .{ 1, k }, .c2 = .{ k, 1 } };
    var worst: f64 = 0;
    for (0..10_001) |i| {
        const p = bezier.pointOn(.{ 1, 0 }, cubic, .{ 0, 1 }, @as(f64, @floatFromInt(i)) / 10_000);
        worst = @max(worst, @abs(std.math.hypot(p[0], p[1]) - 1));
    }
    try testing.expectApproxEqRel(worst, dxf_exporter.cubicArcError(std.math.pi / 2.0, 1), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 2.7253e-4), dxf_exporter.cubicArcError(std.math.pi / 2.0, 1), 1e-7);

    // The fewest: one fewer would stray past the tolerance
    const n = dxf_exporter.arcPieces(2 * std.math.pi, 2, 1e-5);
    const turn = 2 * std.math.pi;
    try testing.expect(dxf_exporter.cubicArcError(turn / @as(f64, @floatFromInt(n)), 2) <= 1e-5);
    try testing.expect(dxf_exporter.cubicArcError(turn / @as(f64, @floatFromInt(n - 1)), 2) > 1e-5);
    // Never more than a quarter turn a piece, however coarse the tolerance, and capped
    try testing.expectEqual(@as(usize, 4), dxf_exporter.arcPieces(turn, 1, 1));
    try testing.expectEqual(@as(usize, 1), dxf_exporter.arcPieces(0.1, 1, 1));
    try testing.expectEqual(@as(usize, 2048), dxf_exporter.arcPieces(turn, 1, 1e-300));
}

test "DXF: a spline's arcs follow the shape's own tolerance" {
    // They were quarter turns whatever the tolerance: 5e-4 mm off a 2 mm circle, fifty
    // times the default tolerance
    const model = "[text(\"O\", 10) + circle(r: 2).translate(x: 1, y: 4)]";
    var counts: [2]usize = undefined;
    for ([_][]const u8{ "", "CAD.config(tolerance: 0.01)\n" }, &counts) |config, *count| {
        const source = try std.mem.concat(testing.allocator, u8, &.{ config, model });
        defer testing.allocator.free(source);
        const out = try exportDxf(source);
        defer testing.allocator.free(out);
        var pairs = try readPairs(out);
        defer pairs.deinit(testing.allocator);
        var found = try splines(pairs.items);
        defer freeSplines(&found);
        count.* = 0;
        for (found.items) |spline| count.* += spline.controls.items.len;
    }
    try testing.expect(counts[0] > counts[1]);
}

test "DXF: one layer per name, the shapes of a name on it, names spelt alike kept apart" {
    // a:b and a/b, both a_b in DXF's spelling, were two layers of one name
    const dxf = try exportDxf("[square(1).named(\"plate\"), square(1).translate(x: 3).named(\"plate\"), square(1).translate(x: 6).named(\"a:b\"), square(1).translate(x: 9).named(\"a/b\"), square(1).translate(x: 12).named(\"0\")]");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    var table: std.ArrayList([]const u8) = .empty;
    defer table.deinit(testing.allocator);
    for (pairs.items, 0..) |p, i| {
        if (p.code == 0 and std.mem.eql(u8, p.value, "LAYER")) {
            var j = i + 1;
            while (pairs.items[j].code != 2) j += 1;
            try table.append(testing.allocator, pairs.items[j].value);
        }
    }
    // `0`, then a layer per name: a shape named "0" isn't put with the unnamed ones
    const expected = [_][]const u8{ "0", "plate", "a_b", "a_b_2", "0_2" };
    try testing.expectEqual(expected.len, table.items.len);
    for (expected, table.items) |want, got| try testing.expectEqualStrings(want, got);
    var lines = try polylines(pairs.items);
    defer freePolylines(&lines);
    const on = [_][]const u8{ "plate", "plate", "a_b", "a_b_2", "0_2" };
    for (on, lines.items) |want, line| try testing.expectEqualStrings(want, line.layer);
}

test "DXF: every handle is given out once" {
    const dxf = try exportDxf("[square(1), square(1).translate(x: 3).named(\"a\")]");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    var seed: ?usize = null;
    for (pairs.items, 0..) |p, i| {
        if (p.code == 9 and std.mem.eql(u8, p.value, "$HANDSEED")) seed = try std.fmt.parseInt(usize, pairs.items[i + 1].value, 16);
        if (p.code != 5 or (i > 0 and pairs.items[i - 1].code == 9)) continue;
        try testing.expect(!seen.contains(p.value));
        try seen.put(testing.allocator, p.value, {});
        try testing.expect(try std.fmt.parseInt(usize, p.value, 16) < seed.?);
    }
    try testing.expect(seen.count() >= 5); // two tables, two layers, two polylines
}

test "DXF: a drawing written and read back has its outlines, arcs as arcs, a glyph's curves as its cubics" {
    const dxf_read = @import("dxf_read.zig");
    const path = @import("../../core/path.zig");
    const dxf = try exportDxf("[square(20, round_r: 4, segments: 16) - circle(r: 3, segments: 16).translate(x: 10, y: 10), text(\"O\", 10).translate(x: 30)]");
    defer testing.allocator.free(dxf);
    var diag: dxf_read.Diagnostic = .{};
    var drawing = dxf_read.read(testing.allocator, dxf, .{ .tolerance = 1e-6 }, &diag) catch |err| {
        std.debug.print("dxf: {s}\n", .{diag.message()});
        return err;
    };
    defer drawing.deinit();
    // The plate, its hole, and the O's two outlines
    try testing.expectEqual(@as(usize, 4), drawing.outlines.len);
    var corners: usize = 0;
    for (drawing.outlines[0].segments) |segment| {
        const arc = segment.arc orelse continue;
        try testing.expectApproxEqAbs(@as(f64, 4), arc.radius, 1e-9);
        corners += 1;
    }
    try testing.expectEqual(@as(usize, 4), corners);
    // The hole: the exact circle, as the CIRCLE written for it
    const hole = drawing.outlines[1];
    try testing.expectEqual(@as(usize, 2), hole.segments.len);
    try testing.expectApproxEqAbs(@as(f64, 3), hole.segments[0].arc.?.radius, 1e-9);
    try testing.expectApproxEqAbs(9 * std.math.pi, @abs(path.signedArea(hole.start, hole.segments)), 1e-9);
    // The glyph's outlines: SPLINEs, read back as their cubics, and the lines written
    // among them (straight cubics) as lines
    for (drawing.outlines[2..]) |outline| {
        var cubics: usize = 0;
        for (outline.segments) |segment| {
            try testing.expect(segment.arc == null);
            if (segment.cubic != null) cubics += 1;
        }
        try testing.expect(cubics >= 4);
    }
}
