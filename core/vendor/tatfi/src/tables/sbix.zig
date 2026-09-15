//! A [Standard Bitmap Graphics Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/sbix) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");

const Table = @This();

/// A list of `Strike`s.
strikes: Strikes,

/// Parses a table from raw data.
///
/// - `number_of_glyphs` is from the `maxp` table.
pub fn parse(
    number_of_glyphs: u16,
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u16);
    if (version != 1) return error.ParseFail;

    s.skip(u16); // flags

    const strikes_count = try s.read(u32);
    if (strikes_count == 0) return error.ParseFail;

    const offsets = try s.read_array(parser.Offset32, strikes_count);

    return .{ .strikes = .{
        .data = data,
        .offsets = offsets,
        .number_of_glyphs = number_of_glyphs +| 1,
    } };
}

/// Selects the best matching `Strike` based on `pixels_per_em`.
pub fn best_strike(
    self: *const Table,
    pixels_per_em: u16,
) ?Strike {
    var idx: u32 = 0;
    var max_ppem: u16 = 0;

    var iter = self.strikes.iterator();
    var i: u32 = 0;
    while (iter.next()) |strike| : (i += 1)
        if ((pixels_per_em <= strike.pixels_per_em and strike.pixels_per_em < max_ppem) or
            (pixels_per_em > max_ppem and strike.pixels_per_em > max_ppem))
        {
            idx = i;
            max_ppem = strike.pixels_per_em;
        };

    return self.strikes.get(idx);
}

/// A strike of glyphs.
pub const Strike = struct {
    /// The pixels per EM size for which this strike was designed.
    pixels_per_em: u16,
    /// The device pixel density (in PPI) for which this strike was designed.
    ppi: u16,
    offsets: parser.LazyArray16(parser.Offset32),
    /// Data from the beginning of the `Strikes` table.
    data: []const u8,

    fn parse(
        number_of_glyphs: u16,
        data: []const u8,
    ) parser.Error!Strike {
        var s = parser.Stream.new(data);
        const pixels_per_em = try s.read(u16);
        const ppi = try s.read(u16);
        const offsets = try s.read_array(parser.Offset32, number_of_glyphs);
        return .{
            .pixels_per_em = pixels_per_em,
            .ppi = ppi,
            .offsets = offsets,
            .data = data,
        };
    }

    /// Returns a glyph data.
    pub fn get(
        self: Strike,
        glyph_id: lib.GlyphId,
    ) ?lib.RasterGlyphImage {
        return self.get_inner(glyph_id, 0) catch null;
    }

    fn get_inner(
        self: Strike,
        glyph_id: lib.GlyphId,
        depth: u8,
    ) parser.Error!lib.RasterGlyphImage {
        // Recursive `dupe`. Bail.
        if (depth == 10) return error.ParseFail;

        const start = (self.offsets.get(glyph_id[0]) orelse return error.ParseFail)[0];
        const end = (self.offsets.get(glyph_id[0] +| 1) orelse return error.ParseFail)[0];

        if (start == end) return error.ParseFail;

        const data_len = len: {
            const length = try std.math.sub(u32, end, start);
            break :len try std.math.sub(u32, length, 8); // 8 is a Glyph data header size.
        };

        var s = try parser.Stream.new_at(self.data, start);
        const x = try s.read(i16);
        const y = try s.read(i16);
        const image_type = try s.read(lib.Tag);
        const image_data = try s.read_bytes(data_len);

        // We do ignore `pdf` and `mask` intentionally, because Apple docs state that:
        // 'Support for the 'pdf ' and 'mask' data types and sbixDrawOutlines flag
        // are planned for future releases of iOS and OS X.'
        const format: lib.RasterGlyphImage.Format = switch (image_type.inner) {
            lib.Tag.from_bytes("png ").inner => .png,
            lib.Tag.from_bytes("dupe").inner => {
                // 'The special graphicType of 'dupe' indicates that
                // the data field contains a glyph ID. The bitmap data for
                // the indicated glyph should be used for the current glyph.'
                var mini_s = parser.Stream.new(image_data);
                const inner_glyph_id = try mini_s.read(lib.GlyphId);
                // TODO: The spec isn't clear about which x/y values should we use.
                //       The current glyph or the referenced one.
                return self.get_inner(inner_glyph_id, depth + 1);
            },
            // TODO: support JPEG and TIFF
            else => return error.ParseFail,
        };

        const width, const height = try png_size(image_data);

        return .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .pixels_per_em = self.pixels_per_em,
            .format = format,
            .data = image_data,
        };
    }

    /// Returns the number of glyphs in this strike.
    pub fn len(
        self: Strike,
    ) u16 {
        // The last offset simply indicates the glyph data end. We don't need it.
        return self.offsets.len() -| 1;
    }
};

/// A list of `Strike`s.
pub const Strikes = struct {
    /// `sbix` table data.
    data: []const u8,
    // Offsets from the beginning of the `sbix` table.
    offsets: parser.LazyArray32(parser.Offset32),
    // The total number of glyphs in the face + 1. From the `maxp` table.
    number_of_glyphs: u16,

    /// Returns the number of strikes.
    pub fn len(
        self: Strikes,
    ) u32 {
        return self.offsets.len();
    }

    /// Returns a strike at the index.
    pub fn get(
        self: Strikes,
        index: u32,
    ) ?Strike {
        const offset = self.offsets.get(index) orelse return null;
        const data = utils.slice(self.data, offset[0]) catch return null;
        return Strike.parse(self.number_of_glyphs, data) catch null;
    }

    pub fn iterator(
        self: *const Strikes,
    ) Iterator {
        return .{ .strikes = self };
    }

    pub const Iterator = struct {
        strikes: *const Strikes,
        index: u32 = 0,

        pub fn next(
            self: *Iterator,
        ) ?Strike {
            if (self.index < self.strikes.len()) {
                defer self.index += 1;
                return self.strikes.get(self.index);
            } else return null;
        }
    };
};

// The `sbix` table doesn't store the image size, so we have to parse it manually.
// Which is quite simple in case of PNG, but way more complex for JPEG.
// Therefore we are omitting it for now.
fn png_size(
    data: []const u8,
) parser.Error!struct { u16, u16 } {
    // PNG stores its size as u32 BE at a fixed offset.
    var s = try parser.Stream.new_at(data, 16);
    const width = try s.read(u32);
    const height = try s.read(u32);

    // PNG size larger than maxInt(u16) is an error.
    return .{
        std.math.cast(u16, width) orelse return error.Overflow,
        std.math.cast(u16, height) orelse return error.Overflow,
    };
}
