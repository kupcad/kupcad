const std = @import("std");
const testing = std.testing;
const text = @import("text.zig");

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

test "Text Engine: Name resolution fallbacks cleanly to default sans font" {
    const face_mono = try text.getFaceByName("mono");
    const face_unknown = try text.getFaceByName("unknown_font_family");

    // "mono" resolves to mono font
    try testing.expect(face_mono.units_per_em() > 0);

    // Unknown string falls back safely to default sans font
    const default_face = try text.getDefaultFace();
    try testing.expectEqual(default_face.units_per_em(), face_unknown.units_per_em());
}

test "Text Engine: Extracts flat 2D polygons from text string and kerning" {
    const face = try text.getDefaultFace();

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
    const face = try text.getDefaultFace();
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

fn pointCount(polygons: *const text.TextPolygons) usize {
    var total: usize = 0;
    for (polygons.contours.items) |c| total += c.items.len;
    return total;
}

test "Text Engine: running out of memory fails the extraction instead of truncating a glyph" {
    const face = try text.getDefaultFace();
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
    const face = try text.getFaceByName("sans");
    try testing.expectError(error.InvalidUtf8, text.extractText(testing.allocator, &face, "A\xFFB", 10.0, 0.1, .left, .baseline));
}

test "Text: a character the font has no glyph for is an error, named by firstMissingGlyph" {
    // It was left out: `text("中")` made an empty sketch, `text("a😀b")` an "ab".
    const face = try text.getFaceByName("sans");
    try testing.expectError(error.MissingGlyph, text.extractText(testing.allocator, &face, "a\u{1F600}b", 10.0, 0.1, .left, .baseline));
    try testing.expectEqual(@as(?u21, 0x1F600), text.firstMissingGlyph(&face, "a\u{1F600}b"));
    try testing.expectEqual(@as(?u21, null), text.firstMissingGlyph(&face, "Привет é"));
}
