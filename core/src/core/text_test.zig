const std = @import("std");
const testing = std.testing;
const tatfi = @import("tatfi");
const text = @import("text.zig");
const bezier = @import("bezier.zig");
const Kerning = @import("kerning.zig").Kerning;

test "Text Engine: Successfully parses all embedded font families allocation-free" {
    inline for (std.enums.values(text.FontKey)) |key| {
        const face = try text.getFace(key);

        const units_per_em = face.units_per_em();
        const ascender = face.ascender();
        const descender = face.descender();

        try testing.expect(units_per_em > 0);
        try testing.expect(ascender > 0);
        try testing.expect(descender < 0);
    }
}

test "Text Engine: a font is named by its own name or an alias, and an unknown name is none" {
    inline for (std.enums.values(text.FontKey)) |key| try testing.expectEqual(key, text.FontKey.fromString(key.name()).?);
    try testing.expectEqual(text.FontKey.sans, text.FontKey.fromString("default").?);
    try testing.expectEqual(text.FontKey.mono, text.FontKey.fromString("monospace").?);
    // It used to be sans, so a typo drew in the wrong font without a word
    try testing.expectEqual(@as(?text.FontKey, null), text.FontKey.fromString("unknown_font_family"));
    try testing.expectEqual(text.FontKey.sans_bold, text.FontKey.fromString("sans_bold").?);
    try testing.expectEqualStrings("\"sans\", \"sans-bold\", \"mono\", \"serif\" and \"stencil\"", text.FONT_LIST);
}

test "Text Engine: Extracts flat 2D polygons from text string and kerning" {
    const face = try text.getFace(.sans);

    var polygons = try text.extractText(testing.allocator, &face, "CAD", 10.0, 0.1, .left, .baseline);
    defer polygons.deinit(testing.allocator);

    // "CAD" is typically 5 closed contours (C, A + hole, D + hole); require
    // at least one per glyph to stay font-agnostic.
    try testing.expect(polygons.contours.items.len >= 3);

    const first_contour = polygons.contours.items[0];
    const last_contour = polygons.contours.items[polygons.contours.items.len - 1];

    // Each contour must have flattened into multiple point segments
    try testing.expect(first_contour.items.len > 10);

    // Ensure the cursor advanced properly. The last contour ('D') must have X-coordinates
    // physically further right than the first contour ('C').
    try testing.expect(last_contour.items[0][0] > first_contour.items[0][0]);
}

test "Text Engine: halign and valign offsets contours correctly" {
    const face = try text.getFace(.sans);
    const alloc = testing.allocator;

    // --- 1. Test Center / Center Alignment ---
    var poly_center = try text.extractText(alloc, &face, "KupCAD", 10.0, 0.1, .center, .center);
    defer poly_center.deinit(alloc);

    var cx_min: f64 = std.math.inf(f64);
    var cx_max: f64 = -std.math.inf(f64);
    var cy_min: f64 = std.math.inf(f64);
    var cy_max: f64 = -std.math.inf(f64);

    for (poly_center.contours.items) |c| {
        for (c.items) |pt| {
            if (pt[0] < cx_min) cx_min = pt[0];
            if (pt[0] > cx_max) cx_max = pt[0];
            if (pt[1] < cy_min) cy_min = pt[1];
            if (pt[1] > cy_max) cy_max = pt[1];
        }
    }

    // Midpoint should be extremely close to 0.0 for both axes
    try testing.expectApproxEqAbs(0.0, (cx_min + cx_max) / 2.0, 0.001);
    try testing.expectApproxEqAbs(0.0, (cy_min + cy_max) / 2.0, 0.001);

    // --- 2. Test Right / Top Alignment ---
    var poly_rt = try text.extractText(alloc, &face, "AlignMe", 10.0, 0.1, .right, .top);
    defer poly_rt.deinit(alloc);

    var rx_max: f64 = -std.math.inf(f64);
    var ry_max: f64 = -std.math.inf(f64);

    for (poly_rt.contours.items) |c| {
        for (c.items) |pt| {
            if (pt[0] > rx_max) rx_max = pt[0];
            if (pt[1] > ry_max) ry_max = pt[1];
        }
    }

    // Since it is aligned Right/Top, the maximum bounds must be exactly shifted to 0.0
    try testing.expectApproxEqAbs(0.0, rx_max, 0.001);
    try testing.expectApproxEqAbs(0.0, ry_max, 0.001);
}

test "Text Engine: each curve is kept with the run of points it became, and moves with the alignment" {
    const face = try text.getFace(.sans);
    var polygons = try text.extractText(testing.allocator, &face, "O", 10.0, 0.1, .center, .center);
    defer polygons.deinit(testing.allocator);
    try testing.expect(polygons.curves.items.len >= 4);
    for (polygons.curves.items) |curve| {
        try testing.expect(curve.contour < polygons.contours.items.len);
        const contour = polygons.contours.items[curve.contour].items;
        try testing.expect(curve.count >= 2 and curve.first + curve.count <= contour.len);
        // Every point of the run lies on the cubic (the flattener halves it, so each is at
        // a dyadic parameter a fine sampling hits)
        const p0 = contour[curve.first];
        const p3 = contour[curve.first + curve.count - 1];
        for (contour[curve.first..][0..curve.count]) |p| {
            var nearest: f64 = std.math.inf(f64);
            for (0..1025) |k| {
                const q = bezier.pointOn(p0, curve.cubic, p3, @as(f64, @floatFromInt(k)) / 1024);
                nearest = @min(nearest, std.math.hypot(q[0] - p[0], q[1] - p[1]));
            }
            try testing.expect(nearest < 1e-9);
        }
        // Centred: the controls lie about the origin with the glyph, not off to its right
        try testing.expect(@abs(curve.cubic.c1[0]) < 10 and @abs(curve.cubic.c1[1]) < 10);
    }
}

fn pointCount(polygons: *const text.TextPolygons) usize {
    var total: usize = 0;
    for (polygons.contours.items) |c| total += c.items.len;
    return total;
}

test "Text Engine: running out of memory fails the extraction instead of truncating a glyph" {
    const face = try text.getFace(.sans);
    var reference = try text.extractText(testing.allocator, &face, "CAD", 10.0, 0.1, .left, .baseline);
    defer reference.deinit(testing.allocator);

    // Fail each allocation in turn: the outline callbacks used to drop the points they
    // could not store and still return the (truncated) text.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var polygons = text.extractText(failing.allocator(), &face, "CAD", 10.0, 0.1, .left, .baseline) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer polygons.deinit(failing.allocator());
        try testing.expect(!failing.has_induced_failure);
        try testing.expectEqual(pointCount(&reference), pointCount(&polygons));
        break;
    }
}

test "Text: a String that isn't valid UTF-8 is an error, not an assertion" {
    const face = try text.getFace(.sans);
    try testing.expectError(error.InvalidUtf8, text.extractText(testing.allocator, &face, "A\xFFB", 10.0, 0.1, .left, .baseline));
}

test "Text: a character the font has no glyph for is an error, named by firstMissingGlyph" {
    // It was left out: `text("中")` made an empty sketch, `text("a😀b")` an "ab".
    const face = try text.getFace(.sans);
    try testing.expectError(error.MissingGlyph, text.extractText(testing.allocator, &face, "a\u{1F600}b", 10.0, 0.1, .left, .baseline));
    try testing.expectEqual(@as(?u21, 0x1F600), text.firstMissingGlyph(&face, "a\u{1F600}b"));
    try testing.expectEqual(@as(?u21, null), text.firstMissingGlyph(&face, "Привет é"));
}

/// The kerning `face` gives the pair `left` `right`, in font units.
fn kerningOf(face: *const tatfi.Face, left: u21, right: u21) !i32 {
    var kerning = try Kerning.init(testing.allocator, face);
    defer kerning.deinit(testing.allocator);
    return kerning.between(face.glyph_index(left).?, face.glyph_index(right).?);
}

test "Text Engine: a font's kerning, from class and glyph pairs and extension lookups" {
    const sans = try text.getFace(.sans);
    // Roboto's classes: "AV" and "LT" come together; "AB" has no kerning
    try testing.expectEqual(@as(i32, -87), try kerningOf(&sans, 'A', 'V'));
    try testing.expectEqual(@as(i32, -275), try kerningOf(&sans, 'L', 'T'));
    try testing.expectEqual(@as(i32, 0), try kerningOf(&sans, 'A', 'B'));
    // Its glyph pairs, which tatfi never found (a pair's second record was read with the
    // first's format), closer or further apart
    try testing.expectEqual(@as(i32, -224), try kerningOf(&sans, '/', '/'));
    try testing.expectEqual(@as(i32, 20), try kerningOf(&sans, '(', 'V'));
    // Roboto Serif keeps its pairs in an extension lookup
    const serif = try text.getFace(.serif);
    try testing.expectEqual(@as(i32, -60), try kerningOf(&serif, 'A', 'V'));
    // Roboto Mono, whose glyphs are all one width, has no GPOS table
    const mono = try text.getFace(.mono);
    try testing.expectEqual(@as(i32, 0), try kerningOf(&mono, 'A', 'V'));
}

/// The largest x of `str`'s outlines in `face`, 10 mm high.
fn rightEdge(face: *const tatfi.Face, str: []const u8) !f64 {
    var polygons = try text.extractText(testing.allocator, face, str, 10.0, 0.1, .left, .baseline);
    defer polygons.deinit(testing.allocator);
    var max_x = -std.math.inf(f64);
    for (polygons.contours.items) |contour| for (contour.items) |point| {
        max_x = @max(max_x, point[0]);
    };
    return max_x;
}

test "Text Engine: a glyph follows the one before it by its advance and their kerning" {
    // "V" went after "A" by A's advance alone, as far as in "AB"
    const face = try text.getFace(.sans);
    const scale = 10.0 / @as(f64, @floatFromInt(face.units_per_em()));
    const advance: f64 = @floatFromInt(face.glyph_hor_advance({}, face.glyph_index('A').?).?);
    const kerned = (advance + @as(f64, @floatFromInt(try kerningOf(&face, 'A', 'V')))) * scale;
    try testing.expectApproxEqAbs(try rightEdge(&face, "V") + kerned, try rightEdge(&face, "AV"), 1e-9);
}

/// How wide `str`'s outlines are in `face`, 10 mm high.
fn widthOf(face: *const tatfi.Face, str: []const u8) !f64 {
    var polygons = try text.extractText(testing.allocator, face, str, 10.0, 0.1, .left, .baseline);
    defer polygons.deinit(testing.allocator);
    var min_x = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    for (polygons.contours.items) |contour| for (contour.items) |point| {
        min_x = @min(min_x, point[0]);
        max_x = @max(max_x, point[0]);
    };
    return max_x - min_x;
}

test "Text Engine: sans-bold's strokes are half again as thick as sans's" {
    // An `l` is one stroke: 0.91 mm in sans at 10 mm, too thin for a 0.4 mm nozzle at 4 mm
    const regular = try widthOf(&(try text.getFace(.sans)), "l");
    const bold = try widthOf(&(try text.getFace(.sans_bold)), "l");
    try testing.expectApproxEqAbs(@as(f64, 0.91), regular, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1.42), bold, 0.01);
}

/// Fonts made by scripts/make-test-fonts.py: a few polygon glyphs, kerned.
const KERN_TABLE_FONT = @embedFile("test_fonts/kern-table.ttf");
const GPOS_FONT = @embedFile("test_fonts/gpos-kerning.otf");

test "Text Engine: a font without GPOS kerning is kerned by its kern table" {
    // The kern table's pairs used to be ignored, so a font that keeps its kerning only there,
    // as many TrueType fonts do, was set by its advances alone
    const face = try tatfi.Face.parse(KERN_TABLE_FONT, 0);
    try testing.expectEqual(@as(i32, -100), try kerningOf(&face, 'A', 'V'));
    try testing.expectEqual(@as(i32, -90), try kerningOf(&face, 'V', 'A'));
    try testing.expectEqual(@as(i32, -80), try kerningOf(&face, 'T', 'o'));
    try testing.expectEqual(@as(i32, 0), try kerningOf(&face, 'A', 'o'));
}

test "Text Engine: a CFF font draws its outlines and is kerned by glyph and class pairs" {
    const face = try tatfi.Face.parse(GPOS_FONT, 0);
    // A, V and T are one contour each, o two: its counter is a hole
    var polygons = try text.extractText(testing.allocator, &face, "AVTo", 10.0, 0.1, .left, .baseline);
    defer polygons.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), polygons.contours.items.len);
    // `pos A V -100` is a glyph pair; V A and T o come from `@LEFT @RIGHT -70`, a class pair
    try testing.expectEqual(@as(i32, -100), try kerningOf(&face, 'A', 'V'));
    try testing.expectEqual(@as(i32, -70), try kerningOf(&face, 'V', 'A'));
    try testing.expectEqual(@as(i32, -70), try kerningOf(&face, 'T', 'o'));
    try testing.expectEqual(@as(i32, 0), try kerningOf(&face, 'o', 'A'));
}
