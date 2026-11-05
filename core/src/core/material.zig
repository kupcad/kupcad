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

    pub fn eql(self: MaterialDef, other: MaterialDef) bool {
        return std.meta.eql(self, other);
    }
};

/// The id of `def` in `table`: an equal one's, or a new one's at its end. A material is known
/// by what it is, so a run made again finds the ids it made before, and the Solids that kept
/// them (a session's cached imports) keep their colours.
pub fn intern(allocator: std.mem.Allocator, table: *std.ArrayList(MaterialDef), def: MaterialDef) !u32 {
    for (table.items, 0..) |known, id| if (known.eql(def)) return @intCast(id);
    try table.append(allocator, def);
    return @intCast(table.items.len - 1);
}

/// The sRGB bytes of "#RRGGBB" or "#RGB" (each digit doubled), or null for anything else.
/// Each digit is read as one (a number parse took "#+10000", its sign, as red).
/// `#rrggbb`, lower case, as the preview's frame and an SVG name a colour (each wrote its own,
/// one in capitals).
pub fn hexRgb(rgb: [3]u8) [7]u8 {
    var out: [7]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
    return out;
}

/// `#rrggbbaa`, as 3MF names a colour with its alpha.
pub fn hexRgba(rgba: [4]u8) [9]u8 {
    var out: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ rgba[0], rgba[1], rgba[2], rgba[3] }) catch unreachable;
    return out;
}

pub fn parseHexColor(text: []const u8) ?[3]u8 {
    if (text.len == 0 or text[0] != '#') return null;
    const digits = text[1..];
    var rgb: [3]u8 = undefined;
    switch (digits.len) {
        6 => for (&rgb, 0..) |*c, i| {
            c.* = @as(u8, std.fmt.charToDigit(digits[2 * i], 16) catch return null) * 16 + (std.fmt.charToDigit(digits[2 * i + 1], 16) catch return null);
        },
        3 => for (&rgb, digits) |*c, d| {
            c.* = @as(u8, std.fmt.charToDigit(d, 16) catch return null) * 0x11;
        },
        else => return null,
    }
    return rgb;
}
