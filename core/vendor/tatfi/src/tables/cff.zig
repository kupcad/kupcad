pub const cff1 = @import("cff/cff1.zig");
pub const cff2 = @import("cff/cff2.zig");

const std = @import("std");
const lib = @import("../lib.zig");
const utils = @import("../utils.zig");

/// A type-safe wrapper for string ID.
pub const StringId = struct { u16 };

pub const Builder = struct {
    builder: lib.OutlineBuilder,
    bbox: lib.RectF,
    transform_tuple: ?struct { u16, cff1.Matrix },

    pub fn move_to(
        self: *Builder,
        x_f: f32,
        y_f: f32,
    ) void {
        const x, const y = self.transform(x_f, y_f);
        self.bbox.extend_by(x, y);
        self.builder.move_to(x, y);
    }

    pub fn line_to(
        self: *Builder,
        x_f: f32,
        y_f: f32,
    ) void {
        const x, const y = self.transform(x_f, y_f);
        self.bbox.extend_by(x, y);
        self.builder.line_to(x, y);
    }

    pub fn curve_to(
        self: *Builder,
        x1_f: f32,
        y1_f: f32,
        x2_f: f32,
        y2_f: f32,
        x_f: f32,
        y_f: f32,
    ) void {
        const x1, const y1 = self.transform(x1_f, y1_f);
        const x2, const y2 = self.transform(x2_f, y2_f);
        const x, const y = self.transform(x_f, y_f);
        self.bbox.extend_by(x1, y1);
        self.bbox.extend_by(x2, y2);
        self.bbox.extend_by(x, y);
        self.builder.curve_to(x1, y1, x2, y2, x, y);
    }

    pub fn close(
        self: *Builder,
    ) void {
        self.builder.close();
    }

    fn transform(
        self: Builder,
        x: f32,
        y: f32,
    ) struct { f32, f32 } {
        const units_per_em, const matrix =
            self.transform_tuple orelse return .{ x, y };

        var tx, var ty = .{ x, y };
        tx = tx * matrix.sx + ty * matrix.kx + matrix.tx;
        ty = tx * matrix.ky + ty * matrix.sy + matrix.ty;
        tx *= @floatFromInt(units_per_em);
        ty *= @floatFromInt(units_per_em);
        return .{ tx, ty };
    }
};

/// A list of errors that can occur during a CFF glyph outlining.
pub const Error = error{
    NoGlyph,
    ReadOutOfBounds,
    ZeroBBox,
    InvalidOperator,
    UnsupportedOperator,
    MissingEndChar,
    DataAfterEndChar,
    NestingLimitReached,
    ArgumentsStackLimitReached,
    InvalidArgumentsStackLength,
    BboxOverflow,
    MissingMoveTo,
    InvalidSubroutineIndex,
    NoLocalSubroutines,
    InvalidSeacCode,
    InvalidItemVariationDataIndex,
    InvalidNumberOfBlendOperands,
    BlendRegionsLimitReached,
};

pub const STANDARD_NAMES: []const []const u8 = &.{
    ".notdef",            "space",             "exclam",              "quotedbl",
    "numbersign",         "dollar",            "percent",             "ampersand",
    "quoteright",         "parenleft",         "parenright",          "asterisk",
    "plus",               "comma",             "hyphen",              "period",
    "slash",              "zero",              "one",                 "two",
    "three",              "four",              "five",                "six",
    "seven",              "eight",             "nine",                "colon",
    "semicolon",          "less",              "equal",               "greater",
    "question",           "at",                "A",                   "B",
    "C",                  "D",                 "E",                   "F",
    "G",                  "H",                 "I",                   "J",
    "K",                  "L",                 "M",                   "N",
    "O",                  "P",                 "Q",                   "R",
    "S",                  "T",                 "U",                   "V",
    "W",                  "X",                 "Y",                   "Z",
    "bracketleft",        "backslash",         "bracketright",        "asciicircum",
    "underscore",         "quoteleft",         "a",                   "b",
    "c",                  "d",                 "e",                   "f",
    "g",                  "h",                 "i",                   "j",
    "k",                  "l",                 "m",                   "n",
    "o",                  "p",                 "q",                   "r",
    "s",                  "t",                 "u",                   "v",
    "w",                  "x",                 "y",                   "z",
    "braceleft",          "bar",               "braceright",          "asciitilde",
    "exclamdown",         "cent",              "sterling",            "fraction",
    "yen",                "florin",            "section",             "currency",
    "quotesingle",        "quotedblleft",      "guillemotleft",       "guilsinglleft",
    "guilsinglright",     "fi",                "fl",                  "endash",
    "dagger",             "daggerdbl",         "periodcentered",      "paragraph",
    "bullet",             "quotesinglbase",    "quotedblbase",        "quotedblright",
    "guillemotright",     "ellipsis",          "perthousand",         "questiondown",
    "grave",              "acute",             "circumflex",          "tilde",
    "macron",             "breve",             "dotaccent",           "dieresis",
    "ring",               "cedilla",           "hungarumlaut",        "ogonek",
    "caron",              "emdash",            "AE",                  "ordfeminine",
    "Lslash",             "Oslash",            "OE",                  "ordmasculine",
    "ae",                 "dotlessi",          "lslash",              "oslash",
    "oe",                 "germandbls",        "onesuperior",         "logicalnot",
    "mu",                 "trademark",         "Eth",                 "onehalf",
    "plusminus",          "Thorn",             "onequarter",          "divide",
    "brokenbar",          "degree",            "thorn",               "threequarters",
    "twosuperior",        "registered",        "minus",               "eth",
    "multiply",           "threesuperior",     "copyright",           "Aacute",
    "Acircumflex",        "Adieresis",         "Agrave",              "Aring",
    "Atilde",             "Ccedilla",          "Eacute",              "Ecircumflex",
    "Edieresis",          "Egrave",            "Iacute",              "Icircumflex",
    "Idieresis",          "Igrave",            "Ntilde",              "Oacute",
    "Ocircumflex",        "Odieresis",         "Ograve",              "Otilde",
    "Scaron",             "Uacute",            "Ucircumflex",         "Udieresis",
    "Ugrave",             "Yacute",            "Ydieresis",           "Zcaron",
    "aacute",             "acircumflex",       "adieresis",           "agrave",
    "aring",              "atilde",            "ccedilla",            "eacute",
    "ecircumflex",        "edieresis",         "egrave",              "iacute",
    "icircumflex",        "idieresis",         "igrave",              "ntilde",
    "oacute",             "ocircumflex",       "odieresis",           "ograve",
    "otilde",             "scaron",            "uacute",              "ucircumflex",
    "udieresis",          "ugrave",            "yacute",              "ydieresis",
    "zcaron",             "exclamsmall",       "Hungarumlautsmall",   "dollaroldstyle",
    "dollarsuperior",     "ampersandsmall",    "Acutesmall",          "parenleftsuperior",
    "parenrightsuperior", "twodotenleader",    "onedotenleader",      "zerooldstyle",
    "oneoldstyle",        "twooldstyle",       "threeoldstyle",       "fouroldstyle",
    "fiveoldstyle",       "sixoldstyle",       "sevenoldstyle",       "eightoldstyle",
    "nineoldstyle",       "commasuperior",     "threequartersemdash", "periodsuperior",
    "questionsmall",      "asuperior",         "bsuperior",           "centsuperior",
    "dsuperior",          "esuperior",         "isuperior",           "lsuperior",
    "msuperior",          "nsuperior",         "osuperior",           "rsuperior",
    "ssuperior",          "tsuperior",         "ff",                  "ffi",
    "ffl",                "parenleftinferior", "parenrightinferior",  "Circumflexsmall",
    "hyphensuperior",     "Gravesmall",        "Asmall",              "Bsmall",
    "Csmall",             "Dsmall",            "Esmall",              "Fsmall",
    "Gsmall",             "Hsmall",            "Ismall",              "Jsmall",
    "Ksmall",             "Lsmall",            "Msmall",              "Nsmall",
    "Osmall",             "Psmall",            "Qsmall",              "Rsmall",
    "Ssmall",             "Tsmall",            "Usmall",              "Vsmall",
    "Wsmall",             "Xsmall",            "Ysmall",              "Zsmall",
    "colonmonetary",      "onefitted",         "rupiah",              "Tildesmall",
    "exclamdownsmall",    "centoldstyle",      "Lslashsmall",         "Scaronsmall",
    "Zcaronsmall",        "Dieresissmall",     "Brevesmall",          "Caronsmall",
    "Dotaccentsmall",     "Macronsmall",       "figuredash",          "hypheninferior",
    "Ogoneksmall",        "Ringsmall",         "Cedillasmall",        "questiondownsmall",
    "oneeighth",          "threeeighths",      "fiveeighths",         "seveneighths",
    "onethird",           "twothirds",         "zerosuperior",        "foursuperior",
    "fivesuperior",       "sixsuperior",       "sevensuperior",       "eightsuperior",
    "ninesuperior",       "zeroinferior",      "oneinferior",         "twoinferior",
    "threeinferior",      "fourinferior",      "fiveinferior",        "sixinferior",
    "seveninferior",      "eightinferior",     "nineinferior",        "centinferior",
    "dollarinferior",     "periodinferior",    "commainferior",       "Agravesmall",
    "Aacutesmall",        "Acircumflexsmall",  "Atildesmall",         "Adieresissmall",
    "Aringsmall",         "AEsmall",           "Ccedillasmall",       "Egravesmall",
    "Eacutesmall",        "Ecircumflexsmall",  "Edieresissmall",      "Igravesmall",
    "Iacutesmall",        "Icircumflexsmall",  "Idieresissmall",      "Ethsmall",
    "Ntildesmall",        "Ogravesmall",       "Oacutesmall",         "Ocircumflexsmall",
    "Otildesmall",        "Odieresissmall",    "OEsmall",             "Oslashsmall",
    "Ugravesmall",        "Uacutesmall",       "Ucircumflexsmall",    "Udieresissmall",
    "Yacutesmall",        "Thornsmall",        "Ydieresissmall",      "001.000",
    "001.001",            "001.002",           "001.003",             "Black",
    "Bold",               "Book",              "Light",               "Medium",
    "Regular",            "Roman",             "Semibold",
};

// Adobe Technical Note #5176, Chapter 16 "Local / Global Subrs INDEXes"
pub inline fn calc_subroutine_bias(
    len: u32,
) u16 {
    return if (len < 1240) 107 else if (len < 33900) 1131 else 32768;
}

pub inline fn conv_subroutine_index(
    index: f32,
    bias: u16,
) Error!u32 {
    const index_i32 = utils.f32_to_i32(index) orelse return error.InvalidSubroutineIndex;
    const index_biased = std.math.add(i32, index_i32, bias) catch return error.InvalidSubroutineIndex;
    return std.math.cast(u32, index_biased) orelse return error.InvalidSubroutineIndex;
}
