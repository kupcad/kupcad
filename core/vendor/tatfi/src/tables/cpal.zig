//! A [Color Palette Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/cpal) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");

const Table = @This();

color_indices: parser.LazyArray16(u16),
colors: parser.LazyArray16(BgraColor),

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u16);
    if (version > 1) return error.ParseFail;

    s.skip(u16); // number of palette entries

    const num_palettes = try s.read(u16);
    if (num_palettes == 0) return error.ParseFail; // zero palettes is an error

    const num_colors = try s.read(u16);
    const color_records_offset = try s.read(parser.Offset32);
    const color_indices = try s.read_array(u16, num_palettes);

    var colors_stream = try parser.Stream.new_at(data, color_records_offset[0]);
    const colors = try colors_stream.read_array(BgraColor, num_colors);

    return .{
        .color_indices = color_indices,
        .colors = colors,
    };
}

/// Returns the number of palettes.
pub fn palettes(
    self: *const Table,
) u16 {
    // Already checked to be nonzero during parsing.
    return self.color_indices.len();
}

/// Returns the color at the given index into the given palette.
pub fn get(
    self: *const Table,
    palette_index: u16,
    palette_entry: u16,
) ?lib.RgbaColor {
    const index = std.math.add(
        u16,
        self.color_indices.get(palette_index) orelse return null,
        palette_entry,
    ) catch return null;

    const c = self.colors.get(index) orelse return null;
    return c.to_rgba();
}

const BgraColor = struct {
    blue: u8,
    green: u8,
    red: u8,
    alpha: u8,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 4;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };

    fn to_rgba(
        self: BgraColor,
    ) lib.RgbaColor {
        return .{
            .red = self.red,
            .green = self.green,
            .blue = self.blue,
            .alpha = self.alpha,
        };
    }
};
