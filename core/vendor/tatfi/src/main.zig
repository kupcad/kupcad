const std = @import("std");
const ttf = @import("tatfi");

pub fn main() !void {
    defer std.debug.print(
        \\compiled successfully
        \\
    , .{});

    // [ARS] Original intent of this file was to make sure all functions compile, due to Zig's
    // lazy compilation model. Meanwhile, it has turned into a record of the library's public
    // interface.

    // Face methods
    var face = ttf.Face.parse("true", 0) catch return;
    _ = face.raw_face.table(.from_bytes("Wasm")) orelse {};
    _ = face.names();
    _ = face.style();
    _ = face.is_bold();
    _ = face.is_italic();
    _ = face.is_monospaced();
    _ = face.is_oblique();
    _ = face.is_variable();
    _ = face.italic_angle();
    _ = face.is_regular();
    const weight = face.weight();
    _ = weight.to_number();
    const width = face.width();
    _ = width.to_number();
    _ = face.ascender();
    _ = face.descender();
    _ = face.line_gap();
    _ = face.vertical_height();
    _ = face.vertical_line_gap();
    _ = face.typographic_ascender();
    _ = face.typographic_descender();
    _ = face.typographic_line_gap();
    _ = face.units_per_em();
    _ = face.x_height();
    _ = face.capital_height();
    _ = face.underline_metrics();
    _ = face.strikeout_metrics();
    _ = face.subscript_metrics();
    _ = face.superscript_metrics();
    _ = face.permissions();
    _ = face.is_subsetting_allowed();
    _ = face.is_outline_embedding_allowed();
    const ur = face.unicode_ranges();
    _ = ur.contains_char('a');
    _ = face.number_of_glyphs();
    _ = face.glyph_index(4);

    _ = face.glyph_index_by_name("boo");
    _ = face.glyph_variation_index(5, 0);

    _ = face.glyph_hor_advance(failing_allocator, .{9});
    _ = face.glyph_ver_advance(failing_allocator, .{9});

    _ = face.glyph_hor_side_bearing(.{3});
    _ = face.glyph_ver_side_bearing(.{3});
    _ = face.glyph_y_origin(.{9});
    _ = face.glyph_name(.{6});
    // use a real implementation of the OutlineBuilder interface
    _ = face.outline_glyph(failing_allocator, .{6}, ttf.OutlineBuilder.dummy_builder);
    _ = face.glyph_bounding_box(failing_allocator, .{53});
    const r = face.global_bounding_box();
    _ = r.width();
    _ = r.height();

    _ = face.glyph_raster_image(.{63}, 54);
    _ = face.glyph_svg_image(.{64});
    _ = face.is_color_glyph(.{54});
    _ = face.color_palettes();
    _ = face.paint_color_glyph(.{64}, 16, white, unsafe_painter) catch return;

    _ = face.variation_axes();
    _ = face.set_variation(.from_bytes("wght"), 300.0) catch return; // mutable method
    _ = face.variation_coordinates();
    _ = face.has_non_default_variation_coordinates();

    _ = face.glyph_phantom_points(failing_allocator, .{55});

    const raw_tables: ttf.RawFaceTables = .{};
    _ = ttf.Face.from_raw_tables(raw_tables) catch return;

    // misc
    _ = ttf.fonts_in_collection(&.{});

    // RawFace methods
    const raw_face = face.raw_face;
    _ = raw_face.table(.from_bytes("Wasm"));

    // FaceTables methods
    const tables = face.tables;
    _ = tables.head;
    _ = tables.hhea;
    _ = tables.maxp;
    _ = tables.bdat;
    if (tables.cbdt) |cbdt| _ = cbdt.get(.{64}, 0);
    if (tables.cff) |cff| {
        _ = cff.outline(.{64}, ttf.OutlineBuilder.dummy_builder) catch return;
        _ = cff.glyph_index(64);
        _ = cff.glyph_width(.{64});
        _ = cff.glyph_index_by_name("name");
        _ = cff.glyph_name(.{64});
        _ = cff.glyph_cid(.{65});
    }
    if (tables.cmap) |cmap| {
        const sts = cmap.subtables;
        const st = sts.get(0).?;
        _ = st.is_unicode();
        _ = st.glyph_index(54);
        _ = st.glyph_variation_index(4, 4);
        _ = st.codepoints(@as(u32, 1), func);
    }
    if (tables.colr) |colr| {
        _ = colr.is_simple();
        _ = colr.contains(.{4});
        // the following two methods are called through `face.paint_color_glyph`
        _ = colr.clip_box(.{5}, &.{});
        _ = colr.paint(.{4}, 0, unsafe_painter, &.{}, white) catch return;
    }
    _ = tables.ebdt;
    if (tables.glyf) |glyf| {
        _ = glyf.outline(.{5}, ttf.OutlineBuilder.dummy_builder);
        _ = glyf.bbox(.{4});
    }
    if (tables.hmtx) |hmtx| {
        _ = hmtx.advance(.{0});
        _ = hmtx.side_bearing(.{0});
    }
    if (tables.kern) |kern| {
        const subtables = kern.subtables;
        var iter = subtables.iterator();
        while (iter.next()) |subtable| {
            _ = subtable.glyphs_kerning(.{5}, .{4});

            // AAT specific table
            const st = subtable.format.format1;
            _ = st.class(.{0});
            _ = st.entry(0, 0);
            _ = st.kerning(@enumFromInt(0));
            _ = st.new_state(0);
        }
    }
    if (tables.name) |name| {
        const names = name.names;
        _ = names.get(4);
        var iter = names.iterator();
        while (iter.next()) |n| {
            _ = if (n.name_id == .family)
                n.to_string(failing_allocator);
            _ = n.language();
        }
    }
    if (tables.os2) |os2| {
        // direcly called by methods on Face
        _ = os2.weight();
        _ = os2.width();
        _ = os2.permissions();
        _ = os2.is_subsetting_allowed();
        _ = os2.is_outline_embedding_allowed();
        _ = os2.subscript_metrics();
        _ = os2.superscript_metrics();
        _ = os2.strikeout_metrics();
        _ = os2.unicode_ranges();
        _ = os2.style();
        _ = os2.is_bold();
        _ = os2.use_typographic_metrics();
        _ = os2.typographic_ascender();
        _ = os2.typographic_descender();
        _ = os2.typographic_line_gap();
        _ = os2.windows_ascender();
        _ = os2.windows_descender();
        _ = os2.x_height();
        _ = os2.capital_height();
    }
    if (tables.post) |post| {
        _ = post.glyph_name(.{5});
        _ = post.glyph_index_by_name("name");
        var iter = post.names();
        while (iter.next()) |_| {}
    }
    if (tables.sbix) |sbix| {
        _ = sbix.best_strike(5);
        const strikes = sbix.strikes;
        _ = strikes.get(4);
        _ = strikes.len();
        var iter = strikes.iterator();
        while (iter.next()) |strike| {
            _ = strike.get(.{4});
            _ = strike.len();
        }
    }
    if (tables.stat) |stat| {
        var iter = stat.subtables();
        while (iter.next()) |subtable| {
            _ = subtable.value();
            _ = subtable.contains(.{ .value = 0 });
            _ = subtable.name_id();
            _ = subtable.is_elidable();
            _ = subtable.is_older_sibling();
        }
        _ = stat.subtable_for_axis(.from_bytes("wdth"), null);
    }
    if (tables.svg) |svg| {
        const docs = svg.documents;
        _ = docs.get(0);
        _ = docs.find(.{0});
        var iter = docs.iterator();
        while (iter.next()) |_| {}
    }
    _ = tables.vhea;
    _ = tables.vmtx; // same as hmtx
    if (tables.vorg) |vorg| _ = vorg.glyph_y_origin(.{0});
    if (tables.opentype_layout.gdef) |gdef| {
        _ = gdef.glyph_class(.{0});
        _ = gdef.glyph_mark_attachment_class(.{4});
        _ = gdef.is_mark_glyph(.{4}, null);
        _ = gdef.glyph_variation_delta(0, 0, &.{});
    }
    if (tables.opentype_layout.gpos) |gpos| {
        const scripts = gpos.scripts;
        _ = scripts.get(0);
        _ = scripts.find(.from_bytes("arab"));
        _ = scripts.index(.from_bytes("arab"));
        var script_iter = scripts.iterator();
        while (script_iter.next()) |_| {}

        _ = gpos.features; // same api as `scripts`
        // until here is shared with gsub as well

        const lookups = gpos.lookups;
        var lookup_iter = lookups.iterator();
        while (lookup_iter.next()) |lookup| {
            const subtables = lookup.subtables; // also an iterator
            var sb_iter = subtables.iterator();
            const subtable = sb_iter.next().?;
            _ = subtable.coverage();
            // api goes deeper when you go into the variants.
        }
    }
    if (tables.opentype_layout.gsub) |gsub| {
        // api other than subtables of lookups is same as gpos.
        const lookups = gsub.lookups;
        const lookup = lookups.get(0).?;
        const subtables = lookup.subtables;
        const subtable = subtables.get(0).?; // difference with gpos stsrts here
        _ = subtable.coverage();
        // api goes deeper when you go into the variants.
    }
    if (tables.opentype_layout.math) |math| {
        const constants = math.constants.?;
        _ = constants.radical_degree_bottom_raise_percent();
        _ = constants.stretch_stack_gap_above_min();
        // and many others

        const glyph_infos = math.glyph_info.?;
        const math_values = glyph_infos.italic_corrections.?;
        _ = math_values.get(.{0}).?.device.?.hinting.x_delta(0, null);
        _ = glyph_infos.extended_shapes.?.get(.{0});
        _ = glyph_infos.extended_shapes.?.contains(.{0});
        _ = glyph_infos.kern_infos.?.get(.{0}).?.bottom_left.?.height(0);
    }
    _ = tables.apple_layout.ankr.?.points(.{0});
    _ = tables.apple_layout.feat.?.names.find(0);
    if (tables.apple_layout.kerx) |kerx| {
        var iter = kerx.subtables.iterator();
        while (iter.next()) |subtable| {
            _ = subtable.glyphs_kerning(.{0}, .{0});
            _ = subtable.glyphs_kerning(.{0}, .{0});
            _ = subtable.format.format1.glyphs_kerning(0);

            // for example
            const est = subtable.format.format1.state_table;
            _ = est.class(.{0});
            _ = est.entry(0, 0);
        }
    }
    if (tables.apple_layout.morx) |morx| {
        var iter = morx.chains.iterator();
        while (iter.next()) |chain| {
            var feature_iter = chain.features.iterator();
            while (feature_iter.next()) |_| {}

            var subtable_iter = chain.subtables.iterator();
            while (subtable_iter.next()) |subtable| {
                _ = subtable.kind.contextual.lookup(0);
            }
        }
    }
    if (tables.apple_layout.trak) |trak| {
        var iter = trak.horizontal.tracks.iterator();
        while (iter.next()) |_| {}
    }
    _ = tables.variable_fonts.avar;
    _ = tables.variable_fonts.cff2;
    if (tables.variable_fonts.fvar) |fvar| {
        var iter = fvar.instances.iterator();
        while (iter.next()) |_| {}
    }
    _ = tables.variable_fonts.gvar;
    _ = tables.variable_fonts.hvar;
    _ = tables.variable_fonts.mvar;
    _ = tables.variable_fonts.vvar;
}

// [ARS] To be replaced by std.mem.Allocator.failing should zig upgrade to 0.16.*
pub const failing_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};
const vtable: std.mem.Allocator.VTable = .{
    .alloc = noAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};
fn noAlloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
    return null;
}

const unsafe_painter = ttf.tables.colr.Painter{
    .ptr = undefined,
    .vtable = undefined,
};

const white: ttf.RgbaColor = .{ .red = 255, .green = 255, .blue = 255, .alpha = 255 };

fn func(_: u21, _: u32) void {}
