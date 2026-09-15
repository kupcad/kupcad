//! A [Glyph Positioning Table](https://docs.microsoft.com/en-us/typography/opentype/spec/gpos)
//! implementation.

// A heavily modified port of https://github.com/harfbuzz/rustybuzz implementation
// originally written by https://github.com/laurmaedje

const std = @import("std");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const ggg = @import("../ggg.zig");

/// A [Device Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#devVarIdxTbls).
pub const Device = union(enum) {
    hinting: HintingDevice,
    variation: VariationDevice,

    pub fn parse(
        data: []const u8,
    ) parser.Error!Device {
        var s = parser.Stream.new(data);
        const first = try s.read(u16);
        const second = try s.read(u16);
        const format = try s.read(u16);
        switch (format) {
            1...3 => {
                const start_size = first;
                const end_size = second;
                const count = (1 + (end_size - start_size)) >> (4 - @as(u4, @truncate(format)));
                const delta_values = try s.read_array(u16, count);
                return .{ .hinting = .{
                    .start_size = start_size,
                    .end_size = end_size,
                    .delta_format = format,
                    .delta_values = delta_values,
                } };
            },
            0x8000 => return .{ .variation = .{
                .outer_index = first,
                .inner_index = second,
            } },
            else => return error.ParseFail,
        }
    }
};

/// A [Device Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#devVarIdxTbls)
/// hinting values.
pub const HintingDevice = struct {
    start_size: u16,
    end_size: u16,
    delta_format: u16,
    delta_values: parser.LazyArray16(u16),

    /// Returns X-axis delta.
    pub fn x_delta(
        self: HintingDevice,
        units_per_em: u16,
        pixels_per_em: ?struct { u16, u16 },
    ) ?i32 {
        const x, _ = pixels_per_em orelse return null;
        return self.get_delta(x, units_per_em);
    }

    /// Returns Y-axis delta.
    pub fn y_delta(
        self: HintingDevice,
        units_per_em: u16,
        pixels_per_em: ?struct { u16, u16 },
    ) ?i32 {
        _, const y = pixels_per_em orelse return null;
        return self.get_delta(y, units_per_em);
    }

    fn get_delta(
        self: HintingDevice,
        ppem: u16,
        scale: u16,
    ) ?i32 {
        const f_16 = self.delta_format;
        std.debug.assert(f_16 >= 1 and f_16 <= 3);
        const f: u3 = @truncate(f_16);

        if (ppem == 0 or
            ppem < self.start_size or
            ppem > self.end_size) return null;

        const s = ppem - self.start_size;
        const byte = self.delta_values.get(s >> (4 - f)) orelse return null;
        // let bits = byte >> (16 - (((s & ((1 << (4 - f)) - 1)) + 1) << f)); // [ARS] TODO need to double check?
        const bits = byte >> @as(u4, @truncate(16 - (((s & ((@as(u16, 1) << (4 - f)) - 1)) + 1) << f)));
        // let mask = 0xFFFF >> (16 - (1 << f));
        const mask = @as(u16, 0xFFFF) >> @as(u4, @truncate(16 - (@as(u16, 1) << f)));

        var delta: i64 = bits & mask;
        if (delta >= ((mask + 1) >> 1))
            delta -= mask + 1;

        return std.math.cast(i32, delta * @divFloor(scale, ppem));
    }
};

/// A [Device Table](https://docs.microsoft.com/en-us/typography/opentype/spec/chapter2#devVarIdxTbls)
/// indexes into [Item Variation Store](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/otvarcommonformats#IVS).
pub const VariationDevice = struct {
    outer_index: u16,
    inner_index: u16,
};

/// A glyph positioning
/// [lookup subtable](https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#table-organization)
/// enumeration.
pub const PositioningSubtable = union(enum) {
    single: SingleAdjustment,
    pair: PairAdjustment,
    cursive: CursiveAdjustment,
    mark_to_base: MarkToBaseAdjustment,
    mark_to_ligature: MarkToLigatureAdjustment,
    mark_to_mark: MarkToMarkAdjustment,
    context: ggg.ContextLookup,
    chain_context: ggg.ChainedContextLookup,

    pub fn parse(
        data: []const u8,
        kind: u16,
    ) parser.Error!PositioningSubtable {
        return switch (kind) {
            1 => .{ .single = try .parse(data) },
            2 => .{ .pair = try .parse(data) },
            3 => .{ .cursive = try .parse(data) },
            4 => .{ .mark_to_base = try .parse(data) },
            5 => .{ .mark_to_ligature = try .parse(data) },
            6 => .{ .mark_to_mark = try .parse(data) },
            7 => .{ .context = try .parse(data) },
            8 => .{ .chain_context = try .parse(data) },
            9 => ggg.parse_extension_lookup(PositioningSubtable, data),
            else => return error.ParseFail,
        };
    }

    /// Returns the subtable coverage.
    pub fn coverage(
        self: PositioningSubtable,
    ) ggg.Coverage {
        return switch (self) {
            .cursive => |t| t.coverage,
            inline .single, .pair, .context, .chain_context => |t| t.coverage(),
            .mark_to_mark => |t| t.mark1_coverage,
            inline .mark_to_base, .mark_to_ligature => |t| t.mark_coverage,
        };
    }
};

/// A [Single Adjustment Positioning Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#SP).
pub const SingleAdjustment = union(enum) {
    format1: struct { coverage: ggg.Coverage, value: ValueRecord },
    format2: struct { coverage: ggg.Coverage, values: ValueRecordsArray },

    fn parse(
        data: []const u8,
    ) parser.Error!SingleAdjustment {
        var s = parser.Stream.new(data);
        switch (try s.read(u16)) {
            1 => {
                const offset = try s.read(parser.Offset16);
                const coverage_var = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                const flags = try s.read(ValueFormatFlags);
                const value = try ValueRecord.parse(data, &s, flags);
                return .{ .format1 = .{ .coverage = coverage_var, .value = value } };
            },
            2 => {
                const offset = try s.read(parser.Offset16);
                const coverage_var = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                const flags = try s.read(ValueFormatFlags);
                const count = try s.read(u16);
                const values = try ValueRecordsArray.parse(data, count, flags, &s);
                return .{ .format2 = .{ .coverage = coverage_var, .values = values } };
            },
            else => return error.ParseFail,
        }
    }

    /// Returns the subtable coverage.
    pub fn coverage(
        self: SingleAdjustment,
    ) ggg.Coverage {
        switch (self) {
            inline else => |f| return f.coverage,
        }
    }
};

/// A [Value Record](https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#value-record).
pub const ValueRecord = struct {
    /// Horizontal adjustment for placement, in design units.
    x_placement: i16 = 0,
    /// Vertical adjustment for placement, in design units.
    y_placement: i16 = 0,
    /// Horizontal adjustment for advance, in design units — only used for horizontal layout.
    x_advance: i16 = 0,
    /// Vertical adjustment for advance, in design units — only used for vertical layout.
    y_advance: i16 = 0,

    /// A `Device` table with horizontal adjustment for placement.
    x_placement_device: ?Device = null,
    /// A `Device` table with vertical adjustment for placement.
    y_placement_device: ?Device = null,
    /// A `Device` table with horizontal adjustment for advance.
    x_advance_device: ?Device = null,
    /// A `Device` table with vertical adjustment for advance.
    y_advance_device: ?Device = null,

    fn parse(
        table_data: []const u8,
        s: *parser.Stream,
        flags: ValueFormatFlags,
    ) parser.Error!ValueRecord {
        var record: ValueRecord = .{};

        if (flags.x_placement)
            record.x_placement = try s.read(i16);

        if (flags.y_placement)
            record.y_placement = try s.read(i16);

        if (flags.x_advance)
            record.x_advance = try s.read(i16);

        if (flags.y_advance)
            record.y_advance = try s.read(i16);

        if (flags.x_placement_device)
            if (try s.read_optional(parser.Offset16)) |offset| {
                const data = try utils.slice(table_data, offset[0]);
                record.x_placement_device = Device.parse(data) catch null;
            };

        if (flags.y_placement_device)
            if (try s.read_optional(parser.Offset16)) |offset| {
                const data = try utils.slice(table_data, offset[0]);
                record.y_placement_device = Device.parse(data) catch null;
            };

        if (flags.x_advance_device)
            if (try s.read_optional(parser.Offset16)) |offset| {
                const data = try utils.slice(table_data, offset[0]);
                record.x_advance_device = Device.parse(data) catch null;
            };

        if (flags.y_advance_device)
            if (try s.read_optional(parser.Offset16)) |offset| {
                const data = try utils.slice(table_data, offset[0]);
                record.y_advance_device = Device.parse(data) catch null;
            };

        return record;
    }
};

/// An array of
/// [Value Records](https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#value-record).
pub const ValueRecordsArray = struct {
    // We have to store the original table data because ValueRecords can have
    // a offset to Device tables and offset is from the beginning of the table.
    table_data: []const u8,
    // A slice that contains all ValueRecords.
    data: []const u8,
    // Number of records.
    len: u16,
    // Size of the single record.
    value_len: usize,
    // Flags, used during ValueRecord parsing.
    flags: ValueFormatFlags,

    fn parse(
        table_data: []const u8,
        count: u16,
        flags: ValueFormatFlags,
        s: *parser.Stream,
    ) parser.Error!ValueRecordsArray {
        return .{
            .table_data = table_data,
            .flags = flags,
            .len = count,
            .value_len = flags.size(),
            .data = try s.read_bytes(count * flags.size()),
        };
    }

    /// Returns a `ValueRecord` at index.
    pub fn get(
        self: ValueRecordsArray,
        index: u16,
    ) ?ValueRecord {
        const start = index * self.value_len;
        const data = utils.slice(self.data, .{ start, self.value_len }) catch return null;

        var s = parser.Stream.new(data);
        return ValueRecord.parse(self.table_data, &s, self.flags) catch null;
    }
};

const ValueFormatFlags = packed struct(u8) {
    x_placement: bool = false,
    y_placement: bool = false,
    x_advance: bool = false,
    y_advance: bool = false,
    x_placement_device: bool = false,
    y_placement_device: bool = false,
    x_advance_device: bool = false,
    y_advance_device: bool = false,

    // The ValueRecord struct constrain either i16 values or Offset16 offsets
    // and the total size depend on how many flags are enabled.
    fn size(
        self: ValueFormatFlags,
    ) usize {
        // The high 8 bits are not used, so make sure we ignore them using 0xFF.
        const backing: u8 = @bitCast(self);
        return @sizeOf(u16) * @popCount(backing);
    }

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 2;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            // There is no data in high 8 bits, so skip it.
            return @bitCast(data[1]);
        }
    };
};

/// A [Pair Adjustment Positioning Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#PP).
pub const PairAdjustment = union(enum) {
    format1: struct {
        coverage: ggg.Coverage,
        sets: PairSets,
    },
    format2: struct {
        coverage: ggg.Coverage,
        classes: struct { ggg.ClassDefinition, ggg.ClassDefinition },
        matrix: ClassMatrix,
    },

    fn parse(
        data: []const u8,
    ) parser.Error!PairAdjustment {
        var s = parser.Stream.new(data);
        switch (try s.read(u16)) {
            1 => {
                const offset = try s.read(parser.Offset16);
                const coverage_v = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                const flags = .{
                    try s.read(ValueFormatFlags),
                    try s.read(ValueFormatFlags),
                };
                const count = try s.read(u16);
                const offsets = try s.read_array(?parser.Offset16, count);
                return .{ .format1 = .{
                    .coverage = coverage_v,
                    .sets = .new(data, offsets, flags),
                } };
            },
            2 => {
                const offset = try s.read(parser.Offset16);
                const coverage_v = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
                const flags = .{
                    try s.read(ValueFormatFlags),
                    try s.read(ValueFormatFlags),
                };
                const classes = classes: {
                    const offset_1 = try s.read(parser.Offset16);
                    const offset_2 = try s.read(parser.Offset16);

                    break :classes .{
                        try ggg.ClassDefinition.parse(try utils.slice(data, offset_1[0])),
                        try ggg.ClassDefinition.parse(try utils.slice(data, offset_2[0])),
                    };
                };
                const counts = .{ try s.read(u16), try s.read(u16) };
                return .{ .format2 = .{
                    .coverage = coverage_v,
                    .classes = classes,
                    .matrix = try .parse(data, counts, flags, &s),
                } };
            },
            else => return error.ParseFail,
        }
    }

    /// Returns the subtable coverage.
    pub fn coverage(
        self: PairAdjustment,
    ) ggg.Coverage {
        switch (self) {
            inline else => |f| return f.coverage,
        }
    }
};

/// A list of `PairSet`s.
// Essentially a `LazyOffsetArray16` but stores additional data required to parse `PairSet`.
pub const PairSets = struct {
    data: []const u8,
    // Zero offsets must be ignored, therefore we're using `?Offset16`.
    offsets: parser.LazyArray16(?parser.Offset16),
    flags: struct { ValueFormatFlags, ValueFormatFlags },

    fn new(
        data: []const u8,
        offsets: parser.LazyArray16(?parser.Offset16),
        flags: struct { ValueFormatFlags, ValueFormatFlags },
    ) PairSets {
        return .{ .data = data, .offsets = offsets, .flags = flags };
    }

    /// Returns a value at `index`.
    pub fn get(
        self: PairSets,
        index: u16,
    ) ?PairSet {
        const offset = self.offsets.get_optional(index) orelse return null;
        const data = utils.slice(self.data, offset[0]) catch return null;
        return PairSet.parse(data, self.flags) catch null;
    }
};

/// A `ValueRecord` pairs set used by `PairAdjustment`.
pub const PairSet = struct {
    data: []const u8,
    flags: struct { ValueFormatFlags, ValueFormatFlags },
    record_len: u8,

    fn parse(
        data: []const u8,
        flags: struct { ValueFormatFlags, ValueFormatFlags },
    ) parser.Error!PairSet {
        var s = parser.Stream.new(data);
        const count = try s.read(u16);
        // Max len is 34, so u8 is just enough.
        const record_len: u8 = @truncate(parser.size_of(lib.GlyphId) + flags[0].size() + flags[1].size());
        return .{
            .data = try s.read_bytes(count * @as(usize, record_len)),
            .flags = flags,
            .record_len = record_len,
        };
    }

    fn binary_search(
        self: PairSet,
        second: lib.GlyphId,
    ) ?[]const u8 {
        // Based on Rust std implementation.

        var size = self.data.len / self.record_len;
        if (size == 0) return null;

        const get_record = struct {
            fn func(
                index: usize,
                set: PairSet,
            ) ?[]const u8 {
                const start = index * set.record_len;
                return utils.slice(set.data, .{ start, set.record_len }) catch null;
            }
        }.func;

        const get_glyph = struct {
            fn func(
                data: []const u8,
            ) lib.GlyphId {
                const bytes = data[0..2];
                return .{std.mem.readInt(u16, bytes, .big)};
            }
        }.func;

        var base: usize = 0;
        while (size > 1) {
            const half = size / 2;
            const mid = base + half;
            // mid is always in [0, size), that means mid is >= 0 and < size.
            // mid >= 0: by definition
            // mid < size: mid = size / 2 + size / 4 + size / 8 ...
            const glyph = get_glyph(get_record(mid, self) orelse return null);
            const cmp = std.math.order(glyph[0], second[0]);

            base = if (cmp == .gt) base else mid;
            size -= half;
        }

        // base is always in [0, size) because base <= mid.
        const value = get_record(base, self) orelse return null;
        const cmp = std.math.order(get_glyph(value)[0], second[0]);
        return if (cmp == .eq) value else null;
    }

    /// Returns a `ValueRecord` pair using the second glyph.
    pub fn get(
        self: PairSet,
        second: lib.GlyphId,
    ) parser.Error!struct { ValueRecord, ValueRecord } {
        const record_data = self.binary_search(second) orelse return error.ParseFail;
        var s = parser.Stream.new(record_data);
        s.skip(lib.GlyphId);
        return .{
            try .parse(self.data, &s, self.flags[0]),
            try .parse(self.data, &s, self.flags[0]),
        };
    }
};

/// A `ValueRecord` pairs matrix used by `PairAdjustment`.
pub const ClassMatrix = struct {
    // We have to store table's original slice,
    // because offsets in ValueRecords are from the begging of the table.
    table_data: []const u8,
    matrix: []const u8,
    counts: struct { u16, u16 },
    flags: struct { ValueFormatFlags, ValueFormatFlags },
    record_len: u8,

    fn parse(
        table_data: []const u8,
        counts: struct { u16, u16 },
        flags: struct { ValueFormatFlags, ValueFormatFlags },
        s: *parser.Stream,
    ) parser.Error!ClassMatrix {
        const count: usize = @as(u32, counts[0]) * @as(u32, counts[1]);
        // Max len is 32, so u8 is just enough.
        const record_len: u8 = @truncate(flags[0].size() + flags[1].size());
        const matrix = try s.read_bytes(count * record_len);
        return .{
            .table_data = table_data,
            .matrix = matrix,
            .counts = counts,
            .flags = flags,
            .record_len = record_len,
        };
    }

    /// Returns a `ValueRecord` pair using specified classes.
    pub fn get(
        self: ClassMatrix,
        classes: struct { u16, u16 },
    ) ?struct { ValueRecord, ValueRecord } {
        if (classes[0] >= self.counts[0] or
            classes[1] >= self.counts[1]) return null;

        const idx = @as(usize, classes[0]) * @as(usize, self.counts[1]) + @as(usize, classes[1]);
        const record_index = idx * @as(usize, self.record_len);

        const record = utils.slice(self.matrix, record_index) catch return null;

        var s = parser.Stream.new(record);
        return .{
            ValueRecord.parse(self.table_data, &s, self.flags[0]) catch return null,
            ValueRecord.parse(self.table_data, &s, self.flags[1]) catch return null,
        };
    }
};

/// A [Cursive Attachment Positioning Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#CAP).
pub const CursiveAdjustment = struct {
    coverage: ggg.Coverage,
    sets: CursiveAnchorSet,

    fn parse(
        data: []const u8,
    ) parser.Error!CursiveAdjustment {
        var s = parser.Stream.new(data);
        if ((try s.read(u16)) != 1) return error.ParseFail;

        const offset = try s.read(parser.Offset16);
        const coverage = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        const count = try s.read(u16);
        const records = try s.read_array(EntryExitRecord, count);
        return .{
            .coverage = coverage,
            .sets = .{ .data = data, .records = records },
        };
    }
};

/// A list of entry and exit `Anchor` pairs.
pub const CursiveAnchorSet = struct {
    data: []const u8,
    records: parser.LazyArray16(EntryExitRecord),
};

const EntryExitRecord = struct {
    entry_anchor_offset: ?parser.Offset16,
    exit_anchor_offset: ?parser.Offset16,

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

/// A [Mark-to-Base Attachment Positioning Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#MBP).
pub const MarkToBaseAdjustment = struct {
    /// A mark coverage.
    mark_coverage: ggg.Coverage,
    /// A base coverage.
    base_coverage: ggg.Coverage,
    /// A list of mark anchors.
    marks: MarkArray,
    /// An anchors matrix.
    anchors: AnchorMatrix,

    fn parse(
        data: []const u8,
    ) parser.Error!MarkToBaseAdjustment {
        var s = parser.Stream.new(data);
        if ((try s.read(u16)) != 1) return error.ParseFail;

        const mark_coverage = c: {
            const offset = try s.read(parser.Offset16);
            break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        };
        const base_coverage = c: {
            const offset = try s.read(parser.Offset16);
            break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        };

        const class_count = try s.read(u16);

        const marks = m: {
            const offset = try s.read(parser.Offset16);
            break :m try MarkArray.parse(try utils.slice(data, offset[0]));
        };

        const anchors = m: {
            const offset = try s.read(parser.Offset16);
            break :m try AnchorMatrix.parse(try utils.slice(data, offset[0]), class_count);
        };

        return .{
            .mark_coverage = mark_coverage,
            .base_coverage = base_coverage,
            .marks = marks,
            .anchors = anchors,
        };
    }
};

/// A [Mark Array](https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#mark-array-table).
pub const MarkArray = struct {
    data: []const u8,
    array: parser.LazyArray16(MarkRecord),

    fn parse(
        data: []const u8,
    ) parser.Error!MarkArray {
        var s = parser.Stream.new(data);
        const count = try s.read(u16);
        const array = try s.read_array(MarkRecord, count);
        return .{ .data = data, .array = array };
    }

    /// Returns contained data at index.
    pub fn get(
        self: MarkArray,
        index: u16,
    ) ?struct { ggg.Class, Anchor } {
        const record = self.array.get(index) orelse return null;
        const data = utils.slice(self.data, record.mark_anchor[0]) catch return null;
        const anchor = Anchor.parse(data) catch return null;

        return .{ record.class, anchor };
    }
};

const MarkRecord = struct {
    class: ggg.Class,
    mark_anchor: parser.Offset16,

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

/// An `Anchor` parsing helper.
pub const AnchorMatrix = struct {
    data: []const u8,
    /// Number of rows in the matrix.
    rows: u16,
    /// Number of columns in the matrix.
    cols: u16,
    matrix: parser.LazyArray32(?parser.Offset16),

    fn parse(
        data: []const u8,
        cols: u16,
    ) parser.Error!AnchorMatrix {
        var s = parser.Stream.new(data);
        const rows = try s.read(u16);
        const count = @as(u32, rows) * @as(u32, cols);
        const matrix = try s.read_array(?parser.Offset16, count);
        return .{
            .data = data,
            .rows = rows,
            .cols = cols,
            .matrix = matrix,
        };
    }

    /// Returns an `Anchor` at position.
    pub fn get(
        self: AnchorMatrix,
        row: u16,
        col: u16,
    ) ?Anchor {
        const idx = @as(u32, row) * @as(u32, self.cols) + @as(u32, col);
        const offset = self.matrix.get_optional(idx) orelse return null;
        const data = utils.slice(self.data, offset[0]) catch return null;
        return Anchor.parse(data) catch null;
    }
};

/// A [Mark-to-Ligature Attachment Positioning Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#MLP).
pub const MarkToLigatureAdjustment = struct {
    mark_coverage: ggg.Coverage,
    ligature_coverage: ggg.Coverage,
    marks: MarkArray,
    ligature_array: LigatureArray,

    fn parse(
        data: []const u8,
    ) parser.Error!MarkToLigatureAdjustment {
        var s = parser.Stream.new(data);
        if ((try s.read(u16)) != 1) return error.ParseFail;

        const mark_coverage = c: {
            const offset = try s.read(parser.Offset16);
            break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        };
        const ligature_coverage = c: {
            const offset = try s.read(parser.Offset16);
            break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        };

        const class_count = try s.read(u16);

        const marks = m: {
            const offset = try s.read(parser.Offset16);
            break :m try MarkArray.parse(try utils.slice(data, offset[0]));
        };

        const ligature_array = m: {
            const offset = try s.read(parser.Offset16);
            break :m try LigatureArray.parse(try utils.slice(data, offset[0]), class_count);
        };

        return .{
            .mark_coverage = mark_coverage,
            .ligature_coverage = ligature_coverage,
            .marks = marks,
            .ligature_array = ligature_array,
        };
    }
};

/// An array or ligature anchor matrices.
pub const LigatureArray = struct {
    data: []const u8,
    class_count: u16,
    offsets: parser.LazyArray16(parser.Offset16),

    fn parse(
        data: []const u8,
        class_count: u16,
    ) parser.Error!LigatureArray {
        var s = parser.Stream.new(data);
        const count = try s.read(u16);
        const offsets = try s.read_array(parser.Offset16, count);
        return .{
            .data = data,
            .class_count = class_count,
            .offsets = offsets,
        };
    }

    /// Returns an `AnchorMatrix` at index.
    pub fn get(
        self: LigatureArray,
        index: u16,
    ) ?AnchorMatrix {
        const offset = self.offsets.get(index) orelse return null;
        const data = utils.slice(self.data, offset[0]) catch return null;
        return AnchorMatrix.parse(data, self.class_count) catch null;
    }
};

/// A [Mark-to-Mark Attachment Positioning Subtable](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#MMP).
pub const MarkToMarkAdjustment = struct {
    mark1_coverage: ggg.Coverage,
    mark2_coverage: ggg.Coverage,
    marks: MarkArray,
    mark2_matrix: AnchorMatrix,

    fn parse(
        data: []const u8,
    ) parser.Error!MarkToMarkAdjustment {
        var s = parser.Stream.new(data);
        if ((try s.read(u16)) != 1) return error.ParseFail;

        const mark1_coverage = c: {
            const offset = try s.read(parser.Offset16);
            break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        };
        const mark2_coverage = c: {
            const offset = try s.read(parser.Offset16);
            break :c try ggg.Coverage.parse(try utils.slice(data, offset[0]));
        };

        const class_count = try s.read(u16);

        const marks = m: {
            const offset = try s.read(parser.Offset16);
            break :m try MarkArray.parse(try utils.slice(data, offset[0]));
        };

        const mark2_matrix = m: {
            const offset = try s.read(parser.Offset16);
            break :m try AnchorMatrix.parse(try utils.slice(data, offset[0]), class_count);
        };

        return .{
            .mark1_coverage = mark1_coverage,
            .mark2_coverage = mark2_coverage,
            .marks = marks,
            .mark2_matrix = mark2_matrix,
        };
    }
};

/// An [Anchor Table](https://docs.microsoft.com/en-us/typography/opentype/spec/gpos#anchor-tables).
///
/// The *Anchor Table Format 2: Design Units Plus Contour Point* is not supported.
pub const Anchor = struct {
    /// Horizontal value, in design units.
    x: i16,
    /// Vertical value, in design units.
    y: i16,
    /// A `Device` table with horizontal value.
    x_device: ?Device,
    /// A `Device` table with vertical value.
    y_device: ?Device,

    fn parse(
        data: []const u8,
    ) parser.Error!Anchor {
        var s = parser.Stream.new(data);
        const format = try s.read(u16);
        if (format < 1 and format > 3) return error.ParseFail;

        var table = Anchor{
            .x = try s.read(i16),
            .y = try s.read(i16),
            .x_device = null,
            .y_device = null,
        };

        // Note: Format 2 is not handled since there is currently no way to
        // get a glyph contour point by index.

        if (format == 3) {
            x: {
                const offset = try s.read_optional(parser.Offset16) orelse break :x;
                const device_data = utils.slice(data, offset[0]) catch break :x;
                table.x_device = Device.parse(device_data) catch null;
            }
            y: {
                const offset = try s.read_optional(parser.Offset16) orelse break :y;
                const device_data = utils.slice(data, offset[0]) catch break :y;
                table.y_device = Device.parse(device_data) catch null;
            }
        }

        return table;
    }
};
