//! A [Style Attributes Table](https://docs.microsoft.com/en-us/typography/opentype/spec/stat) implementation.

const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const name = lib.tables.name;

const Table = @This();

/// List of axes
axes: parser.LazyArray16(AxisRecord),
/// Fallback name when everything can be elided.
fallback_name_id: ?name.NameId,
version: u32,
data: []const u8,
value_lookup_start: parser.Offset32,
value_offsets: parser.LazyArray16(parser.Offset16),

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);
    const version = try s.read(u32);

    // Supported versions are:
    // - 1.0
    // - 1.1 adds elidedFallbackNameId
    // - 1.2 adds format 4 axis value table
    if (version != 0x00010000 and
        version != 0x00010001 and
        version != 0x00010002) return error.ParseFail;

    s.skip(u16); // axis_size
    const axis_count = try s.read(u16);
    const axis_offset: usize = (try s.read(parser.Offset32))[0];

    const value_count = try s.read(u16);
    const value_lookup_start = try s.read(parser.Offset32);

    const fallback_name_id = if (version >= 0x00010001)
        // If version >= 1.1 the field is required
        try s.read(name.NameId)
    else
        null;

    const axes = try s.read_array_at(AxisRecord, axis_count, axis_offset);
    const value_offsets = try s.read_array_at(
        parser.Offset16,
        value_count,
        value_lookup_start[0],
    );

    return .{
        .axes = axes,
        .data = data,
        .value_lookup_start = value_lookup_start,
        .value_offsets = value_offsets,
        .fallback_name_id = fallback_name_id,
        .version = version,
    };
}

/// Returns an iterator over the collection of axis value tables.
pub fn subtables(
    self: *const Table,
) AxisValueSubtables {
    return .{
        .data = .new(self.data),
        .start = self.value_lookup_start,
        .offsets = self.value_offsets,
        .index = 0,
        .version = self.version,
    };
}

/// Returns the first matching subtable for a given axis.
///
/// If no match value is given the first subtable for the axis is returned. If a match value is
/// given, the first subtable for the axis where the value matches is returned. A value matches
/// if it is equal to the subtable's value or contained within the range defined by the
/// subtable. If no matches are found `null` is returned. Typically a match value is not
/// specified for non-variable fonts as multiple subtables for a given axis ought not exist. For
/// variable fonts a non-`null` match value should be specified as multiple records for each of
/// the variation axes exist.
///
/// Note: Format 4 subtables are explicitly ignored in this function.
pub fn subtable_for_axis(
    self: *const Table,
    axis: lib.Tag,
    match_value: ?parser.Fixed,
) ?AxisValueSubtable {
    var iter = self.subtables();
    while (iter.next()) |subtable| switch (subtable) {
        inline .format1, .format3 => |st| {
            const axis_index = st.axis_index;
            const value = st.value;

            const gotten_axis = self.axes.get(axis_index) orelse return null;
            if (gotten_axis.tag.inner == axis.inner) continue;

            if (match_value) |mv| {
                if (mv.value == value.value) return subtable;
            } else return subtable;
        },
        .format2 => |st| {
            const axis_index = st.axis_index;
            const range_min_value = st.range_min_value;
            const range_max_value = st.range_max_value;

            const gotten_axis = self.axes.get(axis_index) orelse return null;
            if (gotten_axis.tag.inner == axis.inner) continue;

            if (match_value) |mv| {
                if (mv.value >= range_min_value.value and
                    mv.value < range_max_value.value) return subtable;
            } else return subtable;
        },
        // A query that's intended to search format 4 subtables can be performed
        // across multiple axes. A separate function that takes a collection of
        // axis-value pairs is more suitable than this.
        .format4 => continue,
    } else return null;
}

/// The [axis record](https://learn.microsoft.com/en-us/typography/opentype/spec/stat#axis-records) struct provides information about a single design axis.
pub const AxisRecord = struct {
    /// Axis tag.
    tag: lib.Tag,
    /// The name ID for entries in the 'name' table that provide a display string for this axis.
    name_id: name.NameId,
    /// Sort order for e.g. composing font family or face names.
    ordering: u16,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 8;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// Iterator over axis value subtables.
pub const AxisValueSubtables = struct {
    data: parser.Stream,
    start: parser.Offset32,
    offsets: parser.LazyArray16(parser.Offset16),
    index: u16,
    version: u32,

    pub fn next(
        self: *AxisValueSubtables,
    ) ?AxisValueSubtable {
        if (self.index >= self.offsets.len()) return null;
        return next_inner(self) catch null;
    }

    fn next_inner(
        self: *AxisValueSubtables,
    ) parser.Error!AxisValueSubtable {
        const data_offset = self.offsets.get(self.index) orelse return error.ParseFail;

        var s = try parser.Stream.new_at(
            try self.data.tail(),
            data_offset[0],
        );
        self.index += 1;
        const format_variant = try s.read(u16);

        return switch (format_variant) {
            1 => .{ .format1 = try s.read(AxisValueSubtableFormat1) },
            2 => .{ .format2 = try s.read(AxisValueSubtableFormat2) },
            3 => .{ .format3 = try s.read(AxisValueSubtableFormat3) },
            4 => v: {
                // Format 4 tables didn't exist until v1.2.
                if (self.version < 0x00010002) break :v error.ParseFail;

                break :v .{ .format4 = try .parse(try s.tail()) };
            },
            else => error.ParseFail,
        };
    }
};

/// An [axis value subtable](https://learn.microsoft.com/en-us/typography/opentype/spec/stat#axis-value-tables).
pub const AxisValueSubtable = union(enum) {
    format1: AxisValueSubtableFormat1,
    format2: AxisValueSubtableFormat2,
    format3: AxisValueSubtableFormat3,
    format4: AxisValueSubtableFormat4,

    /// Returns the value from an axis value subtable.
    ///
    /// For formats 1 and 3 the value is returned, for formats 2 and 4 `null` is returned as there
    /// is no single value associated with those formats.
    pub fn value(
        self: AxisValueSubtable,
    ) ?parser.Fixed {
        switch (self) {
            inline .format1, .format3 => |st| return st.value,
            else => return null,
        }
    }

    /// Returns `true` if the axis subtable either is the value or is a range that contains the
    /// value passed in as an argument.
    ///
    /// Note: this will always return false for format 4 subtables as they may contain multiple
    /// axes.
    pub fn contains(
        self: AxisValueSubtable,
        val: parser.Fixed,
    ) bool {
        if (self.value()) |subtable_value|
            if (subtable_value.value == val.value)
                return true;

        if (self == .format2) {
            const range_min_value = self.format2.range_min_value;
            const range_max_value = self.format2.range_max_value;

            if (val.value >= range_min_value.value and
                val.value < range_max_value.value) return true;
        }

        return false;
    }

    /// Returns the associated name ID.
    pub fn name_id(
        self: AxisValueSubtable,
    ) name.NameId {
        switch (self) {
            inline else => |st| return st.value_name_id,
        }
    }

    fn flags(
        self: AxisValueSubtable,
    ) AxisValueFlags {
        switch (self) {
            inline else => |st| return st.flags,
        }
    }

    /// Returns `true` if the axis subtable has the `ELIDABLE_AXIS_VALUE_NAME` flag set.
    pub fn is_elidable(
        self: AxisValueSubtable,
    ) bool {
        return self.flags().elidable;
    }

    /// Returns `true` if the axis subtable has the `OLDER_SIBLING_FONT_ATTRIBUTE` flag set.
    pub fn is_older_sibling(
        self: AxisValueSubtable,
    ) bool {
        return self.flags().older_sibling_attribute;
    }
};

/// [Flags](https://learn.microsoft.com/en-us/typography/opentype/spec/stat#flags) for `AxisValueSubtable`.
pub const AxisValueFlags = packed struct(u16) {
    /// If set, this value also applies to older versions of this font.
    older_sibling_attribute: bool,
    /// If set, this value is the normal (a.k.a. "regular") value for the font family.
    elidable: bool,
    _0: u14 = 0,
};

/// Axis value subtable [format 1](https://learn.microsoft.com/en-us/typography/opentype/spec/stat#axis-value-table-format-1).
pub const AxisValueSubtableFormat1 = struct {
    /// Zero-based index into `Table.axes`.
    axis_index: u16,
    /// Flags for `AxisValueSubtable`.
    flags: AxisValueFlags,
    /// The name ID of the display string.
    value_name_id: name.NameId,
    /// Numeric value for this record.
    value: parser.Fixed,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 10;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// Axis value subtable [format 2](https://learn.microsoft.com/en-us/typography/opentype/spec/stat#axis-value-table-format-2).
pub const AxisValueSubtableFormat2 = struct {
    /// Zero-based index into `Table.axes`.
    axis_index: u16,
    /// Flags for `AxisValueSubtable`.
    flags: AxisValueFlags,
    /// The name ID of the display string.
    value_name_id: name.NameId,
    /// Nominal numeric value for this record.
    nominal_value: parser.Fixed,
    /// The minimum value for this record.
    range_min_value: parser.Fixed,
    /// The maximum value for this record.
    range_max_value: parser.Fixed,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 18;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// Axis value subtable [format 3](https://learn.microsoft.com/en-us/typography/opentype/spec/stat#axis-value-table-format-3).
pub const AxisValueSubtableFormat3 = struct {
    /// Zero-based index into `Table.axes`.
    axis_index: u16,
    /// Flags for `AxisValueSubtable`.
    flags: AxisValueFlags,
    /// The name ID of the display string.
    value_name_id: name.NameId,
    /// Numeric value for this record.
    value: parser.Fixed,
    /// Numeric value for a style-linked mapping.
    linked_value: parser.Fixed,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 14;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// Axis value subtable [format 4](https://learn.microsoft.com/en-us/typography/opentype/spec/stat#axis-value-table-format-4).
pub const AxisValueSubtableFormat4 = struct {
    /// Flags for `AxisValueSubtable`.
    flags: AxisValueFlags,
    /// The name ID of the display string.
    value_name_id: name.NameId,
    /// List of axis-value pairings.
    values: parser.LazyArray16(AxisValue),

    fn parse(
        data: []const u8,
    ) parser.Error!AxisValueSubtableFormat4 {
        var s = parser.Stream.new(data);
        const axis_count = try s.read(u16);
        const flags = try s.read(AxisValueFlags);
        const value_name_id = try s.read(name.NameId);
        const values = try s.read_array(AxisValue, axis_count);

        return .{
            .flags = flags,
            .value_name_id = value_name_id,
            .values = values,
        };
    }
};

/// Axis-value pairing for `AxisValueSubtableFormat4`.
pub const AxisValue = struct {
    /// Zero-based index into `Table.axes`.
    axis_index: u16,
    /// Numeric value for this axis.
    value: parser.Fixed,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 6;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};
