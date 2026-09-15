//! A [Math Table](https://docs.microsoft.com/en-us/typography/opentype/spec/math) implementation.

const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const ggg = @import("../ggg.zig");

const Device = @import("gpos.zig").Device;

const Table = @This();

/// Math positioning constants.
constants: ?Constants,
/// Per-glyph positioning information.
glyph_info: ?GlyphInfo,
/// Variants and assembly recipes for growable glyphs.
variants: ?Variants,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    if (try s.read(u16) != 1) return error.ParseFail; // major version
    s.skip(u16); // minor version

    const constants = parse_at_offset(Constants, &s, data) catch null;
    const glyph_info = parse_at_offset(GlyphInfo, &s, data) catch null;
    const variants = parse_at_offset(Variants, &s, data) catch null;

    return .{
        .constants = constants,
        .glyph_info = glyph_info,
        .variants = variants,
    };
}

/// A [Math Constants Table](https://learn.microsoft.com/en-us/typography/opentype/spec/math#mathconstants-table).
pub const Constants = struct {
    data: []const u8,

    fn parse(
        data: []const u8,
    ) parser.Error!Constants {
        return .{ .data = data };
    }

    const SCRIPT_PERCENT_SCALE_DOWN_OFFSET: usize = 0;
    const SCRIPT_SCRIPT_PERCENT_SCALE_DOWN_OFFSET: usize = 2;
    const DELIMITED_SUB_FORMULA_MIN_HEIGHT_OFFSET: usize = 4;
    const DISPLAY_OPERATOR_MIN_HEIGHT_OFFSET: usize = 6;
    const MATH_LEADING_OFFSET: usize = 8;
    const AXIS_HEIGHT_OFFSET: usize = 12;
    const ACCENT_BASE_HEIGHT_OFFSET: usize = 16;
    const FLATTENED_ACCENT_BASE_HEIGHT_OFFSET: usize = 20;
    const SUBSCRIPT_SHIFT_DOWN_OFFSET: usize = 24;
    const SUBSCRIPT_TOP_MAX_OFFSET: usize = 28;
    const SUBSCRIPT_BASELINE_DROP_MIN_OFFSET: usize = 32;
    const SUPERSCRIPT_SHIFT_UP_OFFSET: usize = 36;
    const SUPERSCRIPT_SHIFT_UP_CRAMPED_OFFSET: usize = 40;
    const SUPERSCRIPT_BOTTOM_MIN_OFFSET: usize = 44;
    const SUPERSCRIPT_BASELINE_DROP_MAX_OFFSET: usize = 48;
    const SUB_SUPERSCRIPT_GAP_MIN_OFFSET: usize = 52;
    const SUPERSCRIPT_BOTTOM_MAX_WITH_SUBSCRIPT_OFFSET: usize = 56;
    const SPACE_AFTER_SCRIPT_OFFSET: usize = 60;
    const UPPER_LIMIT_GAP_MIN_OFFSET: usize = 64;
    const UPPER_LIMIT_BASELINE_RISE_MIN_OFFSET: usize = 68;
    const LOWER_LIMIT_GAP_MIN_OFFSET: usize = 72;
    const LOWER_LIMIT_BASELINE_DROP_MIN_OFFSET: usize = 76;
    const STACK_TOP_SHIFT_UP_OFFSET: usize = 80;
    const STACK_TOP_DISPLAY_STYLE_SHIFT_UP_OFFSET: usize = 84;
    const STACK_BOTTOM_SHIFT_DOWN_OFFSET: usize = 88;
    const STACK_BOTTOM_DISPLAY_STYLE_SHIFT_DOWN_OFFSET: usize = 92;
    const STACK_GAP_MIN_OFFSET: usize = 96;
    const STACK_DISPLAY_STYLE_GAP_MIN_OFFSET: usize = 100;
    const STRETCH_STACK_TOP_SHIFT_UP_OFFSET: usize = 104;
    const STRETCH_STACK_BOTTOM_SHIFT_DOWN_OFFSET: usize = 108;
    const STRETCH_STACK_GAP_ABOVE_MIN_OFFSET: usize = 112;
    const STRETCH_STACK_GAP_BELOW_MIN_OFFSET: usize = 116;
    const FRACTION_NUMERATOR_SHIFT_UP_OFFSET: usize = 120;
    const FRACTION_NUMERATOR_DISPLAY_STYLE_SHIFT_UP_OFFSET: usize = 124;
    const FRACTION_DENOMINATOR_SHIFT_DOWN_OFFSET: usize = 128;
    const FRACTION_DENOMINATOR_DISPLAY_STYLE_SHIFT_DOWN_OFFSET: usize = 132;
    const FRACTION_NUMERATOR_GAP_MIN_OFFSET: usize = 136;
    const FRACTION_NUM_DISPLAY_STYLE_GAP_MIN_OFFSET: usize = 140;
    const FRACTION_RULE_THICKNESS_OFFSET: usize = 144;
    const FRACTION_DENOMINATOR_GAP_MIN_OFFSET: usize = 148;
    const FRACTION_DENOM_DISPLAY_STYLE_GAP_MIN_OFFSET: usize = 152;
    const SKEWED_FRACTION_HORIZONTAL_GAP_OFFSET: usize = 156;
    const SKEWED_FRACTION_VERTICAL_GAP_OFFSET: usize = 160;
    const OVERBAR_VERTICAL_GAP_OFFSET: usize = 164;
    const OVERBAR_RULE_THICKNESS_OFFSET: usize = 168;
    const OVERBAR_EXTRA_ASCENDER_OFFSET: usize = 172;
    const UNDERBAR_VERTICAL_GAP_OFFSET: usize = 176;
    const UNDERBAR_RULE_THICKNESS_OFFSET: usize = 180;
    const UNDERBAR_EXTRA_DESCENDER_OFFSET: usize = 184;
    const RADICAL_VERTICAL_GAP_OFFSET: usize = 188;
    const RADICAL_DISPLAY_STYLE_VERTICAL_GAP_OFFSET: usize = 192;
    const RADICAL_RULE_THICKNESS_OFFSET: usize = 196;
    const RADICAL_EXTRA_ASCENDER_OFFSET: usize = 200;
    const RADICAL_KERN_BEFORE_DEGREE_OFFSET: usize = 204;
    const RADICAL_KERN_AFTER_DEGREE_OFFSET: usize = 208;
    const RADICAL_DEGREE_BOTTOM_RAISE_PERCENT_OFFSET: usize = 212;

    /// Percentage of scaling down for level 1 superscripts and subscripts.
    pub fn script_percent_scale_down(
        self: Constants,
    ) i16 {
        return self.read(i16, SCRIPT_PERCENT_SCALE_DOWN_OFFSET);
    }

    /// Percentage of scaling down for level 2 (scriptScript) superscripts and subscripts.
    pub fn script_script_percent_scale_down(
        self: Constants,
    ) i16 {
        return self.read(i16, SCRIPT_SCRIPT_PERCENT_SCALE_DOWN_OFFSET);
    }

    /// Minimum height required for a delimited expression (contained within parentheses, etc.) to
    /// be treated as a sub-formula.
    pub fn delimited_sub_formula_min_height(
        self: Constants,
    ) u16 {
        return self.read(u16, DELIMITED_SUB_FORMULA_MIN_HEIGHT_OFFSET);
    }

    /// Minimum height of n-ary operators (such as integral and summation) for formulas in display
    /// mode (that is, appearing as standalone page elements, not embedded inline within text).
    pub fn display_operator_min_height(
        self: Constants,
    ) u16 {
        return self.read(u16, DISPLAY_OPERATOR_MIN_HEIGHT_OFFSET);
    }

    /// White space to be left between math formulas to ensure proper line spacing.
    pub fn math_leading(
        self: Constants,
    ) MathValue {
        return self.read_record(MATH_LEADING_OFFSET);
    }

    /// Axis height of the font.
    pub fn axis_height(
        self: Constants,
    ) MathValue {
        return self.read_record(AXIS_HEIGHT_OFFSET);
    }

    /// Maximum (ink) height of accent base that does not require raising the accents.
    pub fn accent_base_height(
        self: Constants,
    ) MathValue {
        return self.read_record(ACCENT_BASE_HEIGHT_OFFSET);
    }

    /// Maximum (ink) height of accent base that does not require flattening the accents.
    pub fn flattened_accent_base_height(
        self: Constants,
    ) MathValue {
        return self.read_record(FLATTENED_ACCENT_BASE_HEIGHT_OFFSET);
    }

    /// The standard shift down applied to subscript elements.
    pub fn subscript_shift_down(
        self: Constants,
    ) MathValue {
        return self.read_record(SUBSCRIPT_SHIFT_DOWN_OFFSET);
    }

    /// Maximum allowed height of the (ink) top of subscripts that does not require moving
    /// subscripts further down.
    pub fn subscript_top_max(
        self: Constants,
    ) MathValue {
        return self.read_record(SUBSCRIPT_TOP_MAX_OFFSET);
    }

    /// Minimum allowed drop of the baseline of subscripts relative to the (ink) bottom of the
    /// base.
    pub fn subscript_baseline_drop_min(
        self: Constants,
    ) MathValue {
        return self.read_record(SUBSCRIPT_BASELINE_DROP_MIN_OFFSET);
    }

    /// Standard shift up applied to superscript elements.
    pub fn superscript_shift_up(
        self: Constants,
    ) MathValue {
        return self.read_record(SUPERSCRIPT_SHIFT_UP_OFFSET);
    }

    /// Standard shift of superscripts relative to the base, in cramped style.
    pub fn superscript_shift_up_cramped(
        self: Constants,
    ) MathValue {
        return self.read_record(SUPERSCRIPT_SHIFT_UP_CRAMPED_OFFSET);
    }

    /// Minimum allowed height of the (ink) bottom of superscripts that does not require moving
    /// subscripts further up.
    pub fn superscript_bottom_min(
        self: Constants,
    ) MathValue {
        return self.read_record(SUPERSCRIPT_BOTTOM_MIN_OFFSET);
    }

    /// Maximum allowed drop of the baseline of superscripts relative to the (ink) top of the
    /// base.
    pub fn superscript_baseline_drop_max(
        self: Constants,
    ) MathValue {
        return self.read_record(SUPERSCRIPT_BASELINE_DROP_MAX_OFFSET);
    }

    /// Minimum gap between the superscript and subscript ink.
    pub fn sub_superscript_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(SUB_SUPERSCRIPT_GAP_MIN_OFFSET);
    }

    /// The maximum level to which the (ink) bottom of superscript can be pushed to increase the
    /// gap between superscript and subscript, before subscript starts being moved down.
    pub fn superscript_bottom_max_with_subscript(
        self: Constants,
    ) MathValue {
        return self.read_record(SUPERSCRIPT_BOTTOM_MAX_WITH_SUBSCRIPT_OFFSET);
    }

    /// Extra white space to be added after each subscript and superscript.
    pub fn space_after_script(
        self: Constants,
    ) MathValue {
        return self.read_record(SPACE_AFTER_SCRIPT_OFFSET);
    }

    /// Minimum gap between the (ink) bottom of the upper limit, and the (ink) top of the base
    /// operator.
    pub fn upper_limit_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(UPPER_LIMIT_GAP_MIN_OFFSET);
    }

    /// Minimum distance between baseline of upper limit and (ink) top of the base operator.
    pub fn upper_limit_baseline_rise_min(
        self: Constants,
    ) MathValue {
        return self.read_record(UPPER_LIMIT_BASELINE_RISE_MIN_OFFSET);
    }

    /// Minimum gap between (ink) top of the lower limit, and (ink) bottom of the base operator.
    pub fn lower_limit_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(LOWER_LIMIT_GAP_MIN_OFFSET);
    }

    /// Minimum distance between baseline of the lower limit and (ink) bottom of the base operator.
    pub fn lower_limit_baseline_drop_min(
        self: Constants,
    ) MathValue {
        return self.read_record(LOWER_LIMIT_BASELINE_DROP_MIN_OFFSET);
    }

    /// Standard shift up applied to the top element of a stack.
    pub fn stack_top_shift_up(
        self: Constants,
    ) MathValue {
        return self.read_record(STACK_TOP_SHIFT_UP_OFFSET);
    }

    /// Standard shift up applied to the top element of a stack in display style.
    pub fn stack_top_display_style_shift_up(
        self: Constants,
    ) MathValue {
        return self.read_record(STACK_TOP_DISPLAY_STYLE_SHIFT_UP_OFFSET);
    }

    /// Standard shift down applied to the bottom element of a stack.
    pub fn stack_bottom_shift_down(
        self: Constants,
    ) MathValue {
        return self.read_record(STACK_BOTTOM_SHIFT_DOWN_OFFSET);
    }

    /// Standard shift down applied to the bottom element of a stack in display style.
    pub fn stack_bottom_display_style_shift_down(
        self: Constants,
    ) MathValue {
        return self.read_record(STACK_BOTTOM_DISPLAY_STYLE_SHIFT_DOWN_OFFSET);
    }

    /// Minimum gap between (ink) bottom of the top element of a stack, and the (ink) top of the
    /// bottom element.
    pub fn stack_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(STACK_GAP_MIN_OFFSET);
    }

    /// Minimum gap between (ink) bottom of the top element of a stack, and the (ink) top of the
    /// bottom element in display style.
    pub fn stack_display_style_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(STACK_DISPLAY_STYLE_GAP_MIN_OFFSET);
    }

    /// Standard shift up applied to the top element of the stretch stack.
    pub fn stretch_stack_top_shift_up(
        self: Constants,
    ) MathValue {
        return self.read_record(STRETCH_STACK_TOP_SHIFT_UP_OFFSET);
    }

    /// Standard shift down applied to the bottom element of the stretch stack.
    pub fn stretch_stack_bottom_shift_down(
        self: Constants,
    ) MathValue {
        return self.read_record(STRETCH_STACK_BOTTOM_SHIFT_DOWN_OFFSET);
    }

    /// Minimum gap between the ink of the stretched element, and the (ink) bottom of the element above.
    pub fn stretch_stack_gap_above_min(
        self: Constants,
    ) MathValue {
        return self.read_record(STRETCH_STACK_GAP_ABOVE_MIN_OFFSET);
    }

    /// Minimum gap between the ink of the stretched element, and the (ink) top of the element below.
    pub fn stretch_stack_gap_below_min(
        self: Constants,
    ) MathValue {
        return self.read_record(STRETCH_STACK_GAP_BELOW_MIN_OFFSET);
    }

    /// Standard shift up applied to the numerator.
    pub fn fraction_numerator_shift_up(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_NUMERATOR_SHIFT_UP_OFFSET);
    }

    /// Standard shift up applied to the numerator in display style.
    pub fn fraction_numerator_display_style_shift_up(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_NUMERATOR_DISPLAY_STYLE_SHIFT_UP_OFFSET);
    }

    /// Standard shift down applied to the denominator.
    pub fn fraction_denominator_shift_down(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_DENOMINATOR_SHIFT_DOWN_OFFSET);
    }

    /// Standard shift down applied to the denominator in display style.
    pub fn fraction_denominator_display_style_shift_down(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_DENOMINATOR_DISPLAY_STYLE_SHIFT_DOWN_OFFSET);
    }

    /// Minimum tolerated gap between the (ink) bottom of the numerator and the ink of the
    /// fraction bar.
    pub fn fraction_numerator_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_NUMERATOR_GAP_MIN_OFFSET);
    }

    /// Minimum tolerated gap between the (ink) bottom of the numerator and the ink of the
    /// fraction bar in display style.
    pub fn fraction_num_display_style_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_NUM_DISPLAY_STYLE_GAP_MIN_OFFSET);
    }

    /// Thickness of the fraction bar.
    pub fn fraction_rule_thickness(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_RULE_THICKNESS_OFFSET);
    }

    /// Minimum tolerated gap between the (ink) top of the denominator and the ink of the fraction bar.
    pub fn fraction_denominator_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_DENOMINATOR_GAP_MIN_OFFSET);
    }

    /// Minimum tolerated gap between the (ink) top of the denominator and the ink of the fraction
    /// bar in display style.
    pub fn fraction_denom_display_style_gap_min(
        self: Constants,
    ) MathValue {
        return self.read_record(FRACTION_DENOM_DISPLAY_STYLE_GAP_MIN_OFFSET);
    }

    /// Horizontal distance between the top and bottom elements of a skewed fraction.
    pub fn skewed_fraction_horizontal_gap(
        self: Constants,
    ) MathValue {
        return self.read_record(SKEWED_FRACTION_HORIZONTAL_GAP_OFFSET);
    }

    /// Vertical distance between the ink of the top and bottom elements of a skewed fraction.
    pub fn skewed_fraction_vertical_gap(
        self: Constants,
    ) MathValue {
        return self.read_record(SKEWED_FRACTION_VERTICAL_GAP_OFFSET);
    }

    /// Distance between the overbar and the (ink) top of he base.
    pub fn overbar_vertical_gap(
        self: Constants,
    ) MathValue {
        return self.read_record(OVERBAR_VERTICAL_GAP_OFFSET);
    }

    /// Thickness of overbar.
    pub fn overbar_rule_thickness(
        self: Constants,
    ) MathValue {
        return self.read_record(OVERBAR_RULE_THICKNESS_OFFSET);
    }

    /// Extra white space reserved above the overbar.
    pub fn overbar_extra_ascender(
        self: Constants,
    ) MathValue {
        return self.read_record(OVERBAR_EXTRA_ASCENDER_OFFSET);
    }

    /// Distance between underbar and (ink) bottom of the base.
    pub fn underbar_vertical_gap(
        self: Constants,
    ) MathValue {
        return self.read_record(UNDERBAR_VERTICAL_GAP_OFFSET);
    }

    /// Thickness of underbar.
    pub fn underbar_rule_thickness(
        self: Constants,
    ) MathValue {
        return self.read_record(UNDERBAR_RULE_THICKNESS_OFFSET);
    }

    /// Extra white space reserved below the underbar.
    pub fn underbar_extra_descender(
        self: Constants,
    ) MathValue {
        return self.read_record(UNDERBAR_EXTRA_DESCENDER_OFFSET);
    }

    /// Space between the (ink) top of the expression and the bar over it.
    pub fn radical_vertical_gap(
        self: Constants,
    ) MathValue {
        return self.read_record(RADICAL_VERTICAL_GAP_OFFSET);
    }

    /// Space between the (ink) top of the expression and the bar over it.
    pub fn radical_display_style_vertical_gap(
        self: Constants,
    ) MathValue {
        return self.read_record(RADICAL_DISPLAY_STYLE_VERTICAL_GAP_OFFSET);
    }

    /// Thickness of the radical rule.
    pub fn radical_rule_thickness(
        self: Constants,
    ) MathValue {
        return self.read_record(RADICAL_RULE_THICKNESS_OFFSET);
    }

    /// Extra white space reserved above the radical.
    pub fn radical_extra_ascender(
        self: Constants,
    ) MathValue {
        return self.read_record(RADICAL_EXTRA_ASCENDER_OFFSET);
    }

    /// Extra horizontal kern before the degree of a radical, if such is present.
    pub fn radical_kern_before_degree(
        self: Constants,
    ) MathValue {
        return self.read_record(RADICAL_KERN_BEFORE_DEGREE_OFFSET);
    }

    /// Negative kern after the degree of a radical, if such is present.
    pub fn radical_kern_after_degree(
        self: Constants,
    ) MathValue {
        return self.read_record(RADICAL_KERN_AFTER_DEGREE_OFFSET);
    }

    /// Height of the bottom of the radical degree, if such is present, in proportion to the
    /// ascender of the radical sign.
    pub fn radical_degree_bottom_raise_percent(
        self: Constants,
    ) i16 {
        return self.read(i16, RADICAL_DEGREE_BOTTOM_RAISE_PERCENT_OFFSET);
    }

    /// Read an `u16` or `i16` at an offset into the table.
    fn read(
        self: Constants,
        T: type,
        offset: usize,
    ) T {
        if (T != u16 and T != i16) @compileError("u16 or i16");
        var s = parser.Stream.new_at(self.data, offset) catch return 0;
        return s.read(T) catch return 0;
    }

    /// Read a `MathValueRecord` at an offset into the table.
    fn read_record(
        self: Constants,
        offset: usize,
    ) MathValue {
        const data = utils.slice(self.data, offset) catch return .{};
        return MathValue.parse(data, self.data) catch .{};
    }
};

/// A [Math Glyph Info Table](https://learn.microsoft.com/en-us/typography/opentype/spec/math#mathglyphinfo-table).
pub const GlyphInfo = struct {
    /// Per-glyph italics correction values.
    italic_corrections: ?MathValues,
    /// Per-glyph horizontal positions for attaching mathematical accents.
    top_accent_attachments: ?MathValues,
    /// Glyphs which are _extended shapes_.
    extended_shapes: ?ggg.Coverage,
    /// Per-glyph information for mathematical kerning.
    kern_infos: ?KernInfos,

    fn parse(
        data: []const u8,
    ) parser.Error!GlyphInfo {
        var s = parser.Stream.new(data);

        const italic_corrections = parse_at_offset(MathValues, &s, data) catch null;
        const top_accent_attachments = parse_at_offset(MathValues, &s, data) catch null;
        const extended_shapes = parse_at_offset(ggg.Coverage, &s, data) catch null;
        const kern_infos = parse_at_offset(KernInfos, &s, data) catch null;

        return .{
            .italic_corrections = italic_corrections,
            .top_accent_attachments = top_accent_attachments,
            .extended_shapes = extended_shapes,
            .kern_infos = kern_infos,
        };
    }
};

/// A [Math Variants Table](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/math#mathvariants-table).
pub const Variants = struct {
    /// Minimum overlap of connecting glyphs during glyph construction, in design units.
    min_connector_overlap: u16,
    /// Constructions for shapes growing in the vertical direction.
    vertical_constructions: GlyphConstructions,
    /// Constructions for shapes growing in the horizontal direction.
    horizontal_constructions: GlyphConstructions,

    fn parse(
        data: []const u8,
    ) parser.Error!Variants {
        var s = parser.Stream.new(data);

        const min_connector_overlap = try s.read(u16);
        const vertical_coverage = parse_at_offset(ggg.Coverage, &s, data) catch null;
        const horizontal_coverage = parse_at_offset(ggg.Coverage, &s, data) catch null;

        const vertical_count = try s.read(u16);
        const horizontal_count = try s.read(u16);
        const vertical_offsets = try s.read_array_optional(parser.Offset16, vertical_count);
        const horizontal_offsets = try s.read_array_optional(parser.Offset16, horizontal_count);

        return .{
            .min_connector_overlap = min_connector_overlap,
            .vertical_constructions = .new(
                data,
                vertical_coverage,
                vertical_offsets,
            ),
            .horizontal_constructions = .new(
                data,
                horizontal_coverage,
                horizontal_offsets,
            ),
        };
    }
};

/// A mapping from glyphs to
/// [Math Values](https://docs.microsoft.com/en-us/typography/opentype/spec/math#mathvaluerecord).
pub const MathValues = struct {
    data: []const u8,
    coverage: ggg.Coverage,
    records: parser.LazyArray16(MathValueRecord),

    fn parse(
        data: []const u8,
    ) parser.Error!MathValues {
        var s = parser.Stream.new(data);
        const coverage = try parse_at_offset(ggg.Coverage, &s, data);
        const count = try s.read(u16);
        const records = try s.read_array(MathValueRecord, count);
        return .{
            .data = data,
            .coverage = coverage,
            .records = records,
        };
    }

    /// Returns the value for the glyph or `null` if it is not covered.
    pub fn get(
        self: MathValues,
        glyph: lib.GlyphId,
    ) ?MathValue {
        const index = self.coverage.get(glyph) orelse return null;
        const record = self.records.get(index) orelse return null;
        return record.get(self.data);
    }
};

/// A math value record with unresolved offset.
const MathValueRecord = struct {
    value: i16,
    device_offset: ?parser.Offset16,

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

    fn parse(
        data: []const u8,
    ) parser.Error!Self {
        return FromData.parse(data[0..FromData.SIZE]);
    }

    fn get(
        self: MathValueRecord,
        data: []const u8,
    ) MathValue {
        const device: ?Device = d: {
            const offset = self.device_offset orelse break :d null;
            const d = utils.slice(data, offset[0]) catch break :d null;
            break :d Device.parse(d) catch null;
        };
        return .{ .value = self.value, .device = device };
    }
};

/// A [Math Kern Info Table](https://docs.microsoft.com/en-us/typography/opentype/spec/math#mathkerninfo-table).
pub const KernInfos = struct {
    data: []const u8,
    coverage: ggg.Coverage,
    records: parser.LazyArray16(KernInfoRecord),

    fn parse(data: []const u8) parser.Error!KernInfos {
        var s = parser.Stream.new(data);
        const coverage = try parse_at_offset(ggg.Coverage, &s, data);
        const count = try s.read(u16);
        const records = try s.read_array(KernInfoRecord, count);

        return .{
            .data = data,
            .coverage = coverage,
            .records = records,
        };
    }

    /// Returns the kerning info for the glyph or `null` if it is not covered.
    pub fn get(
        self: KernInfos,
        glyph: lib.GlyphId,
    ) ?KernInfo {
        const index = self.coverage.get(glyph) orelse return null;
        const record = self.records.get(index) orelse return null;
        return record.get(self.data);
    }
};

const KernInfoRecord = struct {
    top_right: ?parser.Offset16,
    top_left: ?parser.Offset16,
    bottom_right: ?parser.Offset16,
    bottom_left: ?parser.Offset16,

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

    fn get(
        self: KernInfoRecord,
        data: []const u8,
    ) KernInfo {
        return .{
            .top_right = f: {
                const offset = self.top_right orelse break :f null;
                const d = utils.slice(data, offset[0]) catch break :f null;
                break :f Kern.parse(d) catch null;
            },
            .top_left = f: {
                const offset = self.top_left orelse break :f null;
                const d = utils.slice(data, offset[0]) catch break :f null;
                break :f Kern.parse(d) catch null;
            },
            .bottom_right = f: {
                const offset = self.bottom_right orelse break :f null;
                const d = utils.slice(data, offset[0]) catch break :f null;
                break :f Kern.parse(d) catch null;
            },
            .bottom_left = f: {
                const offset = self.bottom_left orelse break :f null;
                const d = utils.slice(data, offset[0]) catch break :f null;
                break :f Kern.parse(d) catch null;
            },
        };
    }
};

/// An [entry in a Math Kern Info Table](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/math#mathkerninforecord).
pub const KernInfo = struct {
    /// The kerning data for the top-right corner.
    top_right: ?Kern,
    /// The kerning data for the top-left corner.
    top_left: ?Kern,
    /// The kerning data for the bottom-right corner.
    bottom_right: ?Kern,
    /// The kerning data for the bottom-left corner.
    bottom_left: ?Kern,
};

/// A [Math Kern Table](https://learn.microsoft.com/en-us/typography/opentype/spec/math#mathkern-table).
pub const Kern = struct {
    data: []const u8,
    heights: parser.LazyArray16(MathValueRecord),
    kerns: parser.LazyArray16(MathValueRecord),

    /// Number of heights at which the kern value changes.
    pub fn count(
        self: Kern,
    ) u16 {
        return self.heights.len();
    }

    /// The correction height at the given index.
    ///
    /// The index must be smaller than `count()`.
    pub fn height(
        self: Kern,
        index: u16,
    ) ?MathValue {
        const record = self.heights.get(index) orelse return null;
        return record.get(self.data);
    }

    /// The kern value at the given index.
    ///
    /// The index must be smaller than or equal to `count()`.
    pub fn kern(
        self: Kern,
        index: u16,
    ) ?MathValue {
        const record = self.kerns.get(index) orelse return null;
        return record.get(self.data);
    }

    fn parse(
        data: []const u8,
    ) parser.Error!Kern {
        var s = parser.Stream.new(data);
        const c = try s.read(u16);
        const heights = try s.read_array(MathValueRecord, c);
        const kerns = try s.read_array(MathValueRecord, c + 1);
        return .{
            .data = data,
            .heights = heights,
            .kerns = kerns,
        };
    }
};

/// A mapping from glyphs to
/// [Math Glyph Construction Tables](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/math#mathglyphconstruction-table).
pub const GlyphConstructions = struct {
    coverage: ggg.Coverage,
    constructions: parser.LazyOffsetArray16(GlyphConstruction),

    fn new(
        data: []const u8,
        coverage: ?ggg.Coverage,
        offsets: parser.LazyArray16(?parser.Offset16),
    ) GlyphConstructions {
        return .{
            .coverage = coverage orelse .{ .format1 = .{} },
            .constructions = .new(data, offsets),
        };
    }
};

/// A [Math Glyph Construction Table](
/// https://learn.microsoft.com/en-us/typography/opentype/spec/math#mathglyphconstruction-table).
pub const GlyphConstruction = struct {
    /// A general recipe on how to construct a variant with large advance width/height.
    assembly: ?GlyphAssembly,
    /// Prepared variants of the glyph with varying advances.
    variants: parser.LazyArray16(GlyphVariant),
};

/// A [Glyph Assembly Table](https://learn.microsoft.com/en-us/typography/opentype/spec/math#glyphassembly-table).
pub const GlyphAssembly = struct {
    /// The italics correction of the assembled glyph.
    italics_correction: MathValue,
    /// Parts the assembly is composed of.
    parts: parser.LazyArray16(GlyphPart),
};

/// A [Math Value](https://docs.microsoft.com/en-us/typography/opentype/spec/math#mathvaluerecord)
/// with optional device corrections.
pub const MathValue = struct {
    /// The X or Y value in font design units.
    value: i16 = 0,
    /// Device corrections for this value.
    device: ?Device = null,

    fn parse(
        data: []const u8,
        parent: []const u8,
    ) parser.Error!MathValue {
        const record = try MathValueRecord.parse(data);
        return record.get(parent);
    }
};

/// Description of math glyph variants.
pub const GlyphVariant = struct {
    /// The ID of the variant glyph.
    variant_glyph: lib.GlyphId,
    /// Advance width/height, in design units, of the variant glyph.
    advance_measurement: u16,
};

/// Details for a glyph part in an assembly.
pub const GlyphPart = struct {
    /// Glyph ID for the part.
    glyph_id: lib.GlyphId,
    /// Lengths of the connectors on the start of the glyph, in font design units.
    start_connector_length: u16,
    /// Lengths of the connectors on the end of the glyph, in font design units.
    end_connector_length: u16,
    /// The full advance of the part, in font design units.
    full_advance: u16,
    /// Part flags.
    part_flags: PartFlags,
};

/// Glyph part flags.
pub const PartFlags = struct { u16 };

fn parse_at_offset(
    T: type,
    s: *parser.Stream,
    data: []const u8,
) parser.Error!T {
    const offset = try s.read_optional(parser.Offset16) orelse return error.ParseFail;
    return try T.parse(try utils.slice(data, offset[0]));
}
