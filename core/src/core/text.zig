const std = @import("std");
const tatfi = @import("tatfi");

pub const FontKey = enum {
    sans,
    mono,
    serif,
    stencil,

    pub fn fromString(name: []const u8) ?FontKey {
        if (std.mem.eql(u8, name, "sans") or std.mem.eql(u8, name, "default")) return .sans;
        if (std.mem.eql(u8, name, "mono") or std.mem.eql(u8, name, "monospace")) return .mono;
        if (std.mem.eql(u8, name, "serif")) return .serif;
        if (std.mem.eql(u8, name, "stencil")) return .stencil;
        return null;
    }
};

// Embed all TTF files into the binary (Zero allocation runtime overhead)
pub const fonts = struct {
    pub const sans = @embedFile("fonts/Roboto-Regular.ttf");
    pub const mono = @embedFile("fonts/RobotoMono-Regular.ttf");
    pub const serif = @embedFile("fonts/RobotoSerif-Regular.ttf");
    pub const stencil = @embedFile("fonts/AllertaStencil-Regular.ttf");
};

pub fn getFontBytes(key: FontKey) []const u8 {
    return switch (key) {
        .sans => fonts.sans,
        .mono => fonts.mono,
        .serif => fonts.serif,
        .stencil => fonts.stencil,
    };
}

/// Parses and returns a tatfi.Face for the given FontKey
pub fn getFace(key: FontKey) !tatfi.Face {
    const bytes = getFontBytes(key);
    return tatfi.Face.parse(bytes, 0) catch return error.InvalidFont;
}

/// Parses and returns a tatfi.Face by string name (defaults to :sans if unknown)
pub fn getFaceByName(name: []const u8) !tatfi.Face {
    const key = FontKey.fromString(name) orelse .sans;
    return getFace(key);
}

/// Helper for backwards compatibility
pub fn getDefaultFace() !tatfi.Face {
    return getFace(.sans);
}
