//! A [Feature Name Table](
//! https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6feat.html) implementation.

const std = @import("std");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const name = @import("name.zig");

const Table = @This();

/// A list of feature names. Sorted by `FeatureName.feature`.
names: FeatureNames,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    if (try s.read(u32) != 0x00010000) return error.ParseFail; // version

    const count = try s.read(u16);
    try s.advance_checked(6); // reserved
    const records = try s.read_array(FeatureNameRecord, count);

    return .{ .names = .{
        .data = data,
        .records = records,
    } };
}

/// A list of feature names.
pub const FeatureNames = struct {
    data: []const u8,
    records: parser.LazyArray16(FeatureNameRecord),

    /// Returns a feature name at an index.
    pub fn get(
        self: FeatureNames,
        index: u16,
    ) ?FeatureName {
        const record = self.records.get(index) orelse return null;

        const data = utils.slice(self.data, record.setting_table_offset[0]) catch return null;
        var s = parser.Stream.new(data);
        const setting_names =
            s.read_array(SettingName, record.setting_table_records_count) catch return null;
        return .{
            .feature = record.feature,
            .setting_names = setting_names,
            .default_setting_index = if (record.flags.default_setting_index)
                record.default_setting_index
            else
                0,
            .exclusive = record.flags.exclusive,
            .name_index = record.name_index,
        };
    }

    /// Finds a feature name by ID.
    pub fn find(
        self: FeatureNames,
        feature: u16,
    ) ?FeatureName {
        const func = struct {
            fn func(n: FeatureNameRecord, f: u16) std.math.Order {
                return std.math.order(n.feature, f);
            }
        }.func;
        const index, _ = self.records.binary_search_by(feature, func) catch return null;
        return self.get(index);
    }

    pub fn iterator(
        self: *const FeatureNames,
    ) Iterator {
        return .{ .names = self };
    }

    pub const Iterator = struct {
        names: *const FeatureNames,
        index: u16 = 0,

        pub fn next(
            self: *Iterator,
        ) ?FeatureName {
            if (self.index < self.names.records.len()) {
                defer self.index += 1;
                return self.names.get(self.index);
            } else return null;
        }
    };
};

const FeatureNameRecord = struct {
    feature: u16,
    setting_table_records_count: u16,
    // Offset from the beginning of the table.
    setting_table_offset: parser.Offset32,
    flags: packed struct(u8) {
        _0: u6 = 0,
        default_setting_index: bool,
        exclusive: bool,
    },
    default_setting_index: u8,
    name_index: name.NameId,

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

/// A feature names.
pub const FeatureName = struct {
    /// The feature's ID.
    feature: u16,
    /// The feature's setting names.
    setting_names: parser.LazyArray16(SettingName),
    /// The index of the default setting in the `setting_names`.
    default_setting_index: u8,
    /// The feature's exclusive settings. If set, the feature settings are mutually exclusive.
    exclusive: bool,
    /// The `name` table index for the feature's name in a 256..32768 range.
    name_index: name.NameId,
};

/// A setting name.
pub const SettingName = struct {
    /// The setting.
    setting: u16,
    /// The `name` table index for the feature's name in a 256..32768 range.
    name_index: name.NameId,

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
