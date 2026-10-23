const std = @import("std");
const testing = std.testing;
const api = @import("../../api.zig");

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
    var lines = try polylines(pairs.items);
    defer freePolylines(&lines);
    try testing.expectEqual(@as(usize, 3), lines.items.len);
    // The forbidden `/` becomes `_`
    try testing.expectEqualStrings("plate_1", lines.items[0].layer);
    try testing.expectEqualStrings("plate_1", lines.items[1].layer);
    try testing.expectEqualStrings("lid", lines.items[2].layer);
    try testing.expectEqual(@as(usize, 4), lines.items[2].points.items.len);
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

test "DXF: a circle is two bulged vertices, a rounded corner a bulge of its angle, a line none" {
    const dxf = try exportDxf("[circle(r: 5, segments: 8), square(20, round_r: 4, segments: 16).translate(x: 20)]");
    defer testing.allocator.free(dxf);
    var pairs = try readPairs(dxf);
    defer pairs.deinit(testing.allocator);
    var bulges: std.ArrayList([]const u8) = .empty;
    defer bulges.deinit(testing.allocator);
    for (pairs.items) |p| {
        if (p.code == 42) try bulges.append(testing.allocator, p.value);
    }
    // The circle's two half turns, then the plate's four quarter turns (tan 22.5°)
    try testing.expectEqual(@as(usize, 6), bulges.items.len);
    try testing.expectEqualStrings("1", bulges.items[0]);
    try testing.expectEqualStrings("1", bulges.items[1]);
    for (bulges.items[2..]) |b| try testing.expectApproxEqAbs(@tan(std.math.pi / 8.0), try std.fmt.parseFloat(f64, b), 1e-12);
    var lines = try polylines(pairs.items);
    defer freePolylines(&lines);
    try testing.expectEqual(@as(usize, 2), lines.items[0].points.items.len);
    try testing.expectEqual(@as(usize, 8), lines.items[1].points.items.len);
    // A hole's bulges are negative: it runs clockwise
    const holed = try exportDxf("square(20, center: true) - circle(r: 3, segments: 8)");
    defer testing.allocator.free(holed);
    try testing.expect(std.mem.find(u8, holed, "\n42\n-1\n") != null);
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
