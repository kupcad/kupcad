const std = @import("std");
const testing = std.testing;
const text = @import("text.zig");

test "Text Engine: Successfully parses embedded Roboto font allocation-free" {
    const face = try text.getDefaultFace();

    const units_per_em = face.units_per_em();
    const ascender = face.ascender();
    const descender = face.descender();

    try testing.expect(units_per_em > 0);
    try testing.expect(ascender > 0);
    try testing.expect(descender < 0);
}
