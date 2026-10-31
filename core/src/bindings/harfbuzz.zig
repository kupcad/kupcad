//! Bindings to HarfBuzz (vendor/harfbuzz), which shapes a run of text in a font: which glyphs
//! it takes and where each goes, with the font's kerning, ligatures, joining forms and marks.
//! `text` (core/text.zig) shapes with it; build.zig compiles it lean (`harfbuzz_flags`).

pub const Blob = opaque {};
pub const Face = opaque {};
pub const Font = opaque {};
pub const Buffer = opaque {};

pub const MemoryMode = enum(c_uint) { duplicate, readonly, writable, readonly_may_make_writable };
pub const Direction = enum(c_uint) { invalid = 0, ltr = 4, rtl = 5, ttb = 6, btt = 7 };

/// A shaped glyph: `codepoint` is its glyph id, `cluster` the byte its character starts at.
pub const GlyphInfo = extern struct {
    codepoint: u32,
    mask: u32,
    cluster: u32,
    private: [2]u32,
};

/// Where a shaped glyph goes, in font units: its offset from the pen, and how far the pen moves.
pub const GlyphPosition = extern struct {
    x_advance: i32,
    y_advance: i32,
    x_offset: i32,
    y_offset: i32,
    private: u32,
};

pub extern fn hb_blob_create(data: [*]const u8, length: c_uint, mode: MemoryMode, user_data: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void) *Blob;
pub extern fn hb_blob_destroy(blob: *Blob) void;
pub extern fn hb_face_create(blob: *Blob, index: c_uint) *Face;
pub extern fn hb_face_destroy(face: *Face) void;
pub extern fn hb_font_create(face: *Face) *Font;
pub extern fn hb_font_destroy(font: *Font) void;
pub extern fn hb_buffer_create() *Buffer;
pub extern fn hb_buffer_destroy(buffer: *Buffer) void;
pub extern fn hb_buffer_add_utf8(buffer: *Buffer, text: [*]const u8, text_length: c_int, item_offset: c_uint, item_length: c_int) void;
pub extern fn hb_buffer_set_direction(buffer: *Buffer, direction: Direction) void;
pub extern fn hb_buffer_guess_segment_properties(buffer: *Buffer) void;
pub extern fn hb_buffer_allocation_successful(buffer: *Buffer) c_int;
pub extern fn hb_buffer_get_glyph_infos(buffer: *Buffer, length: *c_uint) [*]GlyphInfo;
pub extern fn hb_buffer_get_glyph_positions(buffer: *Buffer, length: *c_uint) [*]GlyphPosition;
pub extern fn hb_shape(font: *Font, buffer: *Buffer, features: ?*const anyopaque, num_features: c_uint) void;
