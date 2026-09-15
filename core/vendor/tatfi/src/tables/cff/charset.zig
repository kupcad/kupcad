const std = @import("std");
const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");

const StringId = @import("../cff.zig").StringId;

pub const Charset = union(enum) {
    iso_adobe,
    expert,
    expert_subset,
    format0: parser.LazyArray16(StringId),
    format1: parser.LazyArray16(Format1Range),
    format2: parser.LazyArray16(Format2Range),

    pub fn parse_charset(
        number_of_glyphs: u16,
        s: *parser.Stream,
    ) parser.Error!Charset {
        // -1 everywhere, since `.notdef` is omitted.
        const format = try s.read(u8);
        switch (format) {
            0 => return .{ .format0 = try s.read_array(StringId, number_of_glyphs - 1) },
            1 => {
                // The number of ranges is not defined, so we have to
                // read until no glyphs are left.
                var count: u16 = 0;
                {
                    var s_cloned: parser.Stream = .{
                        .data = s.data,
                        .offset = s.offset,
                    };
                    var total_left = number_of_glyphs - 1;
                    while (total_left > 0) {
                        s_cloned.skip(StringId);
                        const left = try s_cloned.read(u8);
                        total_left = try std.math.sub(u16, total_left, left + 1);
                        count += 1;
                    }
                }

                return .{ .format1 = try s.read_array(Format1Range, count) };
            },
            2 => {
                // The same as format 1, but Range.left is u16.
                var count: u16 = 0;
                {
                    var s_cloned: parser.Stream = .{
                        .data = s.data,
                        .offset = s.offset,
                    };
                    var total_left = number_of_glyphs - 1;
                    while (total_left > 0) {
                        s_cloned.skip(StringId);
                        const left = try s_cloned.read(u16);
                        total_left = try std.math.sub(u16, total_left, left + 1);
                        count += 1;
                    }
                }
                return .{ .format2 = try s.read_array(Format2Range, count) };
            },
            else => return error.ParseFail,
        }
    }

    pub fn sid_to_gid(
        self: Charset,
        sid: StringId,
    ) ?lib.GlyphId {
        if (sid[0] == 0) return .{0};

        switch (self) {
            .iso_adobe,
            .expert,
            .expert_subset,
            => return null,
            .format0 => |array| {
                // First glyph is omitted, so we have to add 1.
                var iter = array.iterator();
                var pos: usize = 0;
                while (iter.next()) |n| : (pos += 1) {
                    if (n[0] == sid[0]) return .{@truncate(pos + 1)};
                } else return null;
            },
            .format1 => |array| {
                var id: u16 = 1;
                var iter = array.iterator();
                while (iter.next()) |range| {
                    const last = @as(u32, range.first[0]) + range.left;
                    if (range.first[0] <= sid[0] and sid[0] <= last) {
                        id += sid[0] - range.first[0];
                        return .{id};
                    }

                    id += range.left + 1;
                } else return null;
            },
            .format2 => |array| {
                // The same as format 1, but Range.left is u16.
                var id: u16 = 1;
                var iter = array.iterator();
                while (iter.next()) |range| {
                    const last = @as(u32, range.first[0]) + range.left;
                    if (range.first[0] <= sid[0] and sid[0] <= last) {
                        id += sid[0] - range.first[0];
                        return .{id};
                    }

                    id += range.left + 1;
                } else return null;
            },
        }
    }

    pub fn gid_to_sid(
        self: Charset,
        gid: lib.GlyphId,
    ) ?StringId {
        switch (self) {
            .iso_adobe => {
                if (gid[0] > 228) return null;
                return .{gid[0]};
            },
            .expert => {
                const id = gid[0];
                if (id >= EXPERT_ENCODING.len) return null;
                return .{EXPERT_ENCODING[id]};
            },
            .expert_subset => {
                const id = gid[0];
                if (id >= EXPERT_SUBSET_ENCODING.len) return null;
                return .{EXPERT_SUBSET_ENCODING[id]};
            },
            .format0 => |array| {
                const id = gid[0];
                if (id == 0) return .{0};
                return array.get(id - 1);
            },
            // format1, format2,
            inline else => |array| {
                const id = gid[0];
                if (id == 0) return .{0};

                var sid = id - 1;
                var iter = array.iterator();
                while (iter.next()) |range| {
                    if (sid <= range.left) {
                        sid = std.math.add(u16, sid, range.first[0]) catch return null;
                        return .{sid};
                    }

                    sid = std.math.sub(
                        u16,
                        sid,
                        std.math.add(u16, range.left, 1) catch return null,
                    ) catch return null;
                }

                return null;
            },
        }
    }
};

pub const Format1Range = struct {
    first: StringId,
    left: u8,

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

pub const Format2Range = struct {
    first: StringId,
    left: u16,

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

/// The Expert Encoding conversion as defined in the Adobe Technical Note #5176 Appendix C.
const EXPERT_ENCODING: []const u16 = &.{
    0,   1,   229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 13,  14,  15,  99,
    239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 27,  28,  249, 250, 251, 252,
    253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 109, 110,
    267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282,
    283, 284, 285, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298,
    299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314,
    315, 316, 317, 318, 158, 155, 163, 319, 320, 321, 322, 323, 324, 325, 326, 150,
    164, 169, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340,
    341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356,
    357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372,
    373, 374, 375, 376, 377, 378,
};

/// The Expert Subset Encoding conversion as defined in the Adobe Technical Note #5176 Appendix C.
const EXPERT_SUBSET_ENCODING: []const u16 = &.{
    0,   1,   231, 232, 235, 236, 237, 238, 13,  14,  15,  99,  239, 240, 241, 242,
    243, 244, 245, 246, 247, 248, 27,  28,  249, 250, 251, 253, 254, 255, 256, 257,
    258, 259, 260, 261, 262, 263, 264, 265, 266, 109, 110, 267, 268, 269, 270, 272,
    300, 301, 302, 305, 314, 315, 158, 155, 163, 320, 321, 322, 323, 324, 325, 326,
    150, 164, 169, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339,
    340, 341, 342, 343, 344, 345, 346,
};
