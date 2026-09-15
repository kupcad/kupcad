//! A [Naming Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/name) implementation.

const std = @import("std");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");

const Language = @import("../language.zig").Language;

const Table = @This();

/// A list of names.
names: Names = .{},

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    // https://docs.microsoft.com/en-us/typography/opentype/spec/name#naming-table-format-1
    const LANG_TAG_RECORD_SIZE: u16 = 4;

    var s = parser.Stream.new(data);

    const version = try s.read(u16);
    const count = try s.read(u16);
    const storage_offset: usize = (try s.read(parser.Offset16))[0];

    switch (version) {
        0 => {}, // Do nothing.
        1 => {
            const lang_tag_count = try s.read(u16);
            const lang_tag_len = try std.math.mul(u16, lang_tag_count, LANG_TAG_RECORD_SIZE);

            s.advance(lang_tag_len); // langTagRecords
        },
        else => return error.ParseFail, // Unsupported version.
    }

    const records = try s.read_array(NameRecord, count);

    if (s.offset < storage_offset)
        s.advance(storage_offset - s.offset);

    const storage = try s.tail();

    return .{ .names = .{
        .records = records,
        .storage = storage,
    } };
}

/// A list of face names.
pub const Names = struct {
    records: parser.LazyArray16(NameRecord) = .{},
    storage: []const u8 = &.{},

    /// Returns a name at index.
    pub fn get(
        self: Names,
        index: u16,
    ) ?Name {
        const record = self.records.get(index) orelse return null;

        return .{
            .platform_id = record.platform_id,
            .encoding_id = record.encoding_id,
            .language_id = record.language_id,
            .name_id = record.name_id,
            .name = utils.slice(self.storage, .{ record.offset[0], record.length }) catch return null,
        };
    }

    pub fn iterator(
        data: *const Names,
    ) Iterator {
        return .{ .names = data };
    }

    pub const Iterator = struct {
        names: *const Names,
        index: u16 = 0,

        pub fn next(
            self: *Iterator,
        ) ?Name {
            if (self.index >= self.names.records.len()) return null;
            defer self.index += 1;
            return self.names.get(self.index);
        }
    };
};

const NameRecord = struct {
    platform_id: PlatformId,
    encoding_id: u16,
    language_id: u16,
    name_id: NameId,
    length: u16,
    offset: parser.Offset16,

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

/// A [platform ID](https://docs.microsoft.com/en-us/typography/opentype/spec/name#platform-ids).
pub const PlatformId = enum {
    unicode,
    macintosh,
    iso,
    windows,
    custom,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 2;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            const u = std.mem.readInt(u16, data, .big);
            return switch (u) {
                0 => .unicode,
                1 => .macintosh,
                2 => .iso,
                3 => .windows,
                4 => .custom,
                else => error.ParseFail,
            };
        }
    };
};

/// A [Name Record](https://docs.microsoft.com/en-us/typography/opentype/spec/name#name-records).
pub const Name = struct {
    /// A platform ID.
    platform_id: PlatformId,
    /// A platform-specific encoding ID.
    encoding_id: u16,
    /// A language ID.
    language_id: u16,
    /// A [Name ID](https://docs.microsoft.com/en-us/typography/opentype/spec/name#name-ids).
    ///
    /// A predefined list of ID's can be found in the `name_id` module.
    name_id: NameId,
    /// A raw name data.
    ///
    /// Can be in any encoding. Can be empty. If it is unicode, it is UTF-16BE
    name: []const u8,

    /// Returns the Name's data as a UTF-8 string.
    ///
    /// Only Unicode names are supported. And since they are stored as UTF-16BE,
    /// we have to allocate.
    ///
    /// Supports:
    /// - Unicode Platform ID
    /// - Windows Platform ID + Symbol
    /// - Windows Platform ID + Unicode BMP
    pub fn to_string(
        self: Name,
        gpa: std.mem.Allocator,
    ) ?[]const u8 {
        if (self.is_unicode())
            return name_from_utf16_be(self.name, gpa) catch null
        else
            return null;
    }

    /// Checks that the current Name data has a Unicode encoding.
    pub fn is_unicode(
        self: Name,
    ) bool {
        // https://docs.microsoft.com/en-us/typography/opentype/spec/name#windows-encoding-ids
        const WINDOWS_SYMBOL_ENCODING_ID: u16 = 0;
        const WINDOWS_UNICODE_BMP_ENCODING_ID: u16 = 1;

        return switch (self.platform_id) {
            .unicode => true,
            .windows => self.encoding_id == WINDOWS_SYMBOL_ENCODING_ID or
                self.encoding_id == WINDOWS_UNICODE_BMP_ENCODING_ID,
            else => false,
        };
    }

    fn name_from_utf16_be(
        string: []const u8,
        gpa: std.mem.Allocator,
    ) ![]const u8 {
        var name: std.ArrayList(u16) = try .initCapacity(gpa, string.len); // double needed!
        defer name.deinit(gpa);

        var iter = std.mem.window(u8, string, 2, 2);
        while (iter.next()) |win| {
            if (win.len < 2) break;
            const c = std.mem.readInt(u16, win[0..2], .big);
            name.appendAssumeCapacity(c);
        }

        return try std.unicode.utf16LeToUtf8Alloc(gpa, name.items);
    }

    /// Returns a Name language.
    pub fn language(
        self: Name,
    ) Language {
        switch (self.platform_id) {
            .windows => return Language.windows_language(self.language_id),
            .macintosh => if (self.encoding_id == 0 and
                self.language_id == 0) return .English_UnitedStates,
            else => {},
        }
        return .Unknown;
    }
};

/// A list of [name ID](https://docs.microsoft.com/en-us/typography/opentype/spec/name#name-ids)'s.
pub const NameId = enum(u16) {
    copyright_notice = 0,
    family = 1,
    subfamily = 2,
    unique_id = 3,
    full_name = 4,
    version = 5,
    post_script_name = 6,
    trademark = 7,
    manufacturer = 8,
    designer = 9,
    description = 10,
    vendor_url = 11,
    designer_url = 12,
    license = 13,
    license_url = 14,
    reserved = 15,
    typographic_family = 16,
    typographic_subfamily = 17,
    compatible_full = 18,
    sample_text = 19,
    post_script_cid = 20,
    wws_family = 21,
    wws_subfamily = 22,
    light_background_palette = 23,
    dark_background_palette = 24,
    variations_post_script_name_prefix = 25,
    _,
};
