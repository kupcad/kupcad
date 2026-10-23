//! How a model is shaded, and what it is made of: `MaterialDef` (color, alpha, roughness,
//! metallic, transmission, a display role, and a density for the parts list) and
//! `parseHexColor` for the "#RRGGBB" / "#RGB" colors scripts give.

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
    /// g/cm³, for a part's mass in the parts list (exporters/parts.zig); shows nowhere.
    density: ?f64 = null,

    /// Feeds every property to `hasher`, for fingerprints of what a model shows.
    pub fn hashInto(self: MaterialDef, hasher: *std.hash.Wyhash) void {
        hasher.update(&self.rgb);
        hasher.update(std.mem.asBytes(&self.alpha));
        hasher.update(std.mem.asBytes(&self.roughness));
        hasher.update(std.mem.asBytes(&self.metallic));
        hasher.update(std.mem.asBytes(&self.transmission));
        hasher.update(std.mem.asBytes(&self.role));
        // The optional's bytes hold padding, which hashes as anything
        if (self.density) |d| {
            hasher.update(&.{1});
            hasher.update(std.mem.asBytes(&d));
        } else hasher.update(&.{0});
    }
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
