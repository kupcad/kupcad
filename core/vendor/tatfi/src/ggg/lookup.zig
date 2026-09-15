const parser = @import("../parser.zig");
const utils = @import("../utils.zig");

const gpos = @import("../tables/gpos.zig");
const gsub = @import("../tables/gsub.zig");

/// used as a generic parameter for Lookup Subtables
// order is important
pub const LookupSubtable = enum(u1) { gsub = 0, gpos = 1 };

/// A list of `Lookup` values.
pub fn LookupList(subtable: LookupSubtable) type {
    return parser.LazyOffsetArray16(Lookup(subtable));
}

/// A [Lookup Table](https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#lookup-table).
pub fn Lookup(subtable: LookupSubtable) type {
    return struct {
        /// Lookup qualifiers.
        flags: LookupFlags,
        /// Available subtables.
        subtables: LookupSubtables(subtable),
        /// Index into GDEF mark glyph sets structure.
        mark_filtering_set: ?u16,

        const Self = @This();

        pub fn parse(
            data: []const u8,
        ) parser.Error!Self {
            var s = parser.Stream.new(data);
            const kind = try s.read(u16);
            const flags = try s.read(LookupFlags);
            const count = try s.read(u16);
            const offsets = try s.read_array(parser.Offset16, count);

            var mark_filtering_set: ?u16 = null;
            if (flags.use_mark_filtering_set) {
                mark_filtering_set = try s.read(u16);
            }

            return .{
                .flags = flags,
                .subtables = .{
                    .kind = kind,
                    .data = data,
                    .offsets = offsets,
                },
                .mark_filtering_set = mark_filtering_set,
            };
        }
    };
}

/// Lookup table flags.
pub const LookupFlags = packed struct(u16) {
    right_to_left: bool = false,
    ignore_base_glyphs: bool = false,
    ignore_ligatures: bool = false,
    ignore_marks: bool = false,
    use_mark_filtering_set: bool = false,
    _0: u3 = 0,
    mark_attachment_type: u8 = 0,

    pub fn ignore_flags(self: LookupFlags) bool {
        //  self & 0x000E != 0
        return self.ignore_base_glyphs or
            self.ignore_ligatures or
            self.ignore_marks;
    }
};

/// A list of lookup subtables.
pub fn LookupSubtables(kind: LookupSubtable) type {
    const T = switch (kind) {
        .gpos => gpos.PositioningSubtable,
        .gsub => gsub.SubstitutionSubtable,
    };

    return struct {
        kind: u16,
        data: []const u8,
        offsets: parser.LazyArray16(parser.Offset16),

        const Self = @This();

        /// Returns a number of items in the LookupSubtables.
        pub fn len(
            self: Self,
        ) u16 {
            return self.offsets.len();
        }

        /// Parses a subtable at index.
        ///
        /// Accepts either `gpos.PositioningSubtable` or `gsub.SubstitutionSubtable`
        pub fn get(
            self: Self,
            index: u16,
        ) ?T {
            const offset = self.offsets.get(index) orelse return null;
            const data = utils.slice(self.data, offset[0]) catch return null;
            return T.parse(data, self.kind) catch null;
        }

        pub fn iterator(
            data: *const Self,
        ) Iterator {
            return .{ .data = data };
        }

        pub const Iterator = struct {
            data: *const Self,
            index: u16 = 0,

            pub fn next(
                self: *Iterator,
            ) ?T {
                if (self.index < self.data.len()) {
                    defer self.index += 1;
                    return self.data.get(self.index);
                } else return null;
            }
        };
    };
}

pub fn parse_extension_lookup(
    T: type,
    data: []const u8,
) parser.Error!T {
    var s = parser.Stream.new(data);
    if (try s.read(u16) != 1) return error.ParseFail;

    const kind = try s.read(u16);
    const offset = try s.read(parser.Offset32);
    return T.parse(try utils.slice(data, offset[0]), kind);
}
