//! Zip archives, what a 3MF package is. `write` writes one of stored (uncompressed) files
//! (3d/threemf.zig's): each as given, with its CRC-32, then the central directory. Names
//! are UTF-8 (general purpose bit 11), times the format's earliest (1980-01-01), so the same
//! files make the same bytes. `Archive` reads one (3d/threemf_read.zig's), its files stored
//! or deflated, by its central directory. Sizes and offsets are 32-bit both ways: an
//! archive past 4 GiB, which needs zip64, is refused.

const std = @import("std");

const LOCAL_HEADER_SIG: u32 = 0x04034b50;
const CENTRAL_HEADER_SIG: u32 = 0x02014b50;
const END_RECORD_SIG: u32 = 0x06054b50;
/// 2.0, the version that reads stored files and folders.
const VERSION: u16 = 20;
/// General purpose bit 11: the names are UTF-8.
const UTF8_NAMES: u16 = 1 << 11;
const STORED: u16 = 0;
const DEFLATED: u16 = 8;
/// General purpose bit 0: the file is encrypted.
const ENCRYPTED: u16 = 1;
/// The fixed parts of the records, before their names.
const END_RECORD_LEN = 22;
const CENTRAL_HEADER_LEN = 46;
const LOCAL_HEADER_LEN = 30;
/// The longest comment an end record carries, which it is searched for back past.
const MAX_COMMENT_LEN = 0xFFFF;
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

pub const ReadError = error{
    /// No end record: the data isn't a zip archive.
    NotAnArchive,
    /// A record that doesn't fit the data, or a file whose CRC-32 isn't its own.
    Corrupt,
    /// What this reader doesn't read: zip64, an encrypted file, a method but stored or
    /// deflated.
    Unsupported,
    /// A file past the most a caller takes.
    TooLarge,
} || std.mem.Allocator.Error;

/// A zip archive in memory, read by its central directory.
pub const Archive = struct {
    data: []const u8,
    entries: []const Entry,

    pub const Entry = struct {
        name: []const u8,
        method: u16,
        flags: u16,
        crc: u32,
        compressed: u32,
        size: u32,
        /// Where its local header starts
        offset: u32,
    };

    /// The archive `data` (held, not copied), its entries owned by `allocator`.
    pub fn open(allocator: std.mem.Allocator, data: []const u8) ReadError!Archive {
        const end = endRecord(data) orelse return error.NotAnArchive;
        const count = std.mem.readInt(u16, data[end + 10 ..][0..2], .little);
        const directory_size = std.mem.readInt(u32, data[end + 12 ..][0..4], .little);
        const directory_start = std.mem.readInt(u32, data[end + 16 ..][0..4], .little);
        if (count == 0xFFFF or directory_start == 0xFFFF_FFFF) return error.Unsupported;
        if (@as(u64, directory_start) + directory_size > end) return error.Corrupt;
        const entries = try allocator.alloc(Entry, count);
        errdefer allocator.free(entries);
        var at: usize = directory_start;
        for (entries) |*entry| {
            if (at + CENTRAL_HEADER_LEN > end or std.mem.readInt(u32, data[at..][0..4], .little) != CENTRAL_HEADER_SIG) return error.Corrupt;
            const name_len = std.mem.readInt(u16, data[at + 28 ..][0..2], .little);
            const extra_len = std.mem.readInt(u16, data[at + 30 ..][0..2], .little);
            const comment_len = std.mem.readInt(u16, data[at + 32 ..][0..2], .little);
            const name_start = at + CENTRAL_HEADER_LEN;
            if (name_start + name_len > end) return error.Corrupt;
            entry.* = .{
                .name = data[name_start..][0..name_len],
                .flags = std.mem.readInt(u16, data[at + 8 ..][0..2], .little),
                .method = std.mem.readInt(u16, data[at + 10 ..][0..2], .little),
                .crc = std.mem.readInt(u32, data[at + 16 ..][0..4], .little),
                .compressed = std.mem.readInt(u32, data[at + 20 ..][0..4], .little),
                .size = std.mem.readInt(u32, data[at + 24 ..][0..4], .little),
                .offset = std.mem.readInt(u32, data[at + 42 ..][0..4], .little),
            };
            at = name_start + name_len + extra_len + comment_len;
        }
        return .{ .data = data, .entries = entries };
    }

    pub fn deinit(self: Archive, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    /// The file named `name` (ASCII letters in either case, as a package's part names
    /// are; a leading '/' left out), if the archive has it.
    pub fn find(self: Archive, name: []const u8) ?Entry {
        const wanted = std.mem.trimStart(u8, name, "/");
        for (self.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, wanted)) return entry;
        }
        return null;
    }

    /// The bytes of `entry`, owned by `allocator`: error.TooLarge past `max_bytes`, and
    /// error.Corrupt when they aren't what its CRC-32 says.
    pub fn read(self: Archive, allocator: std.mem.Allocator, entry: Entry, max_bytes: usize) ReadError![]u8 {
        if (entry.flags & ENCRYPTED != 0) return error.Unsupported;
        if (entry.method != STORED and entry.method != DEFLATED) return error.Unsupported;
        if (entry.size > max_bytes) return error.TooLarge;
        const at: usize = entry.offset;
        if (at + LOCAL_HEADER_LEN > self.data.len or std.mem.readInt(u32, self.data[at..][0..4], .little) != LOCAL_HEADER_SIG) return error.Corrupt;
        const start = at + LOCAL_HEADER_LEN + std.mem.readInt(u16, self.data[at + 26 ..][0..2], .little) + std.mem.readInt(u16, self.data[at + 28 ..][0..2], .little);
        if (start + entry.compressed > self.data.len) return error.Corrupt;
        const packed_data = self.data[start..][0..entry.compressed];
        const out = try allocator.alloc(u8, entry.size);
        errdefer allocator.free(out);
        if (entry.method == STORED) {
            if (entry.compressed != entry.size) return error.Corrupt;
            @memcpy(out, packed_data);
        } else {
            const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
            defer allocator.free(window);
            var in: std.Io.Reader = .fixed(packed_data);
            var inflate: std.compress.flate.Decompress = .init(&in, .raw, window);
            inflate.reader.readSliceAll(out) catch return error.Corrupt;
        }
        if (std.hash.Crc32.hash(out) != entry.crc) return error.Corrupt;
        return out;
    }
};

/// Where the end record starts: the last one, searched for back past a comment.
fn endRecord(data: []const u8) ?usize {
    if (data.len < END_RECORD_LEN) return null;
    var at = data.len - END_RECORD_LEN;
    const lowest = data.len -| (END_RECORD_LEN + MAX_COMMENT_LEN);
    while (true) : (at -= 1) {
        if (std.mem.readInt(u32, data[at..][0..4], .little) == END_RECORD_SIG) return at;
        if (at == lowest) return null;
    }
}
