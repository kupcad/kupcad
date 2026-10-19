//! A [Compact Font Format 2 Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/cff2) implementation.

// https://docs.microsoft.com/en-us/typography/opentype/spec/cff2charstr

const std = @import("std");
const lib = @import("../../lib.zig");
const parser = @import("../../parser.zig");
const cff = @import("../cff.zig");
const utils = @import("../../utils.zig");

const Index = @import("index.zig");
const ItemVariationStore = @import("../../var_store.zig");
const DictionaryParser = @import("dict.zig");
const CharStringParser = @import("charstring.zig");

// https://docs.microsoft.com/en-us/typography/opentype/spec/cff2#7-top-dict-data
// 'Operators in DICT may be preceded by up to a maximum of 513 operands.'
const MAX_OPERANDS_LEN: usize = 513;

// https://docs.microsoft.com/en-us/typography/opentype/spec/cff2charstr#appendix-b-cff2-charstring-implementation-limits
const STACK_LIMIT: u8 = 10;
const MAX_ARGUMENTS_STACK_LEN: usize = 513;

const Table = @This();

global_subrs: Index = .default,
local_subrs: Index = .default,
char_strings: Index = .default,
item_variation_store: ItemVariationStore = .{},

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    // Parse Header.
    if (try s.read(u8) != 2) return error.ParseFail; // major
    s.skip(u8); // minor
    const header_size = try s.read(u8);
    const top_dict_length = try s.read(u16);

    // Jump to Top DICT. It's not necessarily right after the header.
    s.advance(header_size -| 5);

    const top_dict_data = try s.read_bytes(top_dict_length);
    const top_dict: TopDictData = try .parse(top_dict_data);

    var metadata: Table = .{};

    metadata.global_subrs = try Index.parse(u32, &s);
    metadata.char_strings = cs: {
        var scs = try parser.Stream.new_at(data, top_dict.char_strings_offset);
        break :cs try Index.parse(u32, &scs);
    };

    if (top_dict.variation_store_offset) |offset| {
        var svs = try parser.Stream.new_at(data, offset);
        svs.skip(u16);
        metadata.item_variation_store = try .parse(&s);
    }

    const offset = top_dict.font_dict_index_offset orelse return metadata;

    s.offset = offset;

    const dict_data_idx = try Index.parse(u32, &s);
    var iterator = dict_data_idx.iterator();
    while (iterator.next()) |font_dict_data| {
        // private_dict_range
        const pdr_start, const pdr_len = parse_font_dict(font_dict_data) catch continue;

        // 'Private DICT size and offset, from start of the CFF2 table.'
        const private_dict_data = try utils.slice(data, .{ pdr_start, pdr_len });

        const subroutines_offset = parse_private_dict(private_dict_data) catch continue;

        // 'The local subroutines offset is relative to the beginning
        // of the Private DICT data.'
        const start = std.math.add(usize, pdr_start, subroutines_offset) catch continue;

        var s_inner = parser.Stream.new(try utils.slice(data, start));
        metadata.local_subrs = try Index.parse(u32, &s_inner);

        break;
    }

    return metadata;
}

pub fn outline(
    self: *const Table,
    coordinates: []const lib.NormalizedCoordinate,
    glyph_id: lib.GlyphId,
    builder: lib.OutlineBuilder,
) cff.Error!lib.Rect {
    const data = self.char_strings.get(glyph_id[0]) orelse return error.NoGlyph;
    return try parse_char_string(data, self, coordinates, builder);
}

const TopDictData = struct {
    char_strings_offset: usize = 0,
    font_dict_index_offset: ?usize = null,
    variation_store_offset: ?usize = null,

    // https://docs.microsoft.com/en-us/typography/opentype/spec/cff2#table-9-top-dict-operator-entries
    const Operator = enum(u16) {
        char_strings_offset = 17,
        variation_store_offset = 24,
        font_dict_index_offset = 1236,
        _,
    };

    fn parse(
        data: []const u8,
    ) parser.Error!TopDictData {
        var dict_data: TopDictData = .{};

        var operands_buffer: [MAX_OPERANDS_LEN]f64 = @splat(0.0);
        var dict_parser: DictionaryParser = .new(data, &operands_buffer);

        while (dict_parser.parse_next(Operator)) |operator| switch (operator) {
            .char_strings_offset => dict_data
                .char_strings_offset = try dict_parser.parse_offset(),

            .font_dict_index_offset => dict_data
                .font_dict_index_offset = dict_parser.parse_offset() catch null,

            .variation_store_offset => dict_data
                .variation_store_offset = dict_parser.parse_offset() catch null,

            _ => {},
        };

        // Must be set, otherwise there are nothing to parse.
        if (dict_data.char_strings_offset == 0) return error.ParseFail;

        return dict_data;
    }
};

// https://docs.microsoft.com/en-us/typography/opentype/spec/cff2#table-10-font-dict-operator-entries
const FontDictOperator = enum(u16) {
    private_dict_size_and_offset = 18,
    _,
};

fn parse_font_dict(
    data: []const u8,
) parser.Error!struct { usize, usize } {
    var operands_buffer: [MAX_OPERANDS_LEN]f64 = @splat(0.0);
    var dict_parser: DictionaryParser = .new(data, &operands_buffer);

    while (dict_parser.parse_next(FontDictOperator)) |operator| {
        if (operator == .private_dict_size_and_offset) {
            try dict_parser.parse_operands();
            const operands = dict_parser.operands_slice();

            if (operands.len != 2) return error.ParseFail;

            const len = utils.f64_to_usize(operands[0]) orelse return error.ParseFail;
            const start = utils.f64_to_usize(operands[0]) orelse return error.ParseFail;

            return .{ start, len };
        }
    }
    return error.ParseFail;
}

// https://docs.microsoft.com/en-us/typography/opentype/spec/cff2#table-16-private-dict-operators
const PrivateDictOperator = enum(u16) {
    local_subroutines_offset = 19,
    _,
};

fn parse_private_dict(
    data: []const u8,
) parser.Error!usize {
    var operands_buffer: [MAX_OPERANDS_LEN]f64 = @splat(0.0);
    var dict_parser: DictionaryParser = .new(data, &operands_buffer);

    while (dict_parser.parse_next(PrivateDictOperator)) |operator| {
        if (operator == .local_subroutines_offset) {
            try dict_parser.parse_operands();
            const operands = dict_parser.operands_slice();

            if (operands.len == 1)
                return utils.f64_to_usize(operands[0]) orelse error.ParseFail;

            return error.ParseFail;
        }
    }

    return error.ParseFail;
}

/// CFF2 allows up to 65535 scalars, but an average font will have 3-5.
/// So 64 is more than enough.
const SCALARS_MAX: u8 = 64;

const CharStringParserContext = struct {
    metadata: *const Table,
    coordinates: []const lib.NormalizedCoordinate,
    scalars: std.ArrayList(f32),
    had_vsindex: bool,
    had_blend: bool,
    stems_len: u32,

    fn update_scalars(
        self: *CharStringParserContext,
        index: u16,
    ) cff.Error!void {
        self.scalars.clearRetainingCapacity();

        const indices = self
            .metadata
            .item_variation_store
            .region_indices(index) orelse return error.InvalidItemVariationDataIndex;

        var iter = indices.iterator();
        while (iter.next()) |idx| {
            const scalar = self
                .metadata
                .item_variation_store
                .regions
                .evaluate_region(idx, self.coordinates);
            self.scalars.appendBounded(scalar) catch return error.BlendRegionsLimitReached;
        }
    }
};

fn parse_char_string(
    data: []const u8,
    metadata: *const Table,
    coordinates: []const lib.NormalizedCoordinate,
    builder: lib.OutlineBuilder,
) cff.Error!lib.Rect {
    var scalar_buffer: [SCALARS_MAX]f32 = @splat(0.0); // 256B

    var ctx = CharStringParserContext{
        .metadata = metadata,
        .coordinates = coordinates,
        .scalars = .initBuffer(&scalar_buffer),
        .had_vsindex = false,
        .had_blend = false,
        .stems_len = 0,
    };

    // Load scalars at default index.
    try ctx.update_scalars(0);

    var inner_builder: cff.Builder = .{ .builder = builder, .bbox = .{}, .transform_tuple = null };

    var stack_buffer: [MAX_ARGUMENTS_STACK_LEN]f32 = undefined;

    var cs_parser: CharStringParser = .{
        .stack = .initBuffer(&stack_buffer),
        .builder = &inner_builder,
        .x = 0.0,
        .y = 0.0,
        .has_move_to = false,
        .is_first_move_to = true,
        .width_only = false,
    };
    try parse_char_string_recursive(&ctx, data, 0, &cs_parser);

    const bbox = cs_parser.builder.bbox;

    // Check that bbox was changed.
    if (bbox.is_default()) return error.ZeroBBox;

    return bbox.to_rect() orelse error.BboxOverflow;
}

// https://docs.microsoft.com/en-us/typography/opentype/spec/cff2charstr#4-charstring-operators
const CharStringOperator = enum(u8) {
    hor_stem = 1,
    ver_stem = 3,
    ver_move_to = 4,
    line_to = 5,
    hor_line_to = 6,
    ver_line_to = 7,
    curve_to = 8,
    call_local_subroutine = 10,
    two_byte_operator_mark = 12,
    vs_index = 15,
    blend = 16,
    hor_stem_hint_mask = 18,
    hint_mask = 19,
    counter_mask = 20,
    move_to = 21,
    hor_move_to = 22,
    ver_stem_hint_mask = 23,
    curve_line = 24,
    line_curve = 25,
    vv_curve_to = 26,
    hh_curve_to = 27,
    short_int = 28,
    call_global_subroutine = 29,
    vh_curve_to = 30,
    hv_curve_to = 31,
    fixed_16_16 = 255,
    _,
};

const FlexOperator = enum(u8) {
    hflex = 34,
    flex = 35,
    hflex1 = 36,
    flex1 = 37,
    _,
};

fn parse_char_string_recursive(
    ctx: *CharStringParserContext,
    char_string: []const u8,
    depth: u8,
    p: *CharStringParser,
) cff.Error!void {
    var s = parser.Stream.new(char_string);
    while (!s.at_end()) {
        const op = s.read(CharStringOperator) catch return error.ReadOutOfBounds;
        switch (op) {
            .hor_stem,
            .ver_stem,
            .hor_stem_hint_mask,
            .ver_stem_hint_mask,
            => {
                // y dy {dya dyb}* hstem
                // x dx {dxa dxb}* vstem
                // y dy {dya dyb}* hstemhm
                // x dx {dxa dxb}* vstemhm

                ctx.stems_len += @as(u32, @truncate(p.stack.items.len)) >> 1;

                // We are ignoring the hint operators.
                p.stack.clearRetainingCapacity();
            },
            .ver_move_to => try p.parse_vertical_move_to(0),
            .line_to => try p.parse_line_to(),
            .hor_line_to => try p.parse_horizontal_line_to(),
            .ver_line_to => try p.parse_vertical_line_to(),
            .curve_to => try p.parse_curve_to(),
            .call_local_subroutine => {
                if (p.stack.items.len == 0) return error.InvalidArgumentsStackLength;
                if (depth == STACK_LIMIT) return error.NestingLimitReached;

                const subroutine_bias =
                    cff.calc_subroutine_bias(ctx.metadata.local_subrs.len());
                const index = try cff.conv_subroutine_index(
                    p.stack.pop() orelse unreachable,
                    subroutine_bias,
                );
                const local_char_string = ctx
                    .metadata
                    .local_subrs
                    .get(index) orelse return error.InvalidSubroutineIndex;
                try parse_char_string_recursive(ctx, local_char_string, depth + 1, p);
            },
            .two_byte_operator_mark => {
                // flex
                const op2 = s.read(FlexOperator) catch return error.ReadOutOfBounds;
                switch (op2) {
                    .hflex => try p.parse_hflex(),
                    .flex => try p.parse_flex(),
                    .hflex1 => try p.parse_hflex1(),
                    .flex1 => try p.parse_flex1(),
                    _ => return error.UnsupportedOperator,
                }
            },
            .vs_index => {
                // |- ivs vsindex (15) |-

                // `vsindex` must precede the first `blend` operator, and may occur only once.
                if (ctx.had_blend and ctx.had_vsindex) return error.InvalidOperator;
                if (p.stack.items.len != 1) return error.InvalidArgumentsStackLength;

                const index = utils.f32_to_u16(p.stack.pop() orelse unreachable) orelse
                    return error.InvalidItemVariationDataIndex;
                try ctx.update_scalars(index);

                ctx.had_vsindex = true;

                p.stack.clearRetainingCapacity();
            },
            .blend => {
                // num(0)..num(n-1), delta(0,0)..delta(k-1,0),
                // delta(0,1)..delta(k-1,1) .. delta(0,n-1)..delta(k-1,n-1)
                // n blend (16) val(0)..val(n-1)

                ctx.had_blend = true;

                const n = utils.f32_to_u16((p.stack.pop() orelse unreachable)) orelse
                    return error.InvalidNumberOfBlendOperands;
                const k = ctx.scalars.items.len;

                const len = @as(usize, n) * (@as(usize, k) + 1);
                if (p.stack.items.len < len) return error.InvalidArgumentsStackLength;

                const start = p.stack.items.len - len;
                for (0..n) |i_true| {
                    const i = n - 1 - i_true;
                    for (0..k) |j| {
                        const delta = p.stack.pop() orelse unreachable;
                        p.stack.items[start + i] += delta * ctx.scalars.items[k - j - 1];
                    }
                }
            },
            .hint_mask, .counter_mask => {
                ctx.stems_len += @as(u32, @truncate(p.stack.items.len)) >> 1;
                s.advance((ctx.stems_len + 7) >> 3);

                // We are ignoring the hint operators.
                p.stack.clearRetainingCapacity();
            },
            .move_to => try p.parse_move_to(0),
            .hor_move_to => try p.parse_horizontal_move_to(0),
            .curve_line => try p.parse_curve_line(),
            .line_curve => try p.parse_line_curve(),
            .vv_curve_to => try p.parse_vv_curve_to(),
            .hh_curve_to => try p.parse_hh_curve_to(),
            .short_int => {
                const n = s.read(i16) catch return error.ReadOutOfBounds;
                p.stack.appendBounded(@floatFromInt(n)) catch
                    return error.ArgumentsStackLimitReached;
            },
            .call_global_subroutine => {
                if (p.stack.items.len == 0) return error.InvalidArgumentsStackLength;
                if (depth == STACK_LIMIT) return error.NestingLimitReached;

                const subroutine_bias =
                    cff.calc_subroutine_bias(ctx.metadata.global_subrs.len());
                const index = try cff.conv_subroutine_index(
                    (p.stack.pop() orelse unreachable),
                    subroutine_bias,
                );
                const global_char_string = ctx
                    .metadata
                    .global_subrs
                    .get(index) orelse return error.InvalidSubroutineIndex;
                try parse_char_string_recursive(ctx, global_char_string, depth + 1, p);
            },
            .vh_curve_to => try p.parse_vh_curve_to(),
            .hv_curve_to => try p.parse_hv_curve_to(),
            .fixed_16_16 => try p.parse_fixed(&s),
            _ => switch (@intFromEnum(op)) {
                // Reserved.
                0, 2, 9, 11, 13, 14, 17 => return error.InvalidOperator,
                32...246 => |d| try p.parse_int1(d),
                247...250 => |d| try p.parse_int2(d, &s),
                251...254 => |d| try p.parse_int3(d, &s),
                else => unreachable, // exhausted
            },
        }
    }
}
