const std = @import("std");

pub const MaterialRole = enum { standard, ghost, highlight };

pub const MaterialDef = struct {
    /// sRGB color, parsed from "#RRGGBB" / "#RGB" when the script set it. Storing the
    /// String itself kept a slice into GC memory that nothing rooted until export.
    rgb: [3]u8 = .{ 0xFF, 0xFF, 0xFF },
    alpha: f64 = 1.0,
    roughness: f64 = 0.5,
    metallic: f64 = 0.0,
    transmission: f64 = 0.0,
    role: MaterialRole = .standard,
};

/// The sRGB bytes of "#RRGGBB" or "#RGB" (each digit doubled), or null for anything else.
pub fn parseHexColor(text: []const u8) ?[3]u8 {
    if (text.len == 0 or text[0] != '#') return null;
    const digits = text[1..];
    var rgb: [3]u8 = undefined;
    switch (digits.len) {
        6 => for (&rgb, 0..) |*c, i| {
            c.* = std.fmt.parseInt(u8, digits[i * 2 ..][0..2], 16) catch return null;
        },
        3 => for (&rgb, digits) |*c, d| {
            const nibble = std.fmt.charToDigit(d, 16) catch return null;
            c.* = nibble * 0x11;
        },
        else => return null,
    }
    return rgb;
}
