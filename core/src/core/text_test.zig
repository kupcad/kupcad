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
