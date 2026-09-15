//! A [Glyph Definition Table](
//! https://docs.microsoft.com/en-us/typography/opentype/spec/gdef) implementation.

const cfg = @import("config");
const lib = @import("../lib.zig");
const parser = @import("../parser.zig");
const utils = @import("../utils.zig");
const ggg = @import("../ggg.zig");

const ItemVariationStore = @import("../var_store.zig");

const Table = @This();

glyph_classes: ?ggg.ClassDefinition,
mark_attach_classes: ?ggg.ClassDefinition,
mark_glyph_coverage_offsets: ?struct { []const u8, parser.LazyArray16(parser.Offset32) },
variation_store: if (cfg.variable_fonts) ?ItemVariationStore else void,

/// Parses a table from raw data.
pub fn parse(
    data: []const u8,
) parser.Error!Table {
    var s = parser.Stream.new(data);
    const version = try s.read(u32);

    if (version != 0x00010000 and
        version != 0x00010002 and
        version != 0x00010003) return error.ParseFail;

    const glyph_class_def_offset = try s.read_optional(parser.Offset16);
    s.skip(parser.Offset16); // attachListOffset
    s.skip(parser.Offset16); // ligCaretListOffset
    const mark_attach_class_def_offset = try s.read_optional(parser.Offset16);

    const mark_glyph_sets_def_offset =
        if (version > 0x00010000) try s.read_optional(parser.Offset16) else null;

    const var_store_offset = if (cfg.variable_fonts and version > 0x00010002)
        try s.read_optional(parser.Offset32)
    else
        null;

    return .{
        .glyph_classes = o: {
            const offset = glyph_class_def_offset orelse break :o null;
            break :o ggg.ClassDefinition.parse(
                utils.slice(data, offset[0]) catch break :o null,
            ) catch null;
        },
        .mark_attach_classes = o: {
            const offset = mark_attach_class_def_offset orelse break :o null;
            break :o ggg.ClassDefinition.parse(
                utils.slice(data, offset[0]) catch break :o null,
            ) catch null;
        },
        .mark_glyph_coverage_offsets = o: {
            const offset = mark_glyph_sets_def_offset orelse break :o null;
            const subdata = utils.slice(data, offset[0]) catch break :o null;
            var sub_s = parser.Stream.new(subdata);
            const format = try sub_s.read(u16);

            if (format != 1) break :o null;
            const count = sub_s.read(u16) catch break :o null;
            const array = sub_s.read_array(parser.Offset32, count) catch break :o null;

            break :o .{ subdata, array };
        },
        .variation_store = if (cfg.variable_fonts) o: {
            const offset = var_store_offset orelse break :o null;
            const subdata = utils.slice(data, offset[0]) catch break :o null;
            var sub_s = parser.Stream.new(subdata);

            break :o ItemVariationStore.parse(&sub_s) catch null;
        },
    };
}

/// Returns glyph's class according to
/// [Glyph Class Definition Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gdef#glyph-class-definition-table).
///
/// Returns `null` when *Glyph Class Definition Table* is not set
/// or glyph class is not set or invalid.
pub fn glyph_class(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ?GlyphClass {
    const classes = self.glyph_classes orelse return null;
    return switch (classes.get(glyph_id)) {
        1 => .base,
        2 => .ligature,
        3 => .mark,
        4 => .component,
        else => null,
    };
}

/// Returns glyph's mark attachment class according to
/// [Mark Attachment Class Definition Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gdef#mark-attachment-class-definition-table).
///
/// All glyphs not assigned to a class fall into Class 0.
pub fn glyph_mark_attachment_class(
    self: *const Table,
    glyph_id: lib.GlyphId,
) ggg.Class {
    const def = self.mark_attach_classes orelse return 0;
    return def.get(glyph_id);
}

/// Checks that glyph is a mark according to
/// [Mark Glyph Sets Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gdef#mark-glyph-sets-table).
///
/// `set_index` allows checking a specific glyph coverage set.
/// Otherwise all sets will be checked.
pub fn is_mark_glyph(
    self: *const Table,
    glyph_id: lib.GlyphId,
    set_index: ?u16,
) bool {
    return is_mark_glyph_impl(self, glyph_id, set_index) catch false;
}

/// Returns glyph's variation delta at a specified index according to
/// [Item Variation Store Table](
/// https://docs.microsoft.com/en-us/typography/opentype/spec/gdef#item-variation-store-table).
pub fn glyph_variation_delta(
    self: *const Table,
    outer_index: u16,
    inner_index: u16,
    coordinates: []const lib.NormalizedCoordinate,
) ?f32 {
    if (!cfg.variable_fonts) @compileError("glyph_variation_delta needs variable_fonts enabled");

    const store = self.variation_store orelse return null;
    return store.parse_delta(outer_index, inner_index, coordinates) catch null;
}

pub const GlyphClass = enum(u3) {
    base = 1,
    ligature = 2,
    mark = 3,
    component = 4,
};

fn is_mark_glyph_impl(
    self: *const Table,
    glyph_id: lib.GlyphId,
    set_index_maybe: ?u16,
) !bool {
    const data, const offsets = self.mark_glyph_coverage_offsets orelse return false;
    if (set_index_maybe) |set_index| {
        if (offsets.get(set_index)) |offset| {
            const coverage = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
            if (coverage.contains(glyph_id)) return true;
        }
    } else {
        var iter = offsets.iterator();
        while (iter.next()) |offset| {
            const coverage = try ggg.Coverage.parse(try utils.slice(data, offset[0]));
            if (coverage.contains(glyph_id)) return true;
        }
    }

    return false;
}
