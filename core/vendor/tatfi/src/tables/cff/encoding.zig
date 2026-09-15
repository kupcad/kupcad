const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");

const StringId = @import("../cff.zig").StringId;
const Charset = @import("charset.zig").Charset;

const Encoding = @This();

kind: Kind,
supplemental: parser.LazyArray(u8, Supplement),

pub const new_standard: Encoding = .{
    .kind = .standard,
    .supplemental = .{},
};

pub const new_expert: Encoding = .{
    .kind = .expert,
    .supplemental = .{},
};

pub fn parse(
    s: *parser.Stream,
) parser.Error!Encoding {
    const has_supplemental, const format = f: {
        const format = try s.read(u8);
        // The first high-bit in format indicates that a Supplemental encoding is present.
        // Check it and clear.
        break :f .{ format & 0x80 != 0, format & 0x7f };
    };

    const count = try s.read(u8);
    const kind: Kind = switch (format) {
        0 => .{ .format0 = try s.read_array(u8, count) },
        1 => .{ .format1 = try s.read_array(Format1Range, count) },
        else => return error.ParseFail,
    };

    const supplemental: parser.LazyArray(u8, Supplement) = if (has_supplemental) s: {
        const suppl_count = try s.read(u8);
        break :s try s.read_array(Supplement, suppl_count);
    } else .{};

    return .{ .kind = kind, .supplemental = supplemental };
}

pub fn code_to_gid(
    self: Encoding,
    charset: Charset,
    code: u8,
) ?lib.GlyphId {
    {
        var iter = self.supplemental.iterator();
        while (iter.next()) |s|
            if (s.code == code)
                return charset.sid_to_gid(s.name);
    }

    const index: usize = code;

    switch (self.kind) {
        // Standard encodings store a StringID/SID and not GlyphID/GID.
        // Therefore we have to get SID first and then convert it to GID via Charset.
        // Custom encodings (FormatN) store GID directly.
        //
        // Indexing for predefined encodings never fails,
        // because `code` is always `u8` and encodings have 256 entries.
        //
        // We treat `Expert` as `Standard` as well, since we allow only 8bit codepoints.
        .standard, .expert => {
            const sid: StringId = .{(STANDARD_ENCODING[index])};
            return charset.sid_to_gid(sid);
        },
        .format0 => |table| {
            var iter = table.iterator();
            var i: u16 = 0;
            while (iter.next()) |c| : (i += 1) if (c == code) return .{i + 1};
            return null;
        },
        .format1 => |table| {
            // Starts from 1 because .notdef is implicit.
            var gid: u16 = 1;

            var iter = table.iterator();
            while (iter.next()) |range| : (gid += range.left + 1) {
                const end = range.first +| range.left;
                if (code >= range.first and code <= end) {
                    gid += (code - range.first);
                    return .{gid};
                }
            }
            return null;
        },
    }
}

pub const Kind = union(enum) {
    standard,
    expert,
    format0: parser.LazyArray(u8, u8),
    format1: parser.LazyArray(u8, Format1Range),
};

pub const Supplement = struct {
    code: u8,
    name: StringId,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 3;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

pub const Format1Range = struct {
    first: u8,
    left: u8,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 2;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// The Standard Encoding as defined in the Adobe Technical Note #5176 Appendix B.
pub const STANDARD_ENCODING: []const u8 = &.{
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,
    17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,
    33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,
    49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,
    65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,  80,
    81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,  0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   96,  97,  98,  99,  100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
    0,   111, 112, 113, 114, 0,   115, 116, 117, 118, 119, 120, 121, 122, 0,   123,
    0,   124, 125, 126, 127, 128, 129, 130, 131, 0,   132, 133, 0,   134, 135, 136,
    137, 0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   138, 0,   139, 0,   0,   0,   0,   140, 141, 142, 143, 0,   0,   0,   0,
    0,   144, 0,   0,   0,   145, 0,   0,   146, 147, 148, 149, 0,   0,   0,   0,
};
