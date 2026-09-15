//! An [SVG Table](https://docs.microsoft.com/en-us/typography/opentype/spec/svg) implementation.

const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");

const Table = @This();

/// A list of SVG documents.
documents: SvgDocumentsList,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);
    s.skip(u16); // version

    const doc_list_offset = try s.read_optional(parser.Offset32) orelse return error.ParseFail;

    const count = try s.read_at(u16, doc_list_offset[0]);
    const records = try s.read_array(SvgDocumentRecord, count);

    return .{ .documents = .{
        .data = try utils.slice(data, doc_list_offset[0]),
        .records = records,
    } };
}

/// A list of [SVG documents](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/svg#svg-document-list).
pub const SvgDocumentsList = struct {
    data: []const u8,
    records: parser.LazyArray16(SvgDocumentRecord),

    /// Returns SVG document data at index.
    ///
    /// `index` is not a GlyphId. You should use `find()` instead.
    pub fn get(
        self: SvgDocumentsList,
        index: u16,
    ) ?SvgDocument {
        const record = self.records.get(index) orelse return null;
        const offset = (record.svg_doc_offset orelse return null)[0];

        return .{
            .data = utils.slice(self.data, .{ offset, record.svg_doc_length }) catch return null,
            .start_glyph_id = record.start_glyph_id,
            .end_glyph_id = record.end_glyph_id,
        };
    }

    /// Returns a SVG document data by glyph ID.
    pub fn find(
        self: SvgDocumentsList,
        glyph_id: lib.GlyphId,
    ) ?SvgDocument {
        var iter = self.records.iterator();
        var i: u16 = 0;
        const index = while (iter.next()) |v| : (i += 1) {
            if (glyph_id[0] >= v.start_glyph_id[0] and
                glyph_id[0] <= v.end_glyph_id[0]) break i;
        } else return null;

        return self.get(index);
    }

    pub fn iterator(
        self: *const SvgDocumentsList,
    ) Iterator {
        return .{ .list = self };
    }

    pub const Iterator = struct {
        list: *const SvgDocumentsList,
        index: u16 = 0,

        pub fn next(
            self: *Iterator,
        ) ?SvgDocument {
            if (self.index < self.list.records.len()) {
                defer self.index += 1;
                return self.list.get(self.index);
            } else return null;
        }
    };
};

const SvgDocumentRecord = struct {
    start_glyph_id: lib.GlyphId,
    end_glyph_id: lib.GlyphId,
    svg_doc_offset: ?parser.Offset32,
    svg_doc_length: u32,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 12;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// An [SVG documents](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/svg#svg-document-list).
pub const SvgDocument = struct {
    /// The SVG document data.
    ///
    /// Can be stored as a string or as a gzip compressed data, aka SVGZ.
    data: []const u8,
    /// The first glyph ID for the range covered by this record.
    start_glyph_id: lib.GlyphId,
    /// The last glyph ID, *inclusive*, for the range covered by this record.
    end_glyph_id: lib.GlyphId,
};
