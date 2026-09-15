//! A [Compact Font Format Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/cff) implementation.

// Useful links:
// http://wwwimages.adobe.com/content/dam/Adobe/en/devnet/font/pdfs/5176.CFF.pdf
// http://wwwimages.adobe.com/content/dam/Adobe/en/devnet/font/pdfs/5177.Type2.pdf
// https://github.com/opentypejs/opentype.js/blob/master/src/tables/cff.js

const std = @import("std");
const lib = @import("../../lib.zig");
const utils = @import("../../utils.zig");
const parser = @import("../../parser.zig");
const cff = @import("../cff.zig");

const Encoding = @import("encoding.zig");
const Index = @import("index.zig");
const Charset = @import("charset.zig").Charset;
const DictionaryParser = @import("dict.zig");
const CharStringParser = @import("charstring.zig");

// Limits according to the Adobe Technical Note #5177 Appendix B.
const STACK_LIMIT: u8 = 10;
const MAX_ARGUMENTS_STACK_LEN: usize = 48;

/// Enumerates Charset IDs defined in the Adobe Technical Note #5176, Table 22
const charset_id = struct {
    pub const ISO_ADOBE: usize = 0;
    pub const EXPERT: usize = 1;
    pub const EXPERT_SUBSET: usize = 2;
};

/// Enumerates Charset IDs defined in the Adobe Technical Note #5176, Table 16
const encoding_id = struct {
    pub const STANDARD: usize = 0;
    pub const EXPERT: usize = 1;
};

/// A [Compact Font Format Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/cff).
const Table = @This();

// The whole CFF table.
// Used to resolve a local subroutine in a CID font.
table_data: []const u8,

strings: Index,
global_subrs: Index,
charset: Charset,
number_of_glyphs: u16, // nonzero
matrix: Matrix,
char_strings: Index,
kind: FontKind,

// Copy of Face.units_per_em().
// Required to do glyph outlining, since coordinates must be scaled up by this before applying the `matrix`.
units_per_em: ?u16,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    return try Table.parse_inner(data, null);
}

/// The same as `Table.parse`, with the difference that it allows you to
/// manually pass the units per em of the font, which is needed to properly
/// scale certain fonts with a non-identity matrix.
pub fn parse_with_upem(
    data: []const u8,
    units_per_em: u16,
) parser.Error!Table {
    return try Table.parse_inner(data, units_per_em);
}

fn parse_inner(
    data: []const u8,
    units_per_em: ?u16,
) parser.Error!Table {
    var s = parser.Stream.new(data);

    // Parse Header.
    const major = try s.read(u8);
    s.skip(u8); // minor
    const header_size = try s.read(u8);
    s.skip(u8); // Absolute offset

    if (major != 1) return error.ParseFail;

    // Jump to Name INDEX. It's not necessarily right after the header.
    if (header_size > 4) s.advance(header_size - 4);

    // Skip Name INDEX.
    try Index.skip(u16, &s);

    const top_dict = try parse_top_dict(&s);

    // Must be set, otherwise there are nothing to parse.
    if (top_dict.char_strings_offset == 0) return error.ParseFail;

    // String INDEX.
    const strings = try Index.parse(u16, &s);

    // Parse Global Subroutines INDEX.
    const global_subrs = try Index.parse(u16, &s);

    const char_strings = cs: {
        var scs = try parser.Stream.new_at(data, top_dict.char_strings_offset);
        break :cs try Index.parse(u16, &scs);
    };

    // 'The number of glyphs is the value of the count field in the CharStrings INDEX.'
    const number_of_glyphs = std.math.cast(u16, char_strings.len()) orelse
        return error.ParseFail;
    if (number_of_glyphs == 0) return error.ParseFail;

    // continue from line 941 in cff1.rs
    const charset: Charset = if (top_dict.charset_offset) |charset_offset|
        switch (charset_offset) {
            charset_id.ISO_ADOBE => .iso_adobe,
            charset_id.EXPERT => .expert,
            charset_id.EXPERT_SUBSET => .expert_subset,
            else => s: {
                var sco = try parser.Stream.new_at(data, charset_offset);
                break :s try Charset.parse_charset(number_of_glyphs, &sco);
            },
        }
    else
        .iso_adobe; // default

    const matrix = top_dict.matrix;

    const kind = if (top_dict.has_ros)
        try parse_cid_metadata(data, top_dict, number_of_glyphs)
    else k: {
        // Only SID fonts are allowed to have an Encoding.
        const encoding: Encoding = if (top_dict.encoding_offset) |offset|
            switch (offset) {
                encoding_id.STANDARD => .new_standard,
                encoding_id.EXPERT => .new_expert,
                else => e: {
                    var se = try parser.Stream.new_at(data, offset);
                    break :e try .parse(&se);
                },
            }
        else
            .new_standard;

        break :k try parse_sid_metadata(data, top_dict, encoding);
    };

    return .{
        .table_data = data,
        .strings = strings,
        .global_subrs = global_subrs,
        .charset = charset,
        .number_of_glyphs = number_of_glyphs,
        .matrix = matrix,
        .char_strings = char_strings,
        .kind = kind,
        .units_per_em = units_per_em,
    };
}

/// Resolves a Glyph ID for a code point.
///
/// Similar to `Face.glyph_index` but 8bit
/// and uses CFF encoding and charset tables instead of TrueType `cmap`.
pub fn glyph_index(
    self: *const Table,
    code_point: u8,
) ?lib.GlyphId {
    if (self.kind == .cid) return null;

    return self.kind.sid.encoding.code_to_gid(self.charset, code_point) orelse
        // Try using the Standard encoding otherwise.
        // Custom Encodings does not guarantee to include all glyphs.
        Encoding.new_standard.code_to_gid(self.charset, code_point);
}

/// Returns a glyph width.
///
/// This value is different from outline bbox width and is stored separately.
///
/// Technically similar to `Face.glyph_hor_advance`.
pub fn glyph_width(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?u16 {
    if (self.kind == .cid) return null;

    const sid = self.kind.sid;
    const data = self.char_strings.get(glyph_id[0]) orelse return null;
    _, const maybe_width = parse_char_string(
        data,
        self,
        glyph_id,
        true,
        lib.OutlineBuilder.dummy_builder,
    ) catch return null;
    const width = w: {
        const w = maybe_width orelse break :w sid.default_width;
        break :w sid.nominal_width + w;
    };

    return utils.f32_to_u16(width);
}

/// Returns a glyph ID by a name.
pub fn glyph_index_by_name(
    self: *const Table,
    name: []const u8,
) ?lib.GlyphId {
    if (self.kind == .cid) return null;

    const sid: cff.StringId = sid: for (cff.STANDARD_NAMES, 0..) |n, pos| {
        if (std.mem.eql(u8, n, name)) break :sid .{@truncate(pos)};
    } else {
        var iter = self.strings.iterator();
        var pos: usize = 0;

        const index = while (iter.next()) |n| : (pos += 1) {
            if (std.mem.eql(u8, n, name)) break pos;
        } else return null;
        break :sid .{@truncate(index + cff.STANDARD_NAMES.len)};
    };

    return self.charset.sid_to_gid(sid);
}

/// Returns a glyph name.
pub fn glyph_name(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?[]const u8 {
    if (self.kind == .cid) return null;

    const sid = self.charset.gid_to_sid(glyph_id) orelse return null;

    if (sid[0] < cff.STANDARD_NAMES.len) return cff.STANDARD_NAMES[sid[0]];

    const index = std.math.cast(u32, sid[0] - cff.STANDARD_NAMES.len) orelse return null;
    return self.strings.get(index);
}

/// Outlines a glyph.
pub fn outline(
    self: *const Table,
    glyph_id: lib.GlyphId,
    builder: lib.OutlineBuilder,
) cff.Error!lib.Rect {
    const data = self.char_strings.get(glyph_id[0]) orelse return error.NoGlyph;
    const ret = try parse_char_string(data, self, glyph_id, false, builder);
    return ret[0];
}

/// Returns the CID corresponding to a glyph ID.
///
/// Returns `null` if this is not a CIDFont.
pub fn glyph_cid(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?u16 {
    if (self.kind == .sid) return null;

    const ret = self.charset.gid_to_sid(glyph_id) orelse return null;
    return ret[0];
}

/// An affine transformation matrix.
//[ARS] I dont know what affine means here
pub const Matrix = struct {
    sx: f32 = 0,
    ky: f32 = 0,
    kx: f32 = 0,
    sy: f32 = 0.001,
    tx: f32 = 0,
    ty: f32 = 0,
};

pub const FontKind = union(enum) {
    sid: SIDMetadata,
    cid: CIDMetadata,
};

pub const SIDMetadata = struct {
    local_subrs: Index = .default,
    /// Can be zero.
    default_width: f32 = 0.0,
    /// Can be zero.
    nominal_width: f32 = 0.0,
    encoding: Encoding = .new_standard,
};

pub const CIDMetadata = struct {
    fd_array: Index = .default,
    fd_select: FDSelect = .{ .format0 = .{} },
};

pub const FDSelect = union(enum) {
    format0: parser.LazyArray16(u8),
    format3: []const u8, // It's easier to parse it in-place.

    fn font_dict_index(
        self: FDSelect,
        glyph_id: lib.GlyphId,
    ) parser.Error!u8 {
        switch (self) {
            .format0 => |array| return array.get(glyph_id[0]) orelse error.ParseFail,
            .format3 => |data| {
                var s = parser.Stream.new(data);

                const number_of_ranges = try s.read(u16);
                if (number_of_ranges == 0) return error.ParseFail;

                // 'A sentinel GID follows the last range element and serves
                // to delimit the last range in the array.'

                // Range is: GlyphId + u8
                var prev_first_glyph = try s.read(lib.GlyphId);
                var prev_index = try s.read(u8);
                for (0..number_of_ranges) |_| {
                    const curr_first_glyph = try s.read(lib.GlyphId);

                    if (glyph_id[0] >= prev_first_glyph[0] and
                        glyph_id[0] < curr_first_glyph[0])
                        return prev_index
                    else
                        prev_index = try s.read(u8);

                    prev_first_glyph = curr_first_glyph;
                }

                return error.ParseFail;
            },
        }
    }
};

const TopDict = struct {
    charset_offset: ?usize = null,
    encoding_offset: ?usize = null,
    char_strings_offset: usize = 0,
    /// start , length
    private_dict_range: ?struct { usize, usize } = null,
    matrix: Matrix = .{},
    has_ros: bool = false,
    fd_array_offset: ?usize = null,
    fd_select_offset: ?usize = null,

    /// Enumerates some operators defined in the Adobe Technical Note #5176,
    /// Table 9 Top DICT Operator Entries
    const Operator = enum(u16) {
        charset_offset = 15,
        encoding_offset = 16,
        char_strings_offset = 17,
        private_dict_size_and_offset = 18,
        font_matrix = 1207,
        ros = 1230,
        fd_array = 1236,
        fd_select = 1237,
        _,
    };
};

// Limits according to the Adobe Technical Note #5176, chapter 4 DICT Data.
const MAX_OPERANDS_LEN: usize = 48;

fn parse_top_dict(
    s: *parser.Stream,
) parser.Error!TopDict {
    var top_dict: TopDict = .{};

    const index = try Index.parse(u16, s);
    if (index.data.len == 0) return error.ParseFail;

    // The Top DICT INDEX should have only one dictionary.
    const data = index.get(0) orelse return error.ParseFail;

    var operands_buffer: [MAX_OPERANDS_LEN]f64 = @splat(0.0);
    var dict_parser: DictionaryParser = .new(data, &operands_buffer);

    while (dict_parser.parse_next(TopDict.Operator)) |operator| switch (operator) {
        .charset_offset => top_dict.charset_offset = dict_parser.parse_offset() catch null,
        .encoding_offset => top_dict.encoding_offset = dict_parser.parse_offset() catch null,
        .char_strings_offset => top_dict.char_strings_offset = try dict_parser.parse_offset(),
        .private_dict_size_and_offset => top_dict.private_dict_range = dict_parser.parse_range() catch null,
        .font_matrix => {
            try dict_parser.parse_operands();
            const operands = dict_parser.operands_slice();
            if (operands.len == 6) top_dict.matrix = .{
                .sx = @floatCast(operands[0]),
                .ky = @floatCast(operands[1]),
                .kx = @floatCast(operands[2]),
                .sy = @floatCast(operands[3]),
                .tx = @floatCast(operands[4]),
                .ty = @floatCast(operands[5]),
            };
        },
        .ros => top_dict.has_ros = true,
        .fd_array => top_dict.fd_array_offset = dict_parser.parse_offset() catch null,
        .fd_select => top_dict.fd_select_offset = dict_parser.parse_offset() catch null,
        _ => {},
    };

    return top_dict;
}

fn parse_cid_metadata(
    data: []const u8,
    top_dict: TopDict,
    number_of_glyphs: u16,
) parser.Error!FontKind {
    // charset, FDArray and FDSelect must be set.
    const charset_offset = top_dict.charset_offset orelse return error.ParseFail;
    const fd_array_offset = top_dict.fd_array_offset orelse return error.ParseFail;
    const fd_select_offset = top_dict.fd_select_offset orelse return error.ParseFail;

    if (charset_offset <= charset_id.EXPERT_SUBSET) {
        // 'There are no predefined charsets for CID fonts.'
        // Adobe Technical Note #5176, chapter 18 CID-keyed Fonts
        return error.ParseFail;
    }

    var metadata: CIDMetadata = .{};

    metadata.fd_array = m: {
        var s = try parser.Stream.new_at(data, fd_array_offset);
        break :m try Index.parse(u16, &s);
    };

    metadata.fd_select = f: {
        var s = try parser.Stream.new_at(data, fd_select_offset);
        break :f try parse_fd_select(number_of_glyphs, &s);
    };

    return .{ .cid = metadata };
}

fn parse_fd_select(
    number_of_glyphs: u16,
    s: *parser.Stream,
) parser.Error!FDSelect {
    const format = try s.read(u8);
    return switch (format) {
        0 => .{ .format0 = try s.read_array(u8, number_of_glyphs) },
        3 => .{ .format3 = try s.tail() },
        else => error.ParseFail,
    };
}

fn parse_sid_metadata(
    data: []const u8,
    top_dict: TopDict,
    encoding: Encoding,
) parser.Error!FontKind {
    var metadata: SIDMetadata = .{};
    metadata.encoding = encoding;

    const private_dict_range = top_dict.private_dict_range orelse
        return .{ .sid = metadata };

    const private_dict: PrivateDict = d: {
        const start, const length = private_dict_range;
        break :d parse_private_dict(try utils.slice(data, .{ start, length }));
    };

    metadata.default_width = private_dict.default_width orelse 0.0;
    metadata.nominal_width = private_dict.nominal_width orelse 0.0;

    if (private_dict.local_subroutines_offset) |subroutines_offset|
        // 'The local subroutines offset is relative to the beginning
        // of the Private DICT data.'
        if (std.math.add(usize, private_dict_range[0], subroutines_offset)) |start| {
            var s = parser.Stream.new(try utils.slice(data, start));
            metadata.local_subrs = try Index.parse(u16, &s);
        } else |_| {};

    return .{ .sid = metadata };
}

fn parse_private_dict(
    data: []const u8,
) PrivateDict {
    var dict: PrivateDict = .{};
    var operands_buffer: [MAX_OPERANDS_LEN]f64 = @splat(0.0);
    var dict_parser: DictionaryParser = .new(data, &operands_buffer);

    while (dict_parser.parse_next(PrivateDict.Operator)) |operator| switch (operator) {
        .local_subroutines_offset => dict.local_subroutines_offset =
            dict_parser.parse_offset() catch null,

        .default_width => dict.default_width =
            dict_parser.parse_number_method(f32) catch null,

        .nominal_width => dict.nominal_width =
            dict_parser.parse_number_method(f32) catch null,

        _ => {},
    };

    return dict;
}

const PrivateDict = struct {
    local_subroutines_offset: ?usize = null,
    default_width: ?f32 = null,
    nominal_width: ?f32 = null,

    /// Enumerates some operators defined in the Adobe Technical Note #5176,
    /// Table 23 Private DICT Operators
    const Operator = enum(u16) {
        local_subroutines_offset = 19,
        default_width = 20,
        nominal_width = 21,
        _,
    };
};

const CharStringParserContext = struct {
    metadata: *const Table,
    width: ?f32 = null,
    stems_len: u32 = 0,
    has_endchar: bool = false,
    has_seac: bool = false,
    glyph_id: lib.GlyphId, // Required to parse local subroutine in CID fonts.
    local_subrs: ?Index,
};

fn parse_char_string(
    data: []const u8,
    metadata: *const Table,
    glyph_id: lib.GlyphId,
    width_only: bool,
    builder: lib.OutlineBuilder,
) cff.Error!struct { lib.Rect, ?f32 } {
    const local_subrs = switch (metadata.kind) {
        .sid => |sid| sid.local_subrs,
        .cid => null, // Will be resolved on request.
    };

    var ctx: CharStringParserContext = .{
        .metadata = metadata,
        .glyph_id = glyph_id,
        .local_subrs = local_subrs,
    };

    const transform = t: {
        const upem = metadata.units_per_em orelse break :t null;
        const transform = metadata.matrix;

        break :t if (!std.meta.eql(
            .{ upem, transform },
            .{ 1000, Matrix{} },
        )) .{ upem, transform } else null;
    };

    var inner_builder: cff.Builder = .{
        .builder = builder,
        .bbox = .{},
        .transform_tuple = transform,
    };

    var buffer: [MAX_ARGUMENTS_STACK_LEN]f32 = undefined;
    var cs_parser = CharStringParser{
        .stack = .initBuffer(&buffer),
        .builder = &inner_builder,
        .x = 0.0,
        .y = 0.0,
        .has_move_to = false,
        .is_first_move_to = true,
        .width_only = width_only,
    };

    try parse_char_string_recursive(&ctx, data, 0, &cs_parser);

    if (width_only) return .{ lib.Rect.zero, ctx.width };
    if (!ctx.has_endchar) return error.MissingEndChar;

    const bbox = cs_parser.builder.bbox;
    // Check that bbox was changed.
    if (bbox.is_default()) return error.ZeroBBox;

    const rect = bbox.to_rect() orelse return error.BboxOverflow;
    return .{ rect, ctx.width };
}

/// Enumerates some operators defined in the Adobe Technical Note #5177.
const CharStringOperator = enum(u8) {
    hor_stem = 1,
    ver_stem = 3,
    ver_move_to = 4,
    line_to = 5,
    hor_line_to = 6,
    ver_line_to = 7,
    curve_to = 8,
    call_local_subroutine = 10,
    @"return" = 11,
    two_byte_operator_mark = 12,
    endchar = 14,
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
    dotsection = 0,
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

                // If the stack length is uneven, than the first value is a `width`.
                const len = if (p.stack.items.len & 1 != 0 and ctx.width == null) l: {
                    ctx.width = p.stack.items[0];
                    break :l p.stack.items.len - 1;
                } else p.stack.items.len;

                ctx.stems_len += @as(u32, @truncate(len)) >> 1;

                // We are ignoring the hint operators.
                p.stack.clearRetainingCapacity();
            },
            .ver_move_to => {
                var i: usize = 0;
                if (p.stack.items.len == 2) {
                    i += 1;
                    if (ctx.width == null) ctx.width = p.stack.items[0];
                }

                try p.parse_vertical_move_to(i);
            },
            .line_to => try p.parse_line_to(),
            .hor_line_to => try p.parse_horizontal_line_to(),
            .ver_line_to => try p.parse_vertical_line_to(),
            .curve_to => try p.parse_curve_to(),
            .call_local_subroutine => {
                if (p.stack.items.len == 0) return error.InvalidArgumentsStackLength;
                if (depth == STACK_LIMIT) return error.NestingLimitReached;

                // Parse and remember the local subroutine for the current glyph.
                // Since it's a pretty complex task, we're doing it only when
                // a local subroutine is actually requested by the glyphs charstring.
                if (ctx.local_subrs == null) {
                    if (ctx.metadata.kind == .cid) {
                        const cid = &ctx.metadata.kind.cid;
                        ctx.local_subrs = parse_cid_local_subrs(
                            ctx.metadata.table_data,
                            ctx.glyph_id,
                            cid,
                        ) catch null;
                    }
                }

                if (ctx.local_subrs) |local_subrs| {
                    const subroutine_bias = cff.calc_subroutine_bias(local_subrs.len());
                    const index = try cff.conv_subroutine_index(
                        p.stack.pop() orelse unreachable, // checked stack is not empty
                        subroutine_bias,
                    );

                    const local_char_string = local_subrs.get(index) orelse
                        return error.InvalidSubroutineIndex;

                    try parse_char_string_recursive(ctx, local_char_string, depth + 1, p);
                } else return error.NoLocalSubroutines;

                if (ctx.has_endchar and !ctx.has_seac) {
                    if (!s.at_end()) return error.DataAfterEndChar;
                    break;
                }
            },
            .@"return" => break,
            .two_byte_operator_mark => {
                // flex
                const op2 = s.read(FlexOperator) catch return error.ReadOutOfBounds;
                switch (op2) {
                    .dotsection => {}, // deprecated. noop.
                    .hflex => try p.parse_hflex(),
                    .flex => try p.parse_flex(),
                    .hflex1 => try p.parse_hflex1(),
                    .flex1 => try p.parse_flex1(),
                    _ => return error.UnsupportedOperator,
                }
            },
            .endchar => {
                if (p.stack.items.len == 4 or
                    (ctx.width == null and p.stack.items.len == 5))
                {
                    // Process 'seac'.
                    const accent_char = seac_code_to_glyph_id(
                        ctx.metadata.charset,
                        p.stack.pop() orelse unreachable,
                    ) orelse return error.InvalidSeacCode;

                    const base_char = seac_code_to_glyph_id(
                        ctx.metadata.charset,
                        p.stack.pop() orelse unreachable,
                    ) orelse return error.InvalidSeacCode;

                    const dy = p.stack.pop() orelse unreachable;
                    const dx = p.stack.pop() orelse unreachable; // checked earlier length is at least 4

                    if (ctx.width == null and
                        p.stack.items.len != 0) ctx.width = p.stack.pop();

                    ctx.has_seac = true;

                    if (depth == STACK_LIMIT) return error.NestingLimitReached;

                    const base_char_string = ctx
                        .metadata
                        .char_strings
                        .get(base_char[0]) orelse return error.InvalidSeacCode;

                    try parse_char_string_recursive(ctx, base_char_string, depth + 1, p);

                    p.x = dx;
                    p.y = dy;

                    const accent_char_string = ctx
                        .metadata
                        .char_strings
                        .get(accent_char[0]) orelse return error.InvalidSeacCode;

                    try parse_char_string_recursive(ctx, accent_char_string, depth + 1, p);
                } else if (p.stack.items.len == 1 and ctx.width == null)
                    ctx.width = p.stack.pop();

                if (!p.is_first_move_to) {
                    p.is_first_move_to = true;
                    p.builder.close();
                }
                if (!s.at_end()) return error.DataAfterEndChar;
                ctx.has_endchar = true;

                break;
            },
            .hint_mask, .counter_mask => {
                var len = p.stack.items.len;

                // We are ignoring the hint operators.
                p.stack.clearRetainingCapacity();

                // If the stack length is uneven, than the first value is a `width`.
                if (len & 1 != 0) {
                    len -= 1;
                    if (ctx.width == null) ctx.width = p.stack.items[0];
                }
                ctx.stems_len += @as(u32, @truncate(len)) >> 1;
                s.advance((ctx.stems_len + 7) >> 3);
            },
            .move_to => {
                const i: usize = if (p.stack.items.len == 3) i: {
                    if (ctx.width == null) ctx.width = p.stack.items[0];
                    break :i 1;
                } else 0;

                try p.parse_move_to(i);
            },
            .hor_move_to => {
                const i: usize = if (p.stack.items.len == 2) i: {
                    if (ctx.width == null) ctx.width = p.stack.items[0];
                    break :i 1;
                } else 0;

                try p.parse_horizontal_move_to(i);
            },
            .curve_line => try p.parse_curve_line(),
            .line_curve => try p.parse_line_curve(),
            .vv_curve_to => try p.parse_vv_curve_to(),
            .hh_curve_to => try p.parse_hh_curve_to(),
            .short_int => {
                const n = s.read(i16) catch return error.ReadOutOfBounds;
                p.stack.appendBounded(@floatFromInt(n)) catch return error.ArgumentsStackLimitReached;
            },
            .call_global_subroutine => {
                if (p.stack.items.len == 0) return error.InvalidArgumentsStackLength;
                if (depth == STACK_LIMIT) return error.NestingLimitReached;

                const subroutine_bias = cff.calc_subroutine_bias(ctx.metadata.global_subrs.len());
                const index = try cff.conv_subroutine_index(
                    p.stack.pop() orelse unreachable,
                    subroutine_bias,
                );
                const sub_char_string = ctx
                    .metadata
                    .global_subrs
                    .get(index) orelse return error.InvalidSubroutineIndex;

                try parse_char_string_recursive(ctx, sub_char_string, depth + 1, p);

                if (ctx.has_endchar and !ctx.has_seac) {
                    if (!s.at_end()) return error.DataAfterEndChar;
                    break;
                }
            },
            .vh_curve_to => try p.parse_vh_curve_to(),
            .hv_curve_to => try p.parse_hv_curve_to(),
            .fixed_16_16 => try p.parse_fixed(&s),
            _ => switch (@intFromEnum(op)) {
                // Reserved.
                0, 2, 9, 13, 15, 16, 17 => return error.InvalidOperator,
                32...246 => |d| try p.parse_int1(d),
                247...250 => |d| try p.parse_int2(d, &s),
                251...254 => |d| try p.parse_int3(d, &s),
                else => unreachable, // exhausted

            },
        }

        if (p.width_only and ctx.width != null) break;
    }

    // [RazrFalcon]
    // TODO: 'A charstring subroutine must end with either an endchar or a return operator.'

}

/// In CID fonts, to get local subroutines we have to:
///   1. Find Font DICT index via FDSelect by GID.
///   2. Get Font DICT data from FDArray using this index.
///   3. Get a Private DICT offset from a Font DICT.
///   4. Get a local subroutine offset from Private DICT.
///   5. Parse a local subroutine at offset.
fn parse_cid_local_subrs(
    data: []const u8,
    glyph_id: lib.GlyphId,
    cid: *const CIDMetadata,
) parser.Error!Index {
    const font_dict_index = try cid.fd_select.font_dict_index(glyph_id);
    const font_dict_data = cid.fd_array.get(font_dict_index) orelse return error.ParseFail;
    const private_dict_range = try parse_font_dict(font_dict_data);
    const private_dict_data = try utils.slice(data, private_dict_range);

    const private_dict = parse_private_dict(private_dict_data);
    const subroutines_offset = private_dict.local_subroutines_offset orelse return error.ParseFail;

    // 'The local subroutines offset is relative to the beginning
    // of the Private DICT data.'
    const start = try std.math.add(usize, private_dict_range[0], subroutines_offset);
    const subrs_data = try utils.slice(data, start);
    var s = parser.Stream.new(subrs_data);
    return try Index.parse(u16, &s);
}

fn parse_font_dict(
    data: []const u8,
) parser.Error!struct { usize, usize } {
    var operands_buffer: [MAX_OPERANDS_LEN]f64 = @splat(0.0);
    var dict_parser = DictionaryParser.new(data, &operands_buffer);
    while (dict_parser.parse_next(TopDict.Operator)) |operator|
        if (operator == .private_dict_size_and_offset)
            return try dict_parser.parse_range();

    return error.ParseFail;
}
fn seac_code_to_glyph_id(
    charset: Charset,
    n: f32,
) ?lib.GlyphId {
    const code = utils.f32_to_u8(n) orelse return null;
    const sid = cff.StringId{Encoding.STANDARD_ENCODING[code]};

    switch (charset) {
        // ISO Adobe charset only defines string ids up to 228 (zcaron)
        .iso_adobe => return if (code <= 228) .{sid[0]} else null,
        .expert, .expert_subset => return null,
        else => return charset.sid_to_gid(sid),
    }
}

// tests

const t = std.testing;

test "private dict size overflow" {
    const data = &.{
        0x00, 0x01, // count: 1
        0x01, // offset size: 1
        0x01, // index [0]: 1
        0x0C, // index [1]: 14
        0x1D, 0x7F, 0xFF, 0xFF, 0xFF, // length: i32::MAX
        0x1D, 0x7F, 0xFF, 0xFF, 0xFF, // offset: i32::MAX
        0x12, // operator: 18 (private)
    };
    var s = parser.Stream.new(data);
    const top_dict = try parse_top_dict(&s);
    try t.expectEqual(.{ 2147483647, 2147483647 }, top_dict.private_dict_range);
}

test "private dict negative char strings offset" {
    const data = &.{
        0x00, 0x01, // count: 1
        0x01, // offset size: 1
        0x01, // index [0]: 1
        0x03, // index [1]: 3
        // Item 0
        0x8A, // offset: -1
        0x11, // operator: 17 (char_string)
    };

    var s = parser.Stream.new(data);
    const top_dict = parse_top_dict(&s);
    try t.expectError(error.ParseFail, top_dict);
}

test "private dict no char strings offset operand" {
    const data = &.{
        0x00, 0x01, // count: 1
        0x01, // offset size: 1
        0x01, // index [0]: 1
        0x02, // index [1]: 2
        // Item 0
        // <-- No number here.
        0x11, // operator: 17 (char_string)
    };

    var s = parser.Stream.new(data);
    const top_dict = parse_top_dict(&s);
    try t.expectError(error.ParseFail, top_dict);
}

test "negative private dict offset and size" {
    const data = &.{
        0x00, 0x01, // count: 1
        0x01, // offset size: 1
        0x01, // index [0]: 1
        0x04, // index [1]: 4
        // Item 0
        0x8A, // length: -1
        0x8A, // offset: -1
        0x12, // operator: 18 (private)
    };

    var s = parser.Stream.new(data);
    const top_dict = try parse_top_dict(&s);
    try t.expectEqual(null, top_dict.private_dict_range);
}
