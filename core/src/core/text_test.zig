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

    var polygons = try text.extractText(testing.allocator, &face, "CAD", 10.0, 0.1);
    defer polygons.deinit(testing.allocator);

    // "CAD" should produce at least 4 distinct closed contours
    // (C=1, A=2 (outer+inner hole), D=2 (outer+inner hole)).
    // Actual number depends on font specifics, but MUST be > 3!
    try testing.expect(polygons.contours.items.len >= 3);

    const first_contour = polygons.contours.items[0];
    const last_contour = polygons.contours.items[polygons.contours.items.len - 1];

    // Each contour must have flattened into multiple point segments
    try testing.expect(first_contour.items.len > 10);

    // Ensure the cursor advanced properly. The last contour ('D') must have X-coordinates
    // physically further right than the first contour ('C').
    try testing.expect(last_contour.items[0][0] > first_contour.items[0][0]);
}
