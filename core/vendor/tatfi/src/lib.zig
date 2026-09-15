//! A high-level, safe, zero-allocation font parser for:
//! * [TrueType](https://docs.microsoft.com/en-us/typography/truetype/),
//! * [OpenType](https://docs.microsoft.com/en-us/typography/opentype/spec/), and
//! * [AAT](https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6AATIntro.html).
//!
//! Font parsing starts with a `Face`.

const std = @import("std");
const cfg = @import("config");
const parser = @import("parser.zig");
const utils = @import("utils.zig");

pub const tables = @import("tables.zig");
pub const apple_layout = @import("aat.zig");
pub const opentype_layout = @import("ggg.zig");

/// A type-safe wrapper for glyph ID.
pub const GlyphId = struct { u16 };

/// A font face.
///
/// Provides a high-level API for working with TrueType fonts.
/// If you're not familiar with how TrueType works internally, you should use this type.
/// If you do know and want a bit more low-level access - checkout `FaceTables`.
///
/// Note that `Face` doesn't own the font data and doesn't allocate anything in heap.
/// Therefore you cannot "store" it. The idea is that you should parse the `Face`
/// when needed, get required data and forget about it.
/// That's why the initial parsing is highly optimized and should not become a bottleneck.
///
/// Noe that this struct is almost 2KB big.
pub const Face = struct {
    raw_face: RawFace,
    tables: FaceTables, // Parsed tables.
    coordinates: if (cfg.variable_fonts) VarCoords else void,

    const Self = @This();

    /// Creates a new `Face` from a raw data.
    ///
    /// `index` indicates the specific font face in a font collection.
    /// Use `fonts_in_collection` to get the total number of font faces.
    /// Set to 0 if unsure.
    ///
    /// This method will do some parsing and sanitization,
    /// but in general can be considered free. No significant performance overhead.
    ///
    /// Required tables: `head`, `hhea` and `maxp`.
    ///
    /// If an optional table has invalid data it will be skipped.
    pub fn parse(
        data: []const u8,
        index: u32,
    ) FaceParsingError!Self {
        const raw_face = try RawFace.parse(data, index);
        const raw_tables: RawFaceTables = Self.collect_tables(raw_face);

        var face: Self = .{
            .raw_face = raw_face,
            .coordinates = if (cfg.variable_fonts) VarCoords{},
            .tables = try Self.parse_tables(raw_tables),
        };

        if (cfg.variable_fonts) if (face.tables.variable_fonts.fvar) |fvar| {
            face.coordinates.len = @min(fvar.axes.len(), MAX_VAR_COORDS);
        };

        return face;
    }

    fn collect_tables(
        raw_face: RawFace,
    ) RawFaceTables {
        var ret_tables: RawFaceTables = .{};

        var iterator = raw_face.table_records.iterator();
        while (iterator.next()) |record| {
            const table_data = utils.slice(raw_face.data, .{ record.offset, record.length }) catch continue;

            switch (record.tag.inner) {
                Tag.from_bytes("bdat").inner => ret_tables.bdat = table_data,
                Tag.from_bytes("bloc").inner => ret_tables.bloc = table_data,
                Tag.from_bytes("CBDT").inner => ret_tables.cbdt = table_data,
                Tag.from_bytes("CBLC").inner => ret_tables.cblc = table_data,
                Tag.from_bytes("CFF ").inner => ret_tables.cff = table_data,
                Tag.from_bytes("CFF2").inner => if (cfg.variable_fonts) {
                    ret_tables.variable_fonts.cff2 = table_data;
                },
                Tag.from_bytes("COLR").inner => ret_tables.colr = table_data,
                Tag.from_bytes("CPAL").inner => ret_tables.cpal = table_data,
                Tag.from_bytes("EBDT").inner => ret_tables.ebdt = table_data,
                Tag.from_bytes("EBLC").inner => ret_tables.eblc = table_data,
                Tag.from_bytes("GDEF").inner => if (cfg.opentype_layout) {
                    ret_tables.opentype_layout.gdef = table_data;
                },
                Tag.from_bytes("GPOS").inner => if (cfg.opentype_layout) {
                    ret_tables.opentype_layout.gpos = table_data;
                },
                Tag.from_bytes("GSUB").inner => if (cfg.opentype_layout) {
                    ret_tables.opentype_layout.gsub = table_data;
                },
                Tag.from_bytes("MATH").inner => if (cfg.opentype_layout) {
                    ret_tables.opentype_layout.math = table_data;
                },
                Tag.from_bytes("HVAR").inner => if (cfg.variable_fonts) {
                    ret_tables.variable_fonts.hvar = table_data;
                },
                Tag.from_bytes("MVAR").inner => if (cfg.variable_fonts) {
                    ret_tables.variable_fonts.mvar = table_data;
                },
                Tag.from_bytes("OS/2").inner => ret_tables.os2 = table_data,
                Tag.from_bytes("SVG ").inner => ret_tables.svg = table_data,
                Tag.from_bytes("VORG").inner => ret_tables.vorg = table_data,
                Tag.from_bytes("VVAR").inner => if (cfg.variable_fonts) {
                    ret_tables.variable_fonts.vvar = table_data;
                },
                Tag.from_bytes("ankr").inner => if (cfg.apple_layout) {
                    ret_tables.apple_layout.ankr = table_data;
                },
                Tag.from_bytes("avar").inner => if (cfg.variable_fonts) {
                    ret_tables.variable_fonts.avar = table_data;
                },
                Tag.from_bytes("cmap").inner => ret_tables.cmap = table_data,
                Tag.from_bytes("feat").inner => if (cfg.apple_layout) {
                    ret_tables.apple_layout.feat = table_data;
                },
                Tag.from_bytes("fvar").inner => if (cfg.variable_fonts) {
                    ret_tables.variable_fonts.fvar = table_data;
                },
                Tag.from_bytes("glyf").inner => ret_tables.glyf = table_data,
                Tag.from_bytes("gvar").inner => if (cfg.variable_fonts) {
                    ret_tables.variable_fonts.gvar = table_data;
                },
                Tag.from_bytes("head").inner => ret_tables.head = table_data,
                Tag.from_bytes("hhea").inner => ret_tables.hhea = table_data,
                Tag.from_bytes("hmtx").inner => ret_tables.hmtx = table_data,
                Tag.from_bytes("kern").inner => ret_tables.kern = table_data,
                Tag.from_bytes("kerx").inner => if (cfg.apple_layout) {
                    ret_tables.apple_layout.kerx = table_data;
                },
                Tag.from_bytes("loca").inner => ret_tables.loca = table_data,
                Tag.from_bytes("maxp").inner => ret_tables.maxp = table_data,
                Tag.from_bytes("morx").inner => if (cfg.apple_layout) {
                    ret_tables.apple_layout.morx = table_data;
                },
                Tag.from_bytes("name").inner => ret_tables.name = table_data,
                Tag.from_bytes("post").inner => ret_tables.post = table_data,
                Tag.from_bytes("sbix").inner => ret_tables.sbix = table_data,
                Tag.from_bytes("STAT").inner => ret_tables.stat = table_data,
                Tag.from_bytes("trak").inner => if (cfg.apple_layout) {
                    ret_tables.apple_layout.trak = table_data;
                },
                Tag.from_bytes("vhea").inner => ret_tables.vhea = table_data,
                Tag.from_bytes("vmtx").inner => ret_tables.vmtx = table_data,
                else => {},
            }
        }

        return ret_tables;
    }

    fn parse_tables(
        raw_tables: RawFaceTables,
    ) FaceParsingError!FaceTables {
        const head = tables.head.parse(raw_tables.head) catch
            return error.NoHeadTable;
        const hhea = tables.hhea.parse(raw_tables.hhea) catch
            return error.NoHheaTable;
        const maxp = tables.maxp.parse(raw_tables.maxp) catch
            return error.NoMaxpTable;

        const hmtx = t: {
            const data = raw_tables.hmtx orelse break :t null;
            break :t tables.hmtx.parse(
                hhea.number_of_metrics,
                maxp.number_of_glyphs,
                data,
            ) catch null;
        };

        const vhea = v: {
            const data = raw_tables.vhea orelse break :v null;
            break :v tables.vhea.parse(data) catch null;
        };
        const vmtx = t: {
            const data = raw_tables.vmtx orelse break :t null;
            break :t tables.hmtx.parse(
                (vhea orelse break :t null).number_of_metrics,
                maxp.number_of_glyphs,
                data,
            ) catch null;
        };

        const loca = t: {
            const data = raw_tables.loca orelse break :t null;
            break :t tables.loca.Table.parse(
                maxp.number_of_glyphs,
                head.index_to_location_format,
                data,
            ) catch null;
        };

        const glyf = t: {
            const loca_table = loca orelse break :t null;
            const data = raw_tables.glyf orelse break :t null;
            break :t tables.glyf.parse(loca_table, data);
        };

        const bdat = b: {
            const bloc_data = raw_tables.bloc orelse break :b null;
            const bloc = tables.cblc.parse(bloc_data);
            const data = raw_tables.bdat orelse break :b null;
            break :b tables.cbdt.parse(bloc, data);
        };

        const cbdt = c: {
            const cblc_data = raw_tables.cblc orelse break :c null;
            const cblc = tables.cblc.parse(cblc_data);
            const data = raw_tables.cbdt orelse break :c null;
            break :c tables.cbdt.parse(cblc, data);
        };

        const ebdt = e: {
            const eblc_data = raw_tables.eblc orelse break :e null;
            const eblc = tables.cblc.parse(eblc_data);
            const data = raw_tables.ebdt orelse break :e null;
            break :e tables.cbdt.parse(eblc, data);
        };

        const cpal = c: {
            const data = raw_tables.cpal orelse break :c null;
            break :c tables.cpal.parse(data) catch null;
        };

        const colr = c: {
            const cpal_table = cpal orelse break :c null;
            const data = raw_tables.colr orelse break :c null;
            break :c tables.colr.parse(cpal_table, data) catch null;
        };

        return .{
            .head = head,
            .hhea = hhea,
            .maxp = maxp,

            .bdat = bdat,
            .cbdt = cbdt,
            .cff = c: {
                const data = raw_tables.cff orelse break :c null;
                break :c tables.cff1.parse_with_upem(
                    data,
                    head.units_per_em,
                ) catch null;
            },
            .cmap = c: {
                const data = raw_tables.cmap orelse break :c null;
                break :c tables.cmap.parse(data) catch null;
            },
            .colr = colr,
            .ebdt = ebdt,
            .glyf = glyf,
            .hmtx = hmtx,
            .kern = k: {
                const data = raw_tables.kern orelse break :k null;
                break :k tables.kern.parse(data) catch null;
            },
            .name = n: {
                const data = raw_tables.name orelse break :n null;
                break :n tables.name.parse(data) catch null;
            },
            .os2 = o: {
                const data = raw_tables.os2 orelse break :o null;
                break :o tables.os2.parse(data) catch null;
            },
            .post = p: {
                const data = raw_tables.post orelse break :p null;
                break :p tables.post.parse(data) catch null;
            },
            .sbix = s: {
                const data = raw_tables.sbix orelse break :s null;
                break :s tables.sbix.parse(
                    maxp.number_of_glyphs,
                    data,
                ) catch null;
            },
            .stat = s: {
                const data = raw_tables.stat orelse break :s null;
                break :s tables.stat.parse(data) catch null;
            },
            .svg = s: {
                const data = raw_tables.svg orelse break :s null;
                break :s tables.svg.parse(data) catch null;
            },
            .vhea = vhea,
            .vmtx = vmtx,
            .vorg = v: {
                const data = raw_tables.vorg orelse break :v null;
                break :v tables.vorg.parse(data) catch null;
            },
            .opentype_layout = if (cfg.opentype_layout) .{
                .gdef = g: {
                    const data = raw_tables.opentype_layout.gdef orelse break :g null;
                    break :g tables.gdef.parse(data) catch null;
                },
                .gpos = g: {
                    const data = raw_tables.opentype_layout.gpos orelse break :g null;
                    break :g opentype_layout.LayoutTable(.gpos).parse(data) catch null;
                },
                .gsub = g: {
                    const data = raw_tables.opentype_layout.gsub orelse break :g null;
                    break :g opentype_layout.LayoutTable(.gsub).parse(data) catch null;
                },
                .math = m: {
                    const data = raw_tables.opentype_layout.math orelse break :m null;
                    break :m tables.math.parse(data) catch null;
                },
            },
            .apple_layout = if (cfg.apple_layout) .{
                .ankr = a: {
                    const data = raw_tables.apple_layout.ankr orelse break :a null;
                    break :a tables.ankr.parse(
                        maxp.number_of_glyphs,
                        data,
                    ) catch null;
                },
                .feat = f: {
                    const data = raw_tables.apple_layout.feat orelse break :f null;
                    break :f tables.feat.parse(data) catch null;
                },
                .kerx = k: {
                    const data = raw_tables.apple_layout.kerx orelse break :k null;
                    break :k tables.kerx.parse(
                        maxp.number_of_glyphs,
                        data,
                    ) catch null;
                },
                .morx = m: {
                    const data = raw_tables.apple_layout.morx orelse break :m null;
                    break :m tables.morx.parse(
                        maxp.number_of_glyphs,
                        data,
                    ) catch null;
                },
                .trak = t: {
                    const data = raw_tables.apple_layout.trak orelse break :t null;
                    break :t tables.trak.parse(data) catch null;
                },
            },
            .variable_fonts = if (cfg.variable_fonts) .{
                .avar = a: {
                    const data = raw_tables.variable_fonts.avar orelse break :a null;
                    break :a tables.avar.parse(data) catch null;
                },
                .cff2 = c: {
                    const data = raw_tables.variable_fonts.cff2 orelse break :c null;
                    break :c tables.cff2.parse(data) catch null;
                },
                .fvar = f: {
                    const data = raw_tables.variable_fonts.fvar orelse break :f null;
                    break :f tables.fvar.parse(data) catch null;
                },
                .gvar = g: {
                    const data = raw_tables.variable_fonts.gvar orelse break :g null;
                    break :g tables.gvar.parse(data) catch null;
                },
                .hvar = h: {
                    const data = raw_tables.variable_fonts.hvar orelse break :h null;
                    break :h tables.hvar.parse(data) catch null;
                },
                .mvar = m: {
                    const data = raw_tables.variable_fonts.mvar orelse break :m null;
                    break :m tables.mvar.parse(data) catch null;
                },
                .vvar = v: {
                    const data = raw_tables.variable_fonts.vvar orelse break :v null;
                    break :v tables.vvar.parse(data) catch null;
                },
            },
        };
    }

    /// Creates a new `Face` from provided `RawFaceTables`.
    ///
    /// Does not create a `RawFace`
    pub fn from_raw_tables(
        raw_tables: RawFaceTables,
    ) FaceParsingError!Face {
        var face: Face = .{
            .raw_face = .{ .data = &.{}, .table_records = .{} },
            .coordinates = if (cfg.variable_fonts) .{},
            .tables = try Face.parse_tables(raw_tables),
        };

        if (cfg.variable_fonts) if (face.tables.variable_fonts.fvar) |fvar| {
            face.coordinates.len = @min(fvar.axes.len(), MAX_VAR_COORDS);
        };

        return face;
    }

    /// Returns a list of names.
    ///
    /// Contains face name and other strings.
    pub fn names(
        self: *const Face,
    ) tables.name.Names {
        const t: tables.name = self.tables.name orelse .{};
        return t.names;
    }

    /// Returns face style.
    pub fn style(
        self: *const Face,
    ) tables.os2.Style {
        const t = self.tables.os2 orelse return .normal;
        return t.style();
    }

    /// Checks that face is marked as *Regular*.
    ///
    /// Returns `true` when OS/2 table is not present.
    pub fn is_regular(
        self: *const Face,
    ) bool {
        return self.style() == .normal;
    }

    /// Checks that face is marked as *Italic*.
    pub fn is_italic(
        self: *const Face,
    ) bool {
        // A face can have a Normal style and a non-zero italic angle, which also makes it italic.
        return self.style() == .italic or self.italic_angle() != 0.0;
    }

    /// Returns face's italic angle.
    ///
    /// Returns `0.0` when `post` table is not present.
    pub fn italic_angle(
        self: *const Face,
    ) f32 {
        const t = self.tables.post orelse return 0.0;
        return t.italic_angle;
    }

    /// Checks that face is marked as *Bold*.
    ///
    /// Returns `false` when OS/2 table is not present.
    pub fn is_bold(
        self: *const Face,
    ) bool {
        const t = self.tables.os2 orelse return false;
        return t.is_bold();
    }

    /// Checks that face is marked as *Oblique*.
    ///
    /// Returns `false` when OS/2 table is not present or when its version is < 4.
    pub fn is_oblique(
        self: *const Face,
    ) bool {
        return self.style() == .oblique;
    }

    /// Checks that face is marked as *Monospaced*.
    ///
    /// Returns `false` when `post` table is not present.
    pub fn is_monospaced(
        self: *const Face,
    ) bool {
        const t = self.tables.post orelse return false;
        return t.is_monospaced;
    }

    /// Checks that face is variable.
    ///
    /// Simply checks the presence of a `fvar` table.
    /// returns 'false' if variable_fonts is not enabled
    pub fn is_variable(
        self: *const Face,
    ) bool {
        if (cfg.variable_fonts) {
            // `fvar.parse` already checked that `axisCount` is non-zero.
            return self.tables.variable_fonts.fvar != null;
        } else return false;
    }

    /// Returns face's weight.
    ///
    /// Returns `Weight.normal` when OS/2 table is not present.
    pub fn weight(
        self: *const Face,
    ) tables.os2.Weight {
        const t = self.tables.os2 orelse return .normal;
        return t.weight();
    }

    /// Returns face's width.
    ///
    /// Returns `Width.normal` when OS/2 table is not present or when value is invalid.
    pub fn width(
        self: *const Face,
    ) tables.os2.Width {
        const t = self.tables.os2 orelse return .normal;
        return t.width();
    }

    // Read https://github.com/freetype/freetype/blob/49270c17011491227ec7bd3fb73ede4f674aa065/src/sfnt/sfobjs.c#L1279
    // to learn more about the logic behind the following functions.

    /// Returns a horizontal face ascender.
    ///
    /// This method is affected by variation axes.
    pub fn ascender(
        self: *const Face,
    ) i16 {
        if (self.tables.os2) |os2| if (os2.use_typographic_metrics()) {
            const value = os2.typographic_ascender();
            return self.apply_metrics_variation(Tag.from_bytes("hasc"), value);
        };

        var value = self.tables.hhea.ascender;

        if (value == 0) if (self.tables.os2) |os2| {
            value = os2.typographic_ascender();
            if (value == 0) {
                value = os2.windows_ascender();
                value = self.apply_metrics_variation(Tag.from_bytes("hcla"), value);
            } else {
                value = self.apply_metrics_variation(Tag.from_bytes("hasc"), value);
            }
        };

        return value;
    }

    /// Returns a horizontal face descender.
    ///
    /// This method is affected by variation axes.
    pub fn descender(
        self: *const Face,
    ) i16 {
        if (self.tables.os2) |os2| if (os2.use_typographic_metrics()) {
            const value = os2.typographic_descender();
            return self.apply_metrics_variation(Tag.from_bytes("hdsc"), value);
        };

        var value = self.tables.hhea.descender;

        if (value == 0) if (self.tables.os2) |os2| {
            value = os2.typographic_descender();
            if (value == 0) {
                value = os2.windows_descender();
                value = self.apply_metrics_variation(Tag.from_bytes("hcld"), value);
            } else {
                value = self.apply_metrics_variation(Tag.from_bytes("hdsc"), value);
            }
        };

        return value;
    }

    /// Returns face's height.
    ///
    /// This method is affected by variation axes.
    pub fn height(
        self: *const Face,
    ) i16 {
        return self.ascender() - self.descender();
    }

    /// Returns a horizontal face line gap.
    ///
    /// This method is affected by variation axes.
    pub fn line_gap(
        self: *const Face,
    ) i16 {
        if (self.tables.os2) |os2| if (os2.use_typographic_metrics()) {
            const value = os2.typographic_line_gap();
            return self.apply_metrics_variation(Tag.from_bytes("hlgp"), value);
        };

        var value = self.tables.hhea.line_gap;

        // For line gap, we have to check that ascender or descender are 0, not line gap itself.
        if (self.tables.hhea.ascender == 0 or self.tables.hhea.descender == 0)
            if (self.tables.os2) |os2| {
                if (os2.typographic_ascender() != 0 or os2.typographic_descender() != 0) {
                    value = os2.typographic_line_gap();
                    value = self.apply_metrics_variation(Tag.from_bytes("hlgp"), value);
                } else value = 0;
            };

        return value;
    }

    /// Returns a horizontal typographic face ascender.
    ///
    /// Prefer `Face.ascender` unless you explicitly want this. This is a more
    /// low-level alternative.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present.
    pub fn typographic_ascender(
        self: *const Face,
    ) ?i16 {
        const os2 = self.tables.os2 orelse return null;
        const v = os2.typographic_ascender();
        return self.apply_metrics_variation(Tag.from_bytes("hasc"), v);
    }

    /// Returns a horizontal typographic face descender.
    ///
    /// Prefer `Face.descender` unless you explicitly want this. This is a more
    /// low-level alternative.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present.
    pub fn typographic_descender(
        self: *const Face,
    ) ?i16 {
        const os2 = self.tables.os2 orelse return null;
        const v = os2.typographic_descender();
        return self.apply_metrics_variation(Tag.from_bytes("hdsc"), v);
    }

    /// Returns a horizontal typographic face line gap.
    ///
    /// Prefer `Face.line_gap` unless you explicitly want this. This is a more
    /// low-level alternative.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present.
    pub fn typographic_line_gap(
        self: *const Face,
    ) ?i16 {
        const os2 = self.tables.os2 orelse return null;
        const v = os2.typographic_line_gap();
        return self.apply_metrics_variation(Tag.from_bytes("hlgp"), v);
    }

    /// Returns a vertical face ascender.
    ///
    /// This method is affected by variation axes.
    pub fn vertical_ascender(
        self: *const Face,
    ) ?i16 {
        const vhea = self.tables.vhea orelse return null;
        const v = vhea.ascender;
        return self.apply_metrics_variation(Tag.from_bytes("vasc"), v);
    }

    /// Returns a vertical face descender.
    ///
    /// This method is affected by variation axes.
    pub fn vertical_descender(
        self: *const Face,
    ) ?i16 {
        const vhea = self.tables.vhea orelse return null;
        const v = vhea.descender;
        return self.apply_metrics_variation(Tag.from_bytes("vdsc"), v);
    }

    /// Returns a vertical face height.
    ///
    /// This method is affected by variation axes.
    pub fn vertical_height(
        self: *const Face,
    ) ?i16 {
        const a = self.vertical_ascender() orelse return null;
        const d = self.vertical_descender() orelse return null;
        return a + d;
    }

    /// Returns a vertical face line gap.
    ///
    /// This method is affected by variation axes.
    pub fn vertical_line_gap(
        self: *const Face,
    ) ?i16 {
        const vhea = self.tables.vhea orelse return null;
        const v = vhea.line_gap;
        return self.apply_metrics_variation(Tag.from_bytes("vlgp"), v);
    }

    /// Returns face's units per EM.
    ///
    /// Guarantee to be in a 16..=16384 range.
    pub fn units_per_em(
        self: *const Face,
    ) u16 {
        return self.tables.head.units_per_em;
    }

    /// Returns face's x height.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present or when its version is < 2.
    pub fn x_height(
        self: *const Face,
    ) ?i16 {
        const os2 = self.tables.os2 orelse return null;
        const v = os2.x_height() orelse return null;
        return self.apply_metrics_variation(Tag.from_bytes("xhgt"), v);
    }

    /// Returns face's capital height.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present or when its version is < 2.
    pub fn capital_height(
        self: *const Face,
    ) ?i16 {
        const os2 = self.tables.os2 orelse return null;
        const v = os2.capital_height() orelse return null;
        return self.apply_metrics_variation(Tag.from_bytes("cpht"), v);
    }

    /// Returns face's underline metrics.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when `post` table is not present.
    pub fn underline_metrics(
        self: *const Face,
    ) ?LineMetrics {
        const t = self.tables.post orelse return null;
        var metrics = t.underline_metrics;

        if (self.is_variable()) {
            metrics.position = self.apply_metrics_variation(
                Tag.from_bytes("undo"),
                metrics.position,
            );
            metrics.thickness = self.apply_metrics_variation(
                Tag.from_bytes("unds"),
                metrics.thickness,
            );
        }

        return metrics;
    }

    /// Returns face's strikeout metrics.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present.
    pub fn strikeout_metrics(
        self: *const Face,
    ) ?LineMetrics {
        const t = self.tables.os2 orelse return null;
        var metrics = t.strikeout_metrics();

        if (self.is_variable()) {
            metrics.position = self.apply_metrics_variation(
                Tag.from_bytes("stro"),
                metrics.position,
            );
            metrics.thickness = self.apply_metrics_variation(
                Tag.from_bytes("strs"),
                metrics.thickness,
            );
        }

        return metrics;
    }

    /// Returns face's subscript metrics.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present.
    pub fn subscript_metrics(
        self: *const Face,
    ) ?tables.os2.ScriptMetrics {
        const t = self.tables.os2 orelse return null;
        var metrics = t.subscript_metrics();

        if (self.is_variable()) {
            metrics.x_size = self.apply_metrics_variation(
                Tag.from_bytes("sbxs"),
                metrics.x_size,
            );
            metrics.y_size = self.apply_metrics_variation(
                Tag.from_bytes("sbys"),
                metrics.y_size,
            );
            metrics.x_offset = self.apply_metrics_variation(
                Tag.from_bytes("sbxo"),
                metrics.x_offset,
            );
            metrics.y_offset = self.apply_metrics_variation(
                Tag.from_bytes("sbyo"),
                metrics.y_offset,
            );
        }

        return metrics;
    }

    /// Returns face's superscript metrics.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when OS/2 table is not present.
    pub fn superscript_metrics(
        self: *const Face,
    ) ?tables.os2.ScriptMetrics {
        const t = self.tables.os2 orelse return null;
        var metrics = t.superscript_metrics();

        if (self.is_variable()) {
            metrics.x_size = self.apply_metrics_variation(
                Tag.from_bytes("spxs"),
                metrics.x_size,
            );
            metrics.y_size = self.apply_metrics_variation(
                Tag.from_bytes("spys"),
                metrics.y_size,
            );
            metrics.x_offset = self.apply_metrics_variation(
                Tag.from_bytes("spxo"),
                metrics.x_offset,
            );
            metrics.y_offset = self.apply_metrics_variation(
                Tag.from_bytes("spyo"),
                metrics.y_offset,
            );
        }

        return metrics;
    }

    /// Returns face permissions.
    ///
    /// Returns `null` in case of a malformed value.
    pub fn permissions(
        self: *const Face,
    ) ?tables.os2.Permissions {
        const t = self.tables.os2 orelse return null;
        return t.permissions();
    }

    /// Checks if the face allows embedding a subset, further restricted by `Self.permissions`.
    pub fn is_subsetting_allowed(
        self: *const Face,
    ) bool {
        const t = self.tables.os2 orelse return false;
        return t.is_subsetting_allowed();
    }

    /// Checks if the face allows outline data to be embedded.
    ///
    /// If false, only bitmaps may be embedded in accordance with `Self.permissions`.
    ///
    /// If the font contains no bitmaps and this flag is not set, it implies no embedding is allowed.
    pub fn is_outline_embedding_allowed(
        self: *const Face,
    ) bool {
        const t = self.tables.os2 orelse return false;
        return t.is_outline_embedding_allowed();
    }

    /// Returns [Unicode Ranges](https://docs.microsoft.com/en-us/typography/opentype/spec/os2#ur).
    pub fn unicode_ranges(
        self: *const Face,
    ) tables.os2.UnicodeRanges {
        const t = self.tables.os2 orelse return .{};
        return t.unicode_ranges();
    }

    /// Returns a total number of glyphs in the face.
    ///
    /// Never zero.
    ///
    /// The value was already parsed, so this function doesn't involve any parsing.
    pub fn number_of_glyphs(
        self: *const Face,
    ) u16 {
        return self.tables.maxp.number_of_glyphs;
    }

    /// Resolves a Glyph ID for a code point.
    ///
    /// Returns `null` instead of `0` when glyph is not found.
    ///
    /// All subtable formats except Mixed Coverage (8) are supported.
    ///
    /// If you need a more low-level control, prefer `Face.tables.cmap`.
    pub fn glyph_index(
        self: *const Face,
        code_point: u21,
    ) ?GlyphId {
        const t = self.tables.cmap orelse return null;
        const subtables = t.subtables;

        var iterator = subtables.iterator();
        while (iterator.next()) |subtable|
            if (subtable.is_unicode())
                if (subtable.glyph_index(code_point)) |id|
                    return id;

        return null;
    }

    /// Resolves a Glyph ID for a glyph name.
    ///
    /// Uses the `post` and `CFF` tables as sources.
    ///
    /// Returns `null` when no name is associated with a `glyph`.
    pub fn glyph_index_by_name(
        self: *const Face,
        name: []const u8,
    ) ?GlyphId {
        if (self.tables.post) |post|
            if (post.glyph_index_by_name(name)) |ret|
                return ret;

        if (self.tables.cff) |cff|
            if (cff.glyph_index_by_name(name)) |ret|
                return ret;

        return null;
    }

    /// Resolves a variation of a Glyph ID from two code points.
    ///
    /// Implemented according to
    /// [Unicode Variation Sequences](
    /// https://docs.microsoft.com/en-us/typography/opentype/spec/cmap#format-14-unicode-variation-sequences).
    ///
    /// Returns `null` instead of `0` when glyph is not found.
    pub fn glyph_variation_index(
        self: *const Face,
        code_point: u21,
        variation: u21,
    ) ?GlyphId {
        const t = self.tables.cmap orelse return null;

        var iter = t.subtables.iterator();

        while (iter.next()) |subtable| {
            if (subtable.format != .unicode_variation_sequences) continue;
            const table = subtable.format.unicode_variation_sequences;
            const match = table.glyph_index(code_point, variation) orelse return null;
            switch (match) {
                .found => |x| return x,
                .use_default => return self.glyph_index(code_point),
            }
        }

        return null;
    }

    /// Returns glyph's horizontal advance.
    ///
    /// This method is affected by variation axes.
    ///
    /// [ARS] A working allocator is not strictly needed.
    pub fn glyph_hor_advance(
        self: *const Face,
        gpa: if (cfg.variable_fonts) std.mem.Allocator else void,
        glyph_id: GlyphId,
    ) ?u16 {
        const t = self.tables.hmtx orelse return null;
        const advance_maybe = t.advance(glyph_id);

        if (cfg.variable_fonts) if (self.is_variable()) {
            var advance = advance_maybe orelse return null;

            // Ignore variation offset when `hvar` is not set.
            if (self.tables.variable_fonts.hvar) |hvar| {
                if (hvar.advance_offset(glyph_id, self.coords())) |offset| {
                    // [ARS] bit of a hack re the TDOO in ttf_parser
                    const offset_rounded = utils.f32_to_u16(@round(offset)) orelse
                        return null;
                    advance += offset_rounded;
                }
            } else if (self.glyph_phantom_points(gpa, glyph_id)) |points| {
                // [ARS] bit of a hack re the TDOO in ttf_parser
                const points_rounded = utils.f32_to_u16(@round(points.right.x)) orelse
                    return null;
                advance += points_rounded;
            }

            return advance;
        };

        return advance_maybe;
    }

    /// Returns glyph's vertical advance.
    ///
    /// This method is affected by variation axes.
    ///
    /// [ARS] A working allocator is not strictly needed.
    pub fn glyph_ver_advance(
        self: *const Face,
        gpa: if (cfg.variable_fonts) std.mem.Allocator else void,
        glyph_id: GlyphId,
    ) ?u16 {
        const t = self.tables.vmtx orelse return null;
        var advance = t.advance(glyph_id) orelse return null;

        if (cfg.variable_fonts) if (self.is_variable()) {
            // Ignore variation offset when `vvar` is not set.
            if (self.tables.variable_fonts.vvar) |vvar| {
                if (vvar.advance_offset(glyph_id, self.coords())) |offset| {
                    // [ARS] bit of a hack re the TDOO in ttf_parser
                    const offset_rounded = utils.f32_to_u16(@round(offset)) orelse return null;
                    advance += offset_rounded;
                }
            } else if (self.glyph_phantom_points(gpa, glyph_id)) |points| {
                // [ARS] bit of a hack re the TDOO in ttf_parser
                const points_rounded = utils.f32_to_u16(@round(points.bottom.x)) orelse
                    return null;
                advance += points_rounded;
            }
        };

        return advance;
    }

    /// Returns glyph's horizontal side bearing.
    ///
    /// This method is affected by variation axes.
    pub fn glyph_hor_side_bearing(
        self: *const Face,
        glyph_id: GlyphId,
    ) ?i16 {
        const t = self.tables.hmtx orelse return null;
        var bearing = t.side_bearing(glyph_id) orelse return null;

        if (cfg.variable_fonts) if (self.is_variable()) {
            if (self.tables.variable_fonts.hvar) |hvar| if (hvar
                .left_side_bearing_offset(glyph_id, self.coords())) |offset|
            {
                // [ARS] bit of a hack re the TDOO in ttf_parser
                const offset_rounded = utils.f32_to_i16(@round(offset)) orelse return null;
                bearing += offset_rounded;
            };
        };

        return bearing;
    }

    /// Returns glyph's vertical side bearing.
    ///
    /// This method is affected by variation axes.
    pub fn glyph_ver_side_bearing(
        self: *const Face,
        glyph_id: GlyphId,
    ) ?i16 {
        const t = self.tables.vmtx orelse return null;
        var bearing = t.side_bearing(glyph_id) orelse return null;

        if (cfg.variable_fonts) if (self.is_variable()) {
            if (self.tables.variable_fonts.vvar) |vvar| if (vvar
                .top_side_bearing_offset(glyph_id, self.coords())) |offset|
            {
                // [ARS] bit of a hack re the TDOO in ttf_parser
                const offset_rounded = utils.f32_to_i16(@round(offset)) orelse return null;
                bearing += offset_rounded;
            };
        };

        return bearing;
    }

    /// Returns glyph's vertical origin according to
    /// [Vertical Origin Table](https://docs.microsoft.com/en-us/typography/opentype/spec/vorg).
    ///
    /// This method is affected by variation axes.
    pub fn glyph_y_origin(
        self: *const Face,
        glyph_id: GlyphId,
    ) ?i16 {
        const t = self.tables.vorg orelse return null;
        var origin = t.glyph_y_origin(glyph_id);

        if (cfg.variable_fonts) if (self.is_variable()) {
            if (self.tables.variable_fonts.vvar) |vvar| if (vvar
                .vertical_origin_offset(glyph_id, self.coords())) |offset|
            {
                // [ARS] bit of a hack re the TDOO in ttf_parser
                const offset_rounded = utils.f32_to_i16(@round(offset)) orelse return null;
                origin += offset_rounded;
            };
        };

        return origin;
    }

    /// Returns glyph's name.
    ///
    /// Uses the `post` and `CFF` tables as sources.
    ///
    /// Returns `null` when no name is associated with a `glyph`.
    ///
    /// Return string is either static or owned by the font data.
    pub fn glyph_name(
        self: *const Face,
        glyph_id: GlyphId,
    ) ?[]const u8 {
        if (self.tables.post) |post|
            if (post.glyph_name(glyph_id)) |name|
                return name;

        if (self.tables.cff) |cff|
            if (cff.glyph_name(glyph_id)) |name|
                return name;

        return null;
    }

    /// Outlines a glyph and returns its tight bounding box.
    ///
    /// **Warning**: since `tatfi` is a pull parser,
    /// `OutlineBuilder` will emit segments even when outline is partially malformed.
    /// You must check `outline_glyph()` result before using
    /// `OutlineBuilder`'s output.
    ///
    /// `gvar`, `glyf`, `CFF` and `CFF2` tables are supported.
    /// And they will be accessed in this specific order.
    ///
    /// This method is affected by variation axes.
    ///
    /// Returns `null` when glyph has no outline or on error.
    pub fn outline_glyph(
        self: *const Face,
        gpa: if (cfg.variable_fonts) std.mem.Allocator else void,
        glyph_id: GlyphId,
        builder: OutlineBuilder,
    ) ?Rect {
        if (cfg.variable_fonts)
            if (self.tables.variable_fonts.gvar) |gvar|
                return gvar.outline(
                    gpa,
                    &(self.tables.glyf orelse return null),
                    self.coords(),
                    glyph_id,
                    builder,
                );

        if (self.tables.glyf) |glyf|
            return glyf.outline(glyph_id, builder);

        if (self.tables.cff) |cff|
            return cff.outline(glyph_id, builder) catch null;

        if (cfg.variable_fonts)
            if (self.tables.variable_fonts.cff2) |cff2|
                return cff2.outline(self.coords(), glyph_id, builder) catch null;

        return null;
    }

    /// Returns a tight glyph bounding box.
    ///
    /// This is just a shorthand for `outline_glyph()` since only the `glyf` table stores
    /// a bounding box. We ignore `glyf` table bboxes because they can be malformed.
    /// In case of CFF and variable fonts we have to actually outline
    /// a glyph to find it's bounding box.
    ///
    /// When a glyph is defined by a raster or a vector image,
    /// that can be obtained via `glyph_image()`,
    /// the bounding box must be calculated manually and this method will return `null`.
    ///
    /// Note: the returned bbox is not validated in any way. A font file can have a glyph bbox
    /// set to zero/negative width and/or height and this is perfectly ok.
    /// For calculated bboxes, zero width and/or height is also perfectly fine.
    ///
    /// This method is affected by variation axes.
    pub fn glyph_bounding_box(
        self: *const Face,
        gpa: if (cfg.variable_fonts) std.mem.Allocator else void,
        glyph_id: GlyphId,
    ) ?Rect {
        return self.outline_glyph(gpa, glyph_id, OutlineBuilder.dummy_builder);
    }

    /// Returns a bounding box that large enough to enclose any glyph from the face.
    pub fn global_bounding_box(
        self: *const Face,
    ) Rect {
        return self.tables.head.global_bbox;
    }

    /// Returns a reference to a glyph's raster image.
    ///
    /// A font can define a glyph using a raster or a vector image instead of a simple outline.
    /// Which is primarily used for emojis. This method should be used to access raster images.
    ///
    /// `pixels_per_em` allows selecting a preferred image size. The chosen size will
    /// be closer to an upper one. So when font has 64px and 96px images and `pixels_per_em`
    /// is set to 72, 96px image will be returned.
    /// To get the largest image simply use `maxInt(u16)`.
    ///
    /// Note that this method will return an encoded image. It should be decoded
    /// by the caller. We don't validate or preprocess it in any way.
    ///
    /// Also, a font can contain both: images and outlines. So when this method returns `null`
    /// you should also try `outline_glyph()` afterwards.
    ///
    /// There are multiple ways an image can be stored in a TrueType font
    /// and this method supports most of them.
    /// This includes `sbix`, `bloc` + `bdat`, `EBLC` + `EBDT`, `CBLC` + `CBDT`.
    /// And font's tables will be accesses in this specific order.
    pub fn glyph_raster_image(
        self: *const Face,
        glyph_id: GlyphId,
        pixels_per_em: u16,
    ) ?RasterGlyphImage {
        if (self.tables.sbix) |table|
            if (table.best_strike(pixels_per_em)) |strike|
                return strike.get(glyph_id);

        if (self.tables.bdat) |table|
            return table.get(glyph_id, pixels_per_em);

        if (self.tables.ebdt) |table|
            return table.get(glyph_id, pixels_per_em);

        if (self.tables.cbdt) |table|
            return table.get(glyph_id, pixels_per_em);

        return null;
    }

    /// Returns a reference to a glyph's SVG image.
    ///
    /// A font can define a glyph using a raster or a vector image instead of a simple outline.
    /// Which is primarily used for emojis. This method should be used to access SVG images.
    ///
    /// Note that this method will return just an SVG data. It should be rendered
    /// or even decompressed (in case of SVGZ) by the caller.
    /// We don't validate or preprocess it in any way.
    ///
    /// Also, a font can contain both: images and outlines. So when this method returns `null`
    /// you should also try `outline_glyph()` afterwards.
    pub fn glyph_svg_image(
        self: *const Face,
        glyph_id: GlyphId,
    ) ?tables.svg.SvgDocument {
        const t = self.tables.svg orelse return null;
        return t.documents.find(glyph_id);
    }

    // Returns `true` if the glyph can be colored/painted using the `COLR`+`CPAL` tables.
    ///
    /// See `paint_color_glyph` for details.
    pub fn is_color_glyph(
        self: *const Face,
        glyph_id: GlyphId,
    ) bool {
        const t = self.tables.colr orelse return false;
        return t.contains(glyph_id);
    }

    /// Returns the number of palettes stored in the `COLR`+`CPAL` tables.
    ///
    /// See `paint_color_glyph` for details.
    pub fn color_palettes(
        self: *const Face,
    ) ?u16 {
        const t = self.tables.colr orelse return null;
        return t.palettes.palettes();
    }

    /// Paints a color glyph from the `COLR` table.
    ///
    /// A font can have multiple palettes, which you can check via `color_palettes`.
    /// If unsure, just pass 0 to the `palette` argument, which is the default.
    ///
    /// A font can define a glyph using layers of colored shapes instead of a
    /// simple outline. Which is primarily used for emojis. This method should
    /// be used to access glyphs defined in the `COLR` table.
    ///
    /// Also, a font can contain both: a layered definition and outlines. So
    /// when this method returns `null` you should also try `outline_glyph` afterwards.
    ///
    /// Returns an error if the glyph has no `COLR` definition or if the glyph
    /// definition is malformed.
    ///
    /// See `examples/font2svg.rs` for usage examples.
    pub fn paint_color_glyph(
        self: *const Face,
        glyph_id: GlyphId,
        palette: u16,
        foreground_color: RgbaColor,
        painter: tables.colr.Painter,
    ) tables.colr.Error!void {
        const t = self.tables.colr orelse return error.PaintError;

        try t.paint(
            glyph_id,
            palette,
            painter,
            self.coords(),
            foreground_color,
        );
    }

    /// Returns an iterator over variation axes.
    pub fn variation_axes(
        self: *const Face,
    ) parser.LazyArray16(tables.fvar.VariationAxis) {
        if (!cfg.variable_fonts) @compileError("variation_axes needs variable_fonts enabled");

        const t = self.tables.variable_fonts.fvar orelse return .{};
        return t.axes;
    }

    /// Sets a variation axis coordinate.
    ///
    /// This is one of the only two mutable methods in the library.
    /// We can simplify the API a lot by storing the variable coordinates
    /// in the face object itself.
    ///
    /// Since coordinates are stored on the stack, we allow only 64 of them.
    ///
    /// Returns an error when face is not variable or doesn't have such axis, retuns true otherwise.
    pub fn set_variation(
        self: *Face,
        axis: Tag,
        value: f32,
    ) !void {
        if (!cfg.variable_fonts) @compileError("set_variation needs variable_fonts enabled");

        if (!self.is_variable()) return error.FontNotVariable;
        if ((self.variation_axes().len()) > MAX_VAR_COORDS) return error.FontTooVariable;

        var failure = true;
        var iter = self.variation_axes().iterator();
        var i: usize = 0;
        while (iter.next()) |var_axis| : (i += 1) {
            if (var_axis.tag.inner != axis.inner) continue;
            failure = false;
            self.coordinates.data[i] = var_axis.normalized_value(value);

            if (self.tables.variable_fonts.avar) |avar|
                avar.map_coordinate(self.coordinates.data[0..self.coordinates.len], i) catch {};
        }
        if (failure) return error.NoAxis;
    }

    /// Returns the current normalized variation coordinates.
    pub fn variation_coordinates(
        self: *const Face,
    ) []const NormalizedCoordinate {
        if (!cfg.variable_fonts) @compileError("variation_coordinates needs variable_fonts enabled");

        return self.coordinates.data[0..self.coordinates.len];
    }

    /// Checks that face has non-default variation coordinates.
    pub fn has_non_default_variation_coordinates(
        self: *const Face,
    ) bool {
        if (!cfg.variable_fonts) @compileError("has_non_default_variation_coordinates needs variable_fonts enabled");

        for (self.coordinates.data[0..self.coordinates.len]) |c| {
            if (c.inner != 0) return true;
        } else return false;
    }

    /// Parses glyph's phantom points.
    ///
    /// Available only for variable fonts with the `gvar` table.
    ///
    /// [ARS] A working allocator is not strictly needed.
    pub fn glyph_phantom_points(
        self: *const Face,
        gpa: if (cfg.variable_fonts) std.mem.Allocator else void,
        glyph_id: GlyphId,
    ) ?PhantomPoints {
        if (!cfg.variable_fonts) @compileError("glyph_phantom_points needs variable_fonts enabled");

        const glyf = self.tables.glyf orelse return null;
        const gvar = self.tables.variable_fonts.gvar orelse return null;
        return gvar.phantom_points(gpa, glyf, self.coords(), glyph_id);
    }

    fn apply_metrics_variation(
        self: *const Face,
        tag: Tag,
        value_immutable: i16,
    ) i16 {
        var value = value_immutable;
        if (cfg.variable_fonts) if (self.is_variable()) {
            const metrics: f32 = m: {
                const mvar = self.tables.variable_fonts.mvar orelse break :m 0.0;
                break :m mvar.metric_offset(tag, self.coords()) orelse 0.0;
            };
            const v: f32 = @as(f32, @floatFromInt(value)) + metrics;
            // TODO: Should probably round it, but f32::round is not available in core.
            value = utils.f32_to_i16(v) orelse value;
        };

        return value;
    }

    fn coords(
        self: *const Face,
    ) []const NormalizedCoordinate {
        return self.coordinates.data[0..self.coordinates.len];
    }
};

/// Returns the number of fonts stored in a TrueType font collection.
///
/// Returns `null` if a provided data is not a TrueType font collection.
pub fn fonts_in_collection(
    data: []const u8,
) ?u32 {
    var s = parser.Stream.new(data);
    const magic = s.read(Magic) catch return null;
    if (magic != .font_collection) return null;

    s.skip(u32); // version
    return s.read(u32) catch null;
}

/// A raw font face.
///
/// You are probably looking for `Face`. This is a low-level type.
///
/// Unlike `Face`, `RawFace` parses only face table records.
/// Meaning all you can get from this type is a raw (`[]const u8`) data of a requested table.
/// Then you can either parse just a singe table from a font/face or populate `RawFaceTables`
/// manually before passing it to `Face.from_raw_tables`.
pub const RawFace = struct {
    /// The input font file data.
    data: []const u8,
    /// An array of table records.
    table_records: parser.LazyArray16(TableRecord),

    const Self = @This();

    /// Creates a new `RawFace` from a raw data.
    ///
    /// `index` indicates the specific font face in a font collection.
    /// Use `fonts_in_collection` to get the total number of font faces.
    /// Set to 0 if unsure.
    ///
    /// While we do reuse `FaceParsingError`, `No*Table` errors will not be throws.
    pub fn parse(
        data: []const u8,
        index: u32,
    ) FaceParsingError!Self {
        var s = parser.Stream.new(data);
        const magic = s.read(Magic) catch return error.UnknownMagic;
        switch (magic) {
            .font_collection => {
                s.skip(u32); // version
                const number_of_faces = s.read(u32) catch
                    return error.MalformedFont;

                const offsets = s.read_array(parser.Offset32, number_of_faces) catch
                    return error.MalformedFont;

                const face_offset = offsets.get(index) orelse
                    return error.FaceIndexOutOfBounds;

                // Face offset is from the start of the font data,
                // so we have to adjust it to the current parser offset.
                const offset = std.math.sub(usize, face_offset[0], s.offset) catch
                    return error.MalformedFont;

                s.advance_checked(offset) catch return error.MalformedFont;

                // Read **face** magic.
                // Each face in a font collection also starts with a magic.
                const face_magic = s.read(Magic) catch return error.UnknownMagic;
                // And face in a font collection can't be another collection.
                if (face_magic == .font_collection) return error.UnknownMagic;
            },
            // When reading from a regular font (not a collection) disallow index to be non-zero
            // Basically treat the font as a one-element collection
            else => if (index != 0) return error.FaceIndexOutOfBounds,
        }

        const num_tables = s.read(u16) catch return error.MalformedFont;
        s.advance(6); // searchRange (u16) + entrySelector (u16) + rangeShift (u16)

        const table_records = s.read_array(TableRecord, num_tables) catch
            return error.MalformedFont;

        return .{
            .data = data,
            .table_records = table_records,
        };
    }

    /// Returns the raw data of a selected table.
    pub fn table(
        self: Self,
        tag: Tag,
    ) ?[]const u8 {
        const func = struct {
            fn func(record: TableRecord, t: Tag) std.math.Order {
                const lhs = record.tag.inner;
                const rhs = t.inner;

                return std.math.order(lhs, rhs);
            }
        }.func;

        _, const table_v = self.table_records.binary_search_by(tag, func) catch return null;
        return utils.slice(self.data, .{ table_v.offset, table_v.length }) catch null;
    }
};

/// Parsed face tables.
///
/// Unlike `Face`, provides a low-level parsing abstraction over TrueType tables.
/// Useful when you need a direct access to tables data.
///
/// Also, used when high-level API is problematic to implement.
/// A good example would be OpenType layout tables (GPOS/GSUB).
pub const FaceTables = struct {
    // Mandatory tables.
    head: tables.head,
    hhea: tables.hhea,
    maxp: tables.maxp,

    bdat: ?tables.cbdt = null,
    cbdt: ?tables.cbdt = null,
    cff: ?tables.cff1 = null,
    cmap: ?tables.cmap = null,
    colr: ?tables.colr = null,
    ebdt: ?tables.cbdt = null,
    glyf: ?tables.glyf = null,
    hmtx: ?tables.hmtx = null,
    kern: ?tables.kern = null,
    name: ?tables.name = null,
    os2: ?tables.os2 = null,
    post: ?tables.post = null,
    sbix: ?tables.sbix = null,
    stat: ?tables.stat = null,
    svg: ?tables.svg = null,
    vhea: ?tables.vhea = null,
    vmtx: ?tables.hmtx = null, // [ARS] not a typo
    vorg: ?tables.vorg = null,

    opentype_layout: if (cfg.opentype_layout) struct {
        gdef: ?tables.gdef = null,
        gpos: ?opentype_layout.LayoutTable(.gpos) = null,
        gsub: ?opentype_layout.LayoutTable(.gsub) = null,
        math: ?tables.math = null,
    } else void,

    apple_layout: if (cfg.apple_layout) struct {
        ankr: ?tables.ankr = null,
        feat: ?tables.feat = null,
        kerx: ?tables.kerx = null,
        morx: ?tables.morx = null,
        trak: ?tables.trak = null,
    } else void,

    variable_fonts: if (cfg.variable_fonts) struct {
        avar: ?tables.avar = null,
        cff2: ?tables.cff2 = null,
        fvar: ?tables.fvar = null,
        gvar: ?tables.gvar = null,
        hvar: ?tables.hvar = null,
        mvar: ?tables.mvar = null,
        vvar: ?tables.vvar = null,
    } else void,
};

/// A list of all supported tables as raw data.
///
/// This type should be used in tandem with `Face.from_raw_tables()`.
///
/// This allows loading font faces not only from TrueType font files,
/// but from any source. Mainly used for parsing WOFF.
pub const RawFaceTables = struct {
    // Mandatory tables.
    /// Font Header, global information about the font, version number, creation and modification dates, revision number, and basic typographic data.
    head: []const u8 = &.{},
    /// Horizontal Header, information needed to layout fonts whose characters are written horizontally.
    hhea: []const u8 = &.{},
    /// Maximum Profile, establishes the memory requirements for a font.
    maxp: []const u8 = &.{},

    /// Bitmap data table
    bdat: ?[]const u8 = null,
    /// Bitmap Location, availability of bitmaps at requested point sizes.
    bloc: ?[]const u8 = null,
    /// Color Bitmap Data, used to embed color bitmap glyph data.
    cbdt: ?[]const u8 = null,
    /// Color Bitmap Location, provides locators for embedded color bitmaps.
    cblc: ?[]const u8 = null,
    /// Compact Font Format 1
    cff: ?[]const u8 = null,
    /// Character to Glyph Mapping, maps character codes to glyph indices.
    cmap: ?[]const u8 = null,
    /// Color, adds support for multi-colored glyphs.
    colr: ?[]const u8 = null,
    /// Color Palette, a set of one or more color palettes.
    cpal: ?[]const u8 = null,
    /// Embedded Bitmap Data, embed monochrome or grayscale bitmap glyph data.
    ebdt: ?[]const u8 = null,
    /// Embedded Bitmap Location, provides embedded bitmap locators.
    eblc: ?[]const u8 = null,
    /// Glyph Outline, data that defines the appearance of the glyphs.
    glyf: ?[]const u8 = null,
    /// Horizontal Metrics, metric information for the horizontal layout each of the glyphs.
    hmtx: ?[]const u8 = null,
    /// Kern, values that adjust the intercharacter spacing for glyphs.
    kern: ?[]const u8 = null,
    /// Glyph Data Location, stores the offsets to the locations of the glyphs.
    loca: ?[]const u8 = null,
    /// Font Names, human-readable names for features and settings, copyright, font names, style names, and other information.
    name: ?[]const u8 = null,
    /// OS/2 Compatibility, a set of metrics that are required by Windows.
    os2: ?[]const u8 = null,
    /// Glyph Name and PostScript Font, information needed to use a TrueType font on a PostScript printer.
    post: ?[]const u8 = null,
    /// Extended Bitmaps, provides access to bitmap data in a standard graphics format (such as PNG, JPEG, TIFF).
    sbix: ?[]const u8 = null,
    /// Style Attributes, describes design attributes that distinguish font-style variants within a font family.
    stat: ?[]const u8 = null,
    /// Scalable Vector Graphics, contains SVG descriptions for some or all of the glyphs in the font.
    svg: ?[]const u8 = null,
    /// Vertical Header, information needed for vertical fonts.
    vhea: ?[]const u8 = null,
    /// Vertical Metrics, specifies the vertical spacing for each glyph in an AAT vertical font.
    vmtx: ?[]const u8 = null,
    /// Vertical Origin, the y coordinate of a glyph’s vertical origin, this can only be used in CFF or CFF2 fonts.
    vorg: ?[]const u8 = null,

    opentype_layout: if (cfg.opentype_layout) struct {
        /// Glyph Definition, provides various glyph properties used in OpenType Layout processing.
        gdef: ?[]const u8 = null,
        /// Glyph Positioning, precise control over glyph placement for sophisticated text layout in each supported script.
        gpos: ?[]const u8 = null,
        /// Glyph Substitution, provides data for substitution of glyphs for appropriate rendering of different scripts.
        gsub: ?[]const u8 = null,
        /// Mathematical Typesetting, font-specific information necessary for math formula layout.
        math: ?[]const u8 = null,
    } else void = if (cfg.opentype_layout) .{},

    apple_layout: if (cfg.apple_layout) struct {
        /// Anchor Point Table, defines anchor points.
        ankr: ?[]const u8 = null,
        /// Feature Name Table, font's text features.
        feat: ?[]const u8 = null,
        /// Kerx, extended kerning table.
        kerx: ?[]const u8 = null,
        /// Extended Glyph Metamorphosis, specifies a set of transformations that can apply to the glyphs of your font.
        morx: ?[]const u8 = null,
        /// Tracking, allows AAT fonts to adjust to normal interglyph spacing.
        trak: ?[]const u8 = null,
    } else void = if (cfg.apple_layout) .{},

    variable_fonts: if (cfg.variable_fonts) struct {
        /// Axis Variation Table, allows the font to modify the mapping between axis values and these normalized values.
        avar: ?[]const u8 = null,
        /// Compact Font Format 2
        cff2: ?[]const u8 = null,
        /// Font Variations Table, global information of which variation axes are included in the font.
        fvar: ?[]const u8 = null,
        /// Glyph Variations Table, includes all of the data required for stylizing the glyphs.
        gvar: ?[]const u8 = null,
        /// Horizontal Metrics Variations Table, used in variable fonts to provide glyph variations for horizontal glyph metrics values.
        hvar: ?[]const u8 = null,
        /// Metrics Variations Table, used in variable fonts to provide glyph variations for font-wide metric values found in other font tables.
        mvar: ?[]const u8 = null,
        /// Vertical Metrics Variations Table, used in variable fonts to provide glyph variations for vertical glyph metric values.
        vvar: ?[]const u8 = null,
    } else void = if (cfg.variable_fonts) .{},
};

/// A raw table record.
pub const TableRecord = struct {
    tag: Tag,
    check_sum: u32,
    offset: u32,
    length: u32,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 16;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            return try parser.parse_struct_from_data(Self, data);
        }
    };
};

/// A 4-byte tag.
pub const Tag = struct {
    inner: u32,

    /// Creates a `Tag` from bytes.
    pub fn from_bytes(bytes: *const [4]u8) Tag {
        return .{ .inner = std.mem.readInt(u32, bytes, .big) };
    }

    /// Returns tag as 4-element byte array.
    pub fn to_bytes(self: Tag) [4]u8 {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, self.inner, .big);
        return b;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const bytes = self.to_bytes();
        try writer.print("Tag{{ \"{s}\" }}", .{&bytes});
    }

    /// Creates a `Tag` from bytes.
    ///
    /// In case of empty data will return `Tag` set to 0.
    ///
    /// When `bytes` are shorter than 4, will set missing bytes to ` `.
    ///
    /// Data after first 4 bytes is ignored.
    pub fn from_bytes_lossy(bytes: []const u8) Tag {
        switch (bytes.len) {
            0 => return .{ .inner = 0 },
            1...3 => {
                var temp: [4]u8 = @splat(' ');
                @memcpy(temp[0..bytes.len], bytes[0..bytes.len]);
                return .from_bytes(&temp);
            },
            else => return .from_bytes(bytes[0..4]),
        }
    }

    test "tag from bytes lossy" {
        const t = std.testing;

        try t.expectEqual(Tag{ .inner = 0 }, Tag.from_bytes_lossy(&.{}));
        try t.expectEqual(Tag.from_bytes("b   "), Tag.from_bytes_lossy("b"));
        try t.expectEqual(Tag.from_bytes("hell"), Tag.from_bytes_lossy("hello"));
    }
};

/// A list of font face parsing errors.
pub const FaceParsingError = error{
    /// An attempt to read out of bounds detected.
    ///
    /// Should occur only on malformed fonts.
    MalformedFont,

    /// Face data must start with `0x00010000`, `0x74727565`, `0x4F54544F` or `0x74746366`.
    UnknownMagic,

    /// The face index is larger than the number of faces in the font.
    FaceIndexOutOfBounds,

    /// The `head` table is missing or malformed.
    NoHeadTable,

    /// The `hhea` table is missing or malformed.
    NoHheaTable,

    /// The `maxp` table is missing or malformed.
    NoMaxpTable,
};

/// A rectangle.
///
/// Doesn't guarantee that `x_min` <= `x_max` and/or `y_min` <= `y_max`.
pub const Rect = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,

    pub const zero: Rect = .{
        .x_min = 0,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
    };

    /// Returns rect's width.
    pub fn width(
        self: Rect,
    ) i16 {
        return self.x_max - self.x_min;
    }

    /// Returns rect's height.
    pub fn height(
        self: Rect,
    ) i16 {
        return self.y_max - self.y_min;
    }
};

/// A rectangle described by the left-lower and upper-right points.
pub const RectF = struct {
    /// The horizontal minimum of the rect.
    x_min: f32 = std.math.floatMax(f32),
    /// The vertical minimum of the rect.
    y_min: f32 = std.math.floatMax(f32),
    /// The horizontal maximum of the rect.
    x_max: f32 = std.math.floatMin(f32),
    /// The vertical maximum of the rect.
    y_max: f32 = std.math.floatMin(f32),

    pub fn is_default(
        self: RectF,
    ) bool {
        return std.meta.eql(self, .{});
    }

    pub fn to_rect(
        self: RectF,
    ) ?Rect {
        return .{
            .x_min = utils.f32_to_i16(self.x_min) orelse return null,
            .y_min = utils.f32_to_i16(self.y_min) orelse return null,
            .x_max = utils.f32_to_i16(self.x_max) orelse return null,
            .y_max = utils.f32_to_i16(self.y_max) orelse return null,
        };
    }

    pub fn extend_by(
        self: *RectF,
        x: f32,
        y: f32,
    ) void {
        self.x_min = @min(self.x_min, x);
        self.y_min = @min(self.y_min, y);
        self.x_max = @max(self.x_max, x);
        self.y_max = @max(self.y_max, y);
    }
};

/// A line metrics.
///
/// Used for underline and strikeout.
pub const LineMetrics = struct {
    /// Line position.
    position: i16,
    /// Line thickness.
    thickness: i16,
};

/// A TrueType font magic.
///
/// https://docs.microsoft.com/en-us/typography/opentype/spec/otff#organization-of-an-opentype-font
pub const Magic = enum {
    true_type,
    open_type,
    font_collection,

    const Self = @This();
    pub const FromData = struct {
        // [ARS] impl of FromData trait
        pub const SIZE: usize = 4;

        pub fn parse(
            data: *const [SIZE]u8,
        ) parser.Error!Self {
            const u = std.mem.readInt(u32, data, .big);
            switch (u) {
                0x00010000, 0x74727565 => return .true_type,
                0x4F54544F => return .open_type,
                0x74746366 => return .font_collection,
                else => return error.ParseFail,
            }
        }
    };
};

// VARIABLE FONTS
// [ARS] These should get compiled out if variable_fonts option is false
const MAX_VAR_COORDS: u7 = 64;
const VarCoords = struct {
    data: [MAX_VAR_COORDS]NormalizedCoordinate = @splat(.{ .inner = 0 }),
    len: u8 = 0,
};

/// A variation coordinate in a normalized coordinate system.
///
/// Basically any number in a -1.0..1.0 range.
/// Where 0 is a default value.
///
/// The number is stored as f2.16
pub const NormalizedCoordinate = struct {
    inner: i16,

    pub fn from(n: anytype) NormalizedCoordinate {
        const T = @TypeOf(n);
        if (T == i16) {
            const v = std.math.clamp(n, -(1 << 14), 1 << 14);
            return .{ .inner = v };
        } else if (T == f32) {
            const v = std.math.clamp(n, -1.0, 1.0);
            return .{ .inner = @intFromFloat(v * (1 << 14)) };
        } else @compileError("can make NormalizedCoordinates only from i16 and f32");
    }
};

/// Phantom points.
///
/// Available only for variable fonts with the `gvar` table.
pub const PhantomPoints = struct {
    /// Left side bearing point.
    left: PointF,
    /// Right side bearing point.
    right: PointF,
    /// Top side bearing point.
    top: PointF,
    /// Bottom side bearing point.
    bottom: PointF,

    /// A float point.
    pub const PointF = struct {
        /// The X-axis coordinate.
        x: f32,
        /// The Y-axis coordinate.
        y: f32,
    };
};

/// An affine transform.
pub const Transform = struct {
    /// The 'a' component of the transform.
    a: f32 = 1.0,
    /// The 'b' component of the transform.
    b: f32 = 0.0,
    /// The 'c' component of the transform.
    c: f32 = 0.0,
    /// The 'd' component of the transform.
    d: f32 = 1.0,
    /// The 'e' component of the transform.
    e: f32 = 0.0,
    /// The 'f' component of the transform.
    f: f32 = 0.0,

    /// Checks whether a transform is the identity transform.
    pub fn is_default(
        self: Transform,
    ) bool {
        return std.meta.eql(self, .{});
    }

    /// Combines two transforms with each other.
    pub fn combine(
        ts1: Transform,
        ts2: Transform,
    ) Transform {
        return .{
            .a = ts1.a * ts2.a + ts1.c * ts2.b,
            .b = ts1.b * ts2.a + ts1.d * ts2.b,
            .c = ts1.a * ts2.c + ts1.c * ts2.d,
            .d = ts1.b * ts2.c + ts1.d * ts2.d,
            .e = ts1.a * ts2.e + ts1.c * ts2.f + ts1.e,
            .f = ts1.b * ts2.e + ts1.d * ts2.f + ts1.f,
        };
    }

    /// Creates a new translation transform.
    pub fn new_translate(
        tx: f32,
        ty: f32,
    ) Transform {
        return .{ .e = tx, .f = ty };
    }

    /// Creates a new scale transform.
    pub fn new_scale(
        sx: f32,
        sy: f32,
    ) Transform {
        return .{ .a = sx, .d = sy };
    }

    /// Creates a new rotation transform.
    pub fn new_rotate(
        angle: f32,
    ) Transform {
        const cc = @cos(angle * std.math.pi);
        const ss = @sin(angle * std.math.pi);

        return .{ .a = cc, .b = ss, .c = -ss, .d = cc };
    }

    /// Creates a new skew transform.
    pub fn new_skew(
        skew_x: f32,
        skew_y: f32,
    ) Transform {
        const x = @tan(skew_x * std.math.pi);
        const y = @tan(skew_y * std.math.pi);

        return .{ .b = y, .c = -x };
    }

    pub fn apply_to(
        self: Transform,
        x: *f32,
        y: *f32,
    ) void {
        const tx = x.*;
        const ty = y.*;
        x.* = self.a * tx + self.c * ty + self.e;
        y.* = self.b * tx + self.d * ty + self.f;
    }
};

/// An interface for glyph outline construction.
pub const OutlineBuilder = struct {
    ptr: *anyopaque,
    vtable: VTable,

    pub const VTable = struct {
        /// Appends a MoveTo segment.
        ///
        /// Start of a contour.
        move_to: *const fn (*anyopaque, x: f32, y: f32) void,

        /// Appends a LineTo segment.
        line_to: *const fn (*anyopaque, x: f32, y: f32) void,

        /// Appends a QuadTo segment.
        quad_to: *const fn (*anyopaque, x1: f32, y1: f32, x: f32, y: f32) void,

        /// Appends a CurveTo segment.
        curve_to: *const fn (*anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void,

        /// Appends a ClosePath segment.
        ///
        /// End of a contour.
        close: *const fn (*anyopaque) void,
    };

    pub fn move_to(self: OutlineBuilder, x: f32, y: f32) void {
        self.vtable.move_to(self.ptr, x, y);
    }
    pub fn line_to(self: OutlineBuilder, x: f32, y: f32) void {
        self.vtable.line_to(self.ptr, x, y);
    }
    pub fn quad_to(self: OutlineBuilder, x1: f32, y1: f32, x: f32, y: f32) void {
        self.vtable.quad_to(self.ptr, x1, y1, x, y);
    }
    pub fn curve_to(self: OutlineBuilder, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
        self.vtable.curve_to(self.ptr, x1, y1, x2, y2, x, y);
    }
    pub fn close(self: OutlineBuilder) void {
        self.vtable.close(self.ptr);
    }

    pub const dummy_builder: OutlineBuilder = .{
        .ptr = undefined,
        .vtable = .{
            .move_to = dummy_move,
            .line_to = dummy_move,
            .quad_to = dummy_quad,
            .curve_to = dummy_curve,
            .close = dummy_close,
        },
    };

    fn dummy_move(_: *anyopaque, _: f32, _: f32) void {}
    fn dummy_quad(_: *anyopaque, _: f32, _: f32, _: f32, _: f32) void {}
    fn dummy_curve(_: *anyopaque, _: f32, _: f32, _: f32, _: f32, _: f32, _: f32) void {}
    fn dummy_close(_: *anyopaque) void {}
};

/// A glyph's raster image.
///
/// Note, that glyph metrics are in pixels and not in font units.
pub const RasterGlyphImage = struct {
    /// Horizontal offset.
    x: i16,
    /// Vertical offset.
    y: i16,
    /// Image width.
    ///
    /// It doesn't guarantee that this value is the same as set in the `data`.
    width: u16,
    /// Image height.
    ///
    /// It doesn't guarantee that this value is the same as set in the `data`.
    height: u16,
    /// A pixels per em of the selected strike.
    pixels_per_em: u16,
    /// An image format.
    format: Format,
    /// A raw image data. It's up to the caller to decode it.
    data: []const u8,

    /// A glyph raster image format.
    pub const Format = enum {
        png,

        /// A monochrome bitmap.
        ///
        /// The most significant bit of the first byte corresponds to the top-left pixel, proceeding
        /// through succeeding bits moving left to right. The data for each row is padded to a byte
        /// boundary, so the next row begins with the most significant bit of a new byte. 1 corresponds
        /// to black, and 0 to white.
        bitmap_mono,

        /// A packed monochrome bitmap.
        ///
        /// The most significant bit of the first byte corresponds to the top-left pixel, proceeding
        /// through succeeding bits moving left to right. Data is tightly packed with no padding. 1
        /// corresponds to black, and 0 to white.
        bitmap_mono_packed,

        /// A grayscale bitmap with 2 bits per pixel.
        ///
        /// The most significant bits of the first byte corresponds to the top-left pixel, proceeding
        /// through succeeding bits moving left to right. The data for each row is padded to a byte
        /// boundary, so the next row begins with the most significant bit of a new byte.
        bitmap_gray_2,

        /// A packed grayscale bitmap with 2 bits per pixel.
        ///
        /// The most significant bits of the first byte corresponds to the top-left pixel, proceeding
        /// through succeeding bits moving left to right. Data is tightly packed with no padding.
        bitmap_gray_2_packed,

        /// A grayscale bitmap with 4 bits per pixel.
        ///
        /// The most significant bits of the first byte corresponds to the top-left pixel, proceeding
        /// through succeeding bits moving left to right. The data for each row is padded to a byte
        /// boundary, so the next row begins with the most significant bit of a new byte.
        bitmap_gray_4,

        /// A packed grayscale bitmap with 4 bits per pixel.
        ///
        /// The most significant bits of the first byte corresponds to the top-left pixel, proceeding
        /// through succeeding bits moving left to right. Data is tightly packed with no padding.
        bitmap_gray_4_packed,

        /// A grayscale bitmap with 8 bits per pixel.
        ///
        /// The first byte corresponds to the top-left pixel, proceeding through succeeding bytes
        /// moving left to right.
        bitmap_gray_8,

        /// A color bitmap with 32 bits per pixel.
        ///
        /// The first group of four bytes corresponds to the top-left pixel, proceeding through
        /// succeeding pixels moving left to right. Each byte corresponds to a color channel and the
        /// channels within a pixel are in blue, green, red, alpha order. Color values are
        /// pre-multiplied by the alpha. For example, the color "full-green with half translucency"
        /// is encoded as `\x00\x80\x00\x80`, and not `\x00\xFF\x00\x80`.
        bitmap_premul_bgra_32,
    };
};

/// A RGBA color in the sRGB color space.
pub const RgbaColor = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,

    pub fn new(
        red: u8,
        green: u8,
        blue: u8,
        alpha: u8,
    ) RgbaColor {
        return .{
            .red = red,
            .green = green,
            .blue = blue,
            .alpha = alpha,
        };
    }

    /// internal use only
    pub fn apply_alpha(
        self: RgbaColor,
        alpha: f32,
    ) RgbaColor {
        var ret = self;
        const _1 = @as(f32, @floatFromInt(self.alpha));
        const _2 = _1 / 255;
        const _3 = _2 * alpha;
        const _4 = _3 * 255.0;
        ret.alpha = std.math.lossyCast(u8, _4);

        return ret;
    }
};

test {
    _ = @import("tests/main.zig");
    _ = std.testing.refAllDecls(@This());
}
