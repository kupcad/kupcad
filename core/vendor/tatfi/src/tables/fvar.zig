//! A [Font Variations Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/fvar) implementation.

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const name = lib.tables.name;

const Table = @This();

/// A list of variation axes.
axes: parser.LazyArray16(VariationAxis),
/// A list of instance records
instances: Instances,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    const version = try s.read(u32);
    if (version != 0x00010000) return error.ParseFail;

    const axes_array_offset = try s.read(parser.Offset16);
    s.skip(u16); // reserved
    const axis_count = try s.read(u16);
    const axis_sixe = try s.read(u16);

    if (axis_sixe != VariationAxis.FromData.SIZE) return error.DataError;

    const instance_count = try s.read(u16);
    const instance_size = try s.read(u16);

    // 'If axisCount is zero, then the font is not functional as a variable font,
    // and must be treated as a non-variable font;
    // any variation-specific tables or data is ignored.'
    if (axis_count == 0) return error.ParseFail;

    s.offset = axes_array_offset[0];
    const axes = try s.read_array(VariationAxis, axis_count);

    // Validate instance record size: must be base or base + 2 (for psNameID).
    const base = 4 + (parser.size_of(parser.Fixed) * axis_count);
    if (instance_size != base and instance_size != base + 2) return error.ParseFail;

    const total_instances_len = try std.math.mul(usize, instance_count, instance_size);

    const inst_data = try s.read_bytes(total_instances_len);
    const instances: Instances = .new(
        inst_data,
        instance_size,
        axis_count,
        instance_count,
    );

    return .{
        .axes = axes,
        .instances = instances,
    };
}

/// A [variation axis](https://docs.microsoft.com/en-us/typography/opentype/spec/fvar#variationaxisrecord).
pub const VariationAxis = struct {
    tag: lib.Tag,
    min_value: f32,
    def_value: f32,
    max_value: f32,
    name_id: name.NameId,
    hidden: bool,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 20;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            var s = parser.Stream.new(data);

            const tag = try s.read(lib.Tag);
            const min_value = try s.read(parser.Fixed);
            const def_value = try s.read(parser.Fixed);
            const max_value = try s.read(parser.Fixed);
            const flags = try s.read(packed struct(u16) { hidden: bool, _1: u15 = 0 });
            const name_id = try s.read(name.NameId);

            return .{
                .tag = tag,
                .min_value = @min(def_value.value, min_value.value),
                .def_value = def_value.value,
                .max_value = @max(def_value.value, max_value.value),
                .name_id = name_id,
                .hidden = flags.hidden,
            };
        }
    };

    /// Returns a normalized variation coordinate for this axis.
    pub fn normalized_value(
        self: VariationAxis,
        value: f32,
    ) lib.NormalizedCoordinate {
        var v = value;

        // Based on
        // https://docs.microsoft.com/en-us/typography/opentype/spec/avar#overview
        v = std.math.clamp(v, self.min_value, self.max_value);

        v = if (v == self.def_value)
            0.0
        else if (v < self.def_value)
            (v - self.def_value) / (self.def_value - self.min_value)
        else
            (v - self.def_value) / (self.max_value - self.def_value);

        return .from(v);
    }
};

pub const Instances = struct {
    data: []const u8,
    record_len: u16,
    axis_count: u16,
    count: u16,

    pub fn iterator(
        self: *const Instances,
    ) Iterator {
        return .{ .data = self };
    }

    pub const Iterator = struct {
        data: *const Instances,
        index: u16 = 0,

        pub fn next(
            self: *Iterator,
        ) ?Instance {
            if (self.index < self.data.count) {
                defer self.index += 1;
                return self.data.get(self.index);
            } else return null;
        }
    };

    fn new(
        data: []const u8,
        record_len: u16,
        axis_count: u16,
        count: u16,
    ) Instances {
        return .{
            .data = data,
            .record_len = record_len,
            .axis_count = axis_count,
            .count = count,
        };
    }

    /// Returns the instance at the given index.
    ///
    /// Returns `null` if the index is out of bounds.
    pub fn get(
        self: Instances,
        index: u16,
    ) ?Instance {
        if (index >= self.count) return null;
        const len: usize = self.record_len;
        const start = index * len;
        const record = utils.slice(self.data, .{ start, len }) catch return null;
        return Instance.parse(record, self.axis_count) catch null;
    }

    pub const Instance = struct {
        /// The name ID for entries in the 'name' table that provide subfamily names for this instance.
        subfamily_name_id: name.NameId,
        /// The coordinate array for this instance (length = axisCount).
        coordinates: parser.LazyArray16(parser.Fixed),
        /// The name ID for entries in the 'name' table that provide PostScript names for this instance.
        post_script_name_id: ?name.NameId,

        fn parse(
            record: []const u8,
            axis_count: u16,
        ) parser.Error!Instance {
            var s: parser.Stream = .new(record);

            const subfamily_name_id = try s.read(name.NameId);
            s.skip(u16); // reserved
            const coordinates = try s.read_array(parser.Fixed, axis_count);
            const post_script_name_id = s.read(name.NameId) catch null;

            return .{
                .subfamily_name_id = subfamily_name_id,
                .coordinates = coordinates,
                .post_script_name_id = post_script_name_id,
            };
        }
    };
};
