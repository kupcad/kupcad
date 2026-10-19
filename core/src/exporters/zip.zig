//! A zip archive of stored (uncompressed) files: what a 3MF package is (threemf.zig). The
//! files are written as given, each with its CRC-32, then the central directory. Names are
//! UTF-8 (general purpose bit 11), times the format's earliest (1980-01-01), so the same
//! files make the same bytes. Sizes and offsets are 32-bit: an archive past 4 GiB, which
//! needs zip64, is refused.

const std = @import("std");

const LOCAL_HEADER_SIG: u32 = 0x04034b50;
const CENTRAL_HEADER_SIG: u32 = 0x02014b50;
const END_RECORD_SIG: u32 = 0x06054b50;
/// 2.0, the version that reads stored files and folders.
const VERSION: u16 = 20;
/// General purpose bit 11: the names are UTF-8.
const UTF8_NAMES: u16 = 1 << 11;
const STORED: u16 = 0;
/// MS-DOS date 1980-01-01 (time 00:00), the earliest a zip records.
const DOS_DATE: u16 = (0 << 9) | (1 << 5) | 1;
const DOS_TIME: u16 = 0;

pub const File = struct {
    name: []const u8,
    data: []const u8,
};

/// `files` as a zip archive (owned by `allocator`); error.ArchiveTooLarge past what 32-bit
/// sizes and offsets hold.
pub fn write(allocator: std.mem.Allocator, files: []const File) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const offsets = try allocator.alloc(u32, files.len);
    defer allocator.free(offsets);
    const crcs = try allocator.alloc(u32, files.len);
    defer allocator.free(crcs);

    for (files, offsets, crcs) |file, *offset, *crc| {
        offset.* = try fit32(w.end);
        crc.* = std.hash.Crc32.hash(file.data);
        try w.writeInt(u32, LOCAL_HEADER_SIG, .little);
        try writeCommon(w, file, crc.*);
        try w.writeInt(u16, 0, .little); // extra field length
        try w.writeAll(file.name);
        try w.writeAll(file.data);
    }

    const directory_start = try fit32(w.end);
    for (files, offsets, crcs) |file, offset, crc| {
        try w.writeInt(u32, CENTRAL_HEADER_SIG, .little);
        try w.writeInt(u16, VERSION, .little); // made by
        try writeCommon(w, file, crc);
        try w.writeInt(u16, 0, .little); // extra field length
        try w.writeInt(u16, 0, .little); // comment length
        try w.writeInt(u16, 0, .little); // disk number
        try w.writeInt(u16, 0, .little); // internal attributes
        try w.writeInt(u32, 0, .little); // external attributes
        try w.writeInt(u32, offset, .little);
        try w.writeAll(file.name);
    }
    const directory_size = try fit32(w.end - directory_start);

    const count = std.math.cast(u16, files.len) orelse return error.ArchiveTooLarge;
    try w.writeInt(u32, END_RECORD_SIG, .little);
    try w.writeInt(u16, 0, .little); // this disk
    try w.writeInt(u16, 0, .little); // the directory's disk
    try w.writeInt(u16, count, .little); // entries on this disk
    try w.writeInt(u16, count, .little); // entries
    try w.writeInt(u32, directory_size, .little);
    try w.writeInt(u32, directory_start, .little);
    try w.writeInt(u16, 0, .little); // comment length
    return out.toOwnedSlice();
}

/// What a local header and a central one share, from the version needed to the name's length.
fn writeCommon(w: *std.Io.Writer, file: File, crc: u32) !void {
    const size = try fit32(file.data.len);
    try w.writeInt(u16, VERSION, .little); // needed to extract
    try w.writeInt(u16, UTF8_NAMES, .little);
    try w.writeInt(u16, STORED, .little);
    try w.writeInt(u16, DOS_TIME, .little);
    try w.writeInt(u16, DOS_DATE, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, size, .little); // compressed
    try w.writeInt(u32, size, .little); // uncompressed
    try w.writeInt(u16, std.math.cast(u16, file.name.len) orelse return error.NameTooLong, .little);
}

fn fit32(n: usize) error{ArchiveTooLarge}!u32 {
    return std.math.cast(u32, n) orelse error.ArchiveTooLarge;
}
