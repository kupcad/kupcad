//! A [PostScript Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/post) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");

const ITALIC_ANGLE_OFFSET: usize = 4;
const UNDERLINE_POSITION_OFFSET: usize = 8;
const UNDERLINE_THICKNESS_OFFSET: usize = 10;
const IS_FIXED_PITCH_OFFSET: usize = 12;

const Table = @This();

/// Italic angle in counter-clockwise degrees from the vertical.
italic_angle: f32,
/// Underline metrics.
underline_metrics: lib.LineMetrics,
/// Flag that indicates that the font is monospaced.
is_monospaced: bool,
glyph_indices: parser.LazyArray16(u16),
names_data: []const u8,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    // Do not check the exact length, because some fonts include
    // padding in table's length in table records, which is incorrect.
    if (data.len < 32) return error.ParseFail;

    var s = parser.Stream.new(data);
    const version = try s.read(u32);

    if (version != 0x00010000 and
        version != 0x00020000 and
        version != 0x00025000 and
        version != 0x00030000 and
        version != 0x00040000)
    {
        return error.ParseFail;
    }

    const italic_angle = try s.read_at(parser.Fixed, ITALIC_ANGLE_OFFSET);

    const underline_metrics: lib.LineMetrics = .{
        .position = try s.read_at(i16, UNDERLINE_POSITION_OFFSET),
        .thickness = try s.read_at(i16, UNDERLINE_THICKNESS_OFFSET),
    };

    const is_monospaced = (try s.read_at(u32, IS_FIXED_PITCH_OFFSET)) != 0;

    // Only version 2.0 of the table has data at the end.
    const names_data, const glyph_indices = if (version == 0x00020000) v: {
        const indices_count = try s.read_at(u16, 32);
        const glyph_indices = try s.read_array(u16, indices_count);
        const names_data = try s.tail();
        break :v .{ names_data, glyph_indices };
    } else .{ &.{}, parser.LazyArray16(u16){} };

    return .{
        .italic_angle = italic_angle.value,
        .underline_metrics = underline_metrics,
        .is_monospaced = is_monospaced,
        .names_data = names_data,
        .glyph_indices = glyph_indices,
    };
}

/// Returns a glyph ID by a name.
pub fn glyph_index_by_name(
    self: *const Table,
    name: []const u8,
) ?lib.GlyphId {
    const id = id: for (MACINTOSH_NAMES, 0..) |n, index| {
        if (!std.mem.eql(u8, name, n)) continue;
        var iter = self.glyph_indices.iterator();
        var pos: usize = 0;
        while (iter.next()) |glyph_idx| : (pos += 1) {
            if (glyph_idx == index)
                break :id pos;
        } else return null;
    } else {
        const index = i: {
            var iter = self.names();
            var pos: usize = 0;
            const index = while (iter.next()) |n| : (pos += 1) {
                if (std.mem.eql(u8, name, n)) break pos;
            } else return null;
            break :i index + MACINTOSH_NAMES.len;
        };

        var iter = self.glyph_indices.iterator();
        var pos: usize = 0;
        while (iter.next()) |glyph_idx| : (pos += 1) {
            if (glyph_idx == index)
                break :id pos;
        } else return null;
    };

    return .{@truncate(id)};
}

/// Returns an iterator over glyph names.
///
/// Default/predefined names are not included. Just the one in the font file.
pub fn names(
    self: *const Table,
) Names {
    return .{
        .data = self.names_data,
        .offset = 0,
    };
}

/// Returns a glyph name by ID.
pub fn glyph_name(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?[]const u8 {
    const index = self.glyph_indices.get(glyph_id[0]) orelse return null;

    // 'If the name index is between 0 and 257, treat the name index
    // as a glyph index in the Macintosh standard order.'
    if (index < MACINTOSH_NAMES.len)
        return MACINTOSH_NAMES[index]
    else {
        // 'If the name index is between 258 and 65535, then subtract 258 and use that
        // to index into the list of Pascal strings at the end of the table.'
        const pascal_idx = index - MACINTOSH_NAMES.len;
        var iter = self.names();
        var counter: usize = 0;
        while (iter.next()) |n| : (counter += 1)
            if (counter == pascal_idx) return n;

        return null;
    }
}

// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6post.html
/// A list of Macintosh glyph names.
const MACINTOSH_NAMES: []const []const u8 = &.{
    ".notdef",          ".null",         "nonmarkingreturn", "space",
    "exclam",           "quotedbl",      "numbersign",       "dollar",
    "percent",          "ampersand",     "quotesingle",      "parenleft",
    "parenright",       "asterisk",      "plus",             "comma",
    "hyphen",           "period",        "slash",            "zero",
    "one",              "two",           "three",            "four",
    "five",             "six",           "seven",            "eight",
    "nine",             "colon",         "semicolon",        "less",
    "equal",            "greater",       "question",         "at",
    "A",                "B",             "C",                "D",
    "E",                "F",             "G",                "H",
    "I",                "J",             "K",                "L",
    "M",                "N",             "O",                "P",
    "Q",                "R",             "S",                "T",
    "U",                "V",             "W",                "X",
    "Y",                "Z",             "bracketleft",      "backslash",
    "bracketright",     "asciicircum",   "underscore",       "grave",
    "a",                "b",             "c",                "d",
    "e",                "f",             "g",                "h",
    "i",                "j",             "k",                "l",
    "m",                "n",             "o",                "p",
    "q",                "r",             "s",                "t",
    "u",                "v",             "w",                "x",
    "y",                "z",             "braceleft",        "bar",
    "braceright",       "asciitilde",    "Adieresis",        "Aring",
    "Ccedilla",         "Eacute",        "Ntilde",           "Odieresis",
    "Udieresis",        "aacute",        "agrave",           "acircumflex",
    "adieresis",        "atilde",        "aring",            "ccedilla",
    "eacute",           "egrave",        "ecircumflex",      "edieresis",
    "iacute",           "igrave",        "icircumflex",      "idieresis",
    "ntilde",           "oacute",        "ograve",           "ocircumflex",
    "odieresis",        "otilde",        "uacute",           "ugrave",
    "ucircumflex",      "udieresis",     "dagger",           "degree",
    "cent",             "sterling",      "section",          "bullet",
    "paragraph",        "germandbls",    "registered",       "copyright",
    "trademark",        "acute",         "dieresis",         "notequal",
    "AE",               "Oslash",        "infinity",         "plusminus",
    "lessequal",        "greaterequal",  "yen",              "mu",
    "partialdiff",      "summation",     "product",          "pi",
    "integral",         "ordfeminine",   "ordmasculine",     "Omega",
    "ae",               "oslash",        "questiondown",     "exclamdown",
    "logicalnot",       "radical",       "florin",           "approxequal",
    "Delta",            "guillemotleft", "guillemotright",   "ellipsis",
    "nonbreakingspace", "Agrave",        "Atilde",           "Otilde",
    "OE",               "oe",            "endash",           "emdash",
    "quotedblleft",     "quotedblright", "quoteleft",        "quoteright",
    "divide",           "lozenge",       "ydieresis",        "Ydieresis",
    "fraction",         "currency",      "guilsinglleft",    "guilsinglright",
    "fi",               "fl",            "daggerdbl",        "periodcentered",
    "quotesinglbase",   "quotedblbase",  "perthousand",      "Acircumflex",
    "Ecircumflex",      "Aacute",        "Edieresis",        "Egrave",
    "Iacute",           "Icircumflex",   "Idieresis",        "Igrave",
    "Oacute",           "Ocircumflex",   "apple",            "Ograve",
    "Uacute",           "Ucircumflex",   "Ugrave",           "dotlessi",
    "circumflex",       "tilde",         "macron",           "breve",
    "dotaccent",        "ring",          "cedilla",          "hungarumlaut",
    "ogonek",           "caron",         "Lslash",           "lslash",
    "Scaron",           "scaron",        "Zcaron",           "zcaron",
    "brokenbar",        "Eth",           "eth",              "Yacute",
    "yacute",           "Thorn",         "thorn",            "minus",
    "multiply",         "onesuperior",   "twosuperior",      "threesuperior",
    "onehalf",          "onequarter",    "threequarters",    "franc",
    "Gbreve",           "gbreve",        "Idotaccent",       "Scedilla",
    "scedilla",         "Cacute",        "cacute",           "Ccaron",
    "ccaron",           "dcroat",
};

/// An iterator over glyph names.
///
/// The `post` table doesn't provide the glyph names count,
/// so we have to simply iterate over all of them to find it out.
///
/// [ARS] Does not verify it is valid utf8
pub const Names = struct {
    data: []const u8,
    offset: usize,

    pub fn next(
        self: *Names,
    ) ?[]const u8 {
        // Glyph names are stored as Pascal Strings.
        // Meaning u8 (len) + [u8] (data).

        if (self.offset >= self.data.len) return null;

        const len = self.data[self.offset];
        self.offset += 1;

        // An empty name is an error.
        if (len == 0) return null;

        defer self.offset += len;
        return utils.slice(self.data, .{ self.offset, len }) catch null;
    }
};
