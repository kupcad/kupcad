const std = @import("std");
const tatfi = @import("tatfi");

// Embed the default font into the binary so it is universally available
pub const default_font_bytes = @embedFile("fonts/Roboto-Regular.ttf");

pub fn getDefaultFace() !tatfi.Face {
    return tatfi.Face.parse(default_font_bytes, 0) catch return error.InvalidFont;
}
