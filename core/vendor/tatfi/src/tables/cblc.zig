//! A [Color Bitmap Location Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/cblc) implementation.
//!
//! EBLC and bloc also share the same structure, so this is re-used for them.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");

const Table = @This();
data: []const u8,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) Table {
    return .{
        .data = data,
    };
}

pub fn get(
    self: *const Table,
    glyph_id: lib.GlyphId,
    pixels_per_em: u16,
) ?Location {
    return self.get_impl(glyph_id, pixels_per_em) catch null;
}

fn get_impl(
    self: *const Table,
    glyph_id: lib.GlyphId,
    pixels_per_em: u16,
) parser.Error!Location {
    var s = parser.Stream.new(self.data);

    // The CBLC table version is a bit tricky, so we are ignoring it for now.
    // The CBLC table is based on EBLC table, which was based on the `bloc` table.
    // And before the CBLC table specification was finished, some fonts,
    // notably Noto Emoji, have used version 2.0, but the final spec allows only 3.0.
    // So there are perfectly valid fonts in the wild, which have an invalid version.
    s.skip(u32); // version

    const size_table = try select_bitmap_size_table(glyph_id, pixels_per_em, &s);
    const info = try select_index_subtable(self.data, size_table, glyph_id);

    s.offset = info.offset;
    const index_format = try s.read(u16);
    const image_format_raw = try s.read(u16);
    var image_offset: usize = (try s.read(parser.Offset32))[0];

    const bit_depth = size_table.bit_depth;
    const image_format: Location.BitmapFormat = switch (image_format_raw) {
        1 => .{ .metrics = .small, .data = .{ .byte_aligned = bit_depth } },
        2 => .{ .metrics = .small, .data = .{ .bit_aligned = bit_depth } },
        5 => .{ .metrics = .shared, .data = .{ .bit_aligned = bit_depth } },
        6 => .{ .metrics = .big, .data = .{ .byte_aligned = bit_depth } },
        7 => .{ .metrics = .big, .data = .{ .bit_aligned = bit_depth } },
        17 => .{ .metrics = .small, .data = .png },
        18 => .{ .metrics = .big, .data = .png },
        19 => .{ .metrics = .shared, .data = .png },
        else => return error.ParseFail, // Invalid format.
    };

    // [RazrFalcon] TODO: I wasn't able to find fonts with index 4 and 5, so they are untested.

    const glyph_diff = try std.math.sub(u16, glyph_id[0], info.start_glyph_id[0]);
    var metrics = std.mem.zeroes(Location.Metrics);

    switch (index_format) {
        1 => {
            s.advance(glyph_diff * parser.size_of(parser.Offset32));
            const offset = try s.read(parser.Offset32);
            image_offset += offset[0];
        },
        2 => {
            const image_size = try s.read(u32);
            image_offset += try std.math.mul(usize, glyph_diff, image_size);
            metrics.height = try s.read(u8);
            metrics.width = try s.read(u8);
            metrics.x = try s.read(i8);
            metrics.y = try s.read(i8);
        },
        3 => {
            s.advance(glyph_diff * parser.size_of(parser.Offset16));
            const offset = try s.read(parser.Offset16);
            image_offset += offset[0];
        },
        4 => {
            const num_glyphs = try std.math.add(u32, try s.read(u32), 1);
            const pairs = try s.read_array(GlyphIdOffsetPair, num_glyphs);
            var iter = pairs.iterator();
            const pair = while (iter.next()) |p| {
                if (p.glyph_id[0] == glyph_id[0]) break p;
            } else return error.ParseFail;

            image_offset += pair.offset[0];
        },
        5 => {
            const image_size = try s.read(u32);
            metrics.height = try s.read(u8);
            metrics.width = try s.read(u8);
            metrics.x = try s.read(i8);
            metrics.y = try s.read(i8);
            s.skip(u8); // hor_advance
            s.skip(i8); // ver_bearing_x
            s.skip(i8); // ver_bearing_y
            s.skip(u8); // ver_advance
            const num_glyphs = try s.read(u32);
            const glyphs = try s.read_array(lib.GlyphId, num_glyphs);

            const func = struct {
                fn func(lhs: lib.GlyphId, rhs: lib.GlyphId) std.math.Order {
                    return std.math.order(lhs[0], rhs[0]);
                }
            }.func;
            const index, _ = glyphs.binary_search_by(glyph_id, func) catch return error.ParseFail;

            image_offset = try std.math.add(usize, image_offset, try std.math.mul(usize, index, image_size));
        },
        else => return error.ParseFail, // Invalid format.
    }

    return .{
        .format = image_format,
        .offset = image_offset,
        .metrics = metrics,
        .ppem = size_table.ppem,
    };
}

pub const Location = struct {
    format: BitmapFormat,
    offset: usize,
    metrics: Metrics,
    ppem: u16,

    pub const BitmapFormat = struct {
        metrics: enum { small, big, shared },
        data: union(enum) { byte_aligned: u8, bit_aligned: u8, png },
    };

    pub const Metrics = struct { x: i8, y: i8, width: u8, height: u8 };
};

const BitmapSizeTable = struct {
    subtable_array_offset: parser.Offset32,
    number_of_subtables: u32,
    ppem: u16,
    bit_depth: u8,
    // Many fields are omitted.
};

fn select_bitmap_size_table(
    glyph_id: lib.GlyphId,
    pixels_per_em: u16,
    s: *parser.Stream,
) parser.Error!BitmapSizeTable {
    const subtable_count = try s.read(u32);
    const orig_s_offset = s.offset;

    var idx: ?usize = null;
    var max_ppem: u16 = 0;
    var bit_depth_for_max_ppem: u8 = 0;

    for (0..subtable_count) |i| {
        // Check that the current subtable contains a provided glyph id.
        s.advance(40); // Jump to `start_glyph_index`.
        const start_glyph_id = try s.read(lib.GlyphId);
        const end_glyph_id = try s.read(lib.GlyphId);
        const ppem_x: u16 = try s.read(u8);
        s.advance(1); // ppem_y
        const bit_depth = try s.read(u8);
        s.advance(1); // flags

        if (glyph_id[0] < start_glyph_id[0] or
            glyph_id[0] > end_glyph_id[0]) continue;

        // Select a best matching subtable based on `pixels_per_em`.
        if ((pixels_per_em <= ppem_x and ppem_x < max_ppem) or
            (pixels_per_em > max_ppem and ppem_x > max_ppem))
        {
            idx = i;
            max_ppem = ppem_x;
            bit_depth_for_max_ppem = bit_depth;
        }
    }

    if (idx == null) return error.ParseFail;

    s.offset = orig_s_offset;
    s.advance((idx orelse unreachable) * 48); // 48 is BitmapSize Table size

    const subtable_array_offset = try s.read(parser.Offset32);
    s.skip(u32); // index_tables_size
    const number_of_subtables = try s.read(u32);

    return .{
        .subtable_array_offset = subtable_array_offset,
        .number_of_subtables = number_of_subtables,
        .ppem = max_ppem,
        .bit_depth = bit_depth_for_max_ppem,
    };
}

const IndexSubtableInfo = struct {
    start_glyph_id: lib.GlyphId,
    offset: usize, // absolute offset
};

fn select_index_subtable(
    data: []const u8,
    size_table: BitmapSizeTable,
    glyph_id: lib.GlyphId,
) parser.Error!IndexSubtableInfo {
    var s = try parser.Stream.new_at(data, size_table.subtable_array_offset[0]);
    for (0..size_table.number_of_subtables) |_| {
        const start_glyph_id = try s.read(lib.GlyphId);
        const end_glyph_id = try s.read(lib.GlyphId);
        const offset = try s.read(parser.Offset32);

        if (glyph_id[0] >= start_glyph_id[0] and glyph_id[0] <= end_glyph_id[0])
            return .{
                .start_glyph_id = start_glyph_id,
                .offset = size_table.subtable_array_offset[0] + offset[0],
            };
    }

    return error.ParseFail;
}

const GlyphIdOffsetPair = struct {
    glyph_id: lib.GlyphId,
    offset: parser.Offset16,

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
};
