//! The zip writer (zip.zig): an archive std.zip reads back to the files given, each with
//! its CRC-32, and the same bytes for the same files; and the reader, `Archive`, stored
//! and deflated files alike.

const std = @import("std");
const testing = std.testing;
const zip = @import("zip.zig");

const FILES = [_]zip.File{
    .{ .name = "[Content_Types].xml", .data = "<Types/>\n" },
    .{ .name = "3D/3dmodel.model", .data = "<model unit=\"millimeter\"/>\n" },
    .{ .name = "empty.txt", .data = "" },
    .{ .name = "größe.txt", .data = "UTF-8 name" },
};

/// The files of `archive` as std.zip extracts them, checked against FILES.
fn expectExtracts(archive: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zip", .data = archive });
    try tmp.dir.createDirPath(testing.io, "out");
    var out = try tmp.dir.openDir(testing.io, "out", .{});
    defer out.close(testing.io);
    const file = try tmp.dir.openFile(testing.io, "a.zip", .{});
    defer file.close(testing.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(testing.io, &buf);
    try std.zip.extract(out, &reader, .{});
    for (FILES) |f| {
        errdefer std.debug.print("file: {s}\n", .{f.name});
        const data = try out.readFileAlloc(testing.io, f.name, testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(data);
        try testing.expectEqualStrings(f.data, data);
    }
}

test "zip: more entries or a longer name than a zip's 16-bit fields hold is refused" {
    // 65535 files and a 65535-byte name are the most the format counts
    const many = try testing.allocator.alloc(zip.File, 1 << 16);
    defer testing.allocator.free(many);
    @memset(many, .{ .name = "a", .data = "" });
    try testing.expectError(error.ArchiveTooLarge, zip.write(testing.allocator, many));
    const long_name = try testing.allocator.alloc(u8, 1 << 16);
    defer testing.allocator.free(long_name);
    @memset(long_name, 'n');
    try testing.expectError(error.NameTooLong, zip.write(testing.allocator, &.{.{ .name = long_name, .data = "" }}));
    // One fewer of each still fits
    const fits = try zip.write(testing.allocator, many[0 .. (1 << 16) - 1]);
    testing.allocator.free(fits);
}

test "zip: an archive extracts to the files written, the names as given" {
    const archive = try zip.write(testing.allocator, &FILES);
    defer testing.allocator.free(archive);
    try expectExtracts(archive);
}

test "zip: each file's CRC-32 and sizes are its own, and the same files make the same bytes" {
    // std.zip doesn't check checksums yet: each local header is read here
    const archive = try zip.write(testing.allocator, &FILES);
    defer testing.allocator.free(archive);
    var at: usize = 0;
    for (FILES) |f| {
        errdefer std.debug.print("file: {s}\n", .{f.name});
        const header = archive[at..];
        try testing.expectEqualSlices(u8, "PK\x03\x04", header[0..4]);
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, header[8..10], .little)); // stored
        try testing.expectEqual(std.hash.Crc32.hash(f.data), std.mem.readInt(u32, header[14..18], .little));
        try testing.expectEqual(@as(u32, @intCast(f.data.len)), std.mem.readInt(u32, header[18..22], .little));
        try testing.expectEqual(@as(u32, @intCast(f.data.len)), std.mem.readInt(u32, header[22..26], .little));
        const name_len = std.mem.readInt(u16, header[26..28], .little);
        try testing.expectEqualStrings(f.name, header[30..][0..name_len]);
        at += 30 + name_len + f.data.len;
    }
    const again = try zip.write(testing.allocator, &FILES);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, archive, again);
}

test "zip: an archive read gives each file back, found by its name in either case" {
    const archive = try zip.write(testing.allocator, &FILES);
    defer testing.allocator.free(archive);
    const read = try zip.Archive.open(testing.allocator, archive);
    defer read.deinit(testing.allocator);
    try testing.expectEqual(FILES.len, read.entries.len);
    for (FILES) |f| {
        const data = try read.read(testing.allocator, read.find(f.name).?, 1 << 16);
        defer testing.allocator.free(data);
        try testing.expectEqualStrings(f.data, data);
    }
    // A package names its parts from its root, in any case
    try testing.expect(read.find("/3d/3DMODEL.model") != null);
    try testing.expect(read.find("missing") == null);
    try testing.expectError(error.TooLarge, read.read(testing.allocator, read.find("3D/3dmodel.model").?, 4));
}

/// An archive of one file, `name`, whose data is `packed_data` by `method` and `size` long
/// unpacked, with the `crc` and the `flags` given: the local header, the data, the central
/// header and the end record.
fn oneFile(comptime name: []const u8, method: u16, flags: u16, packed_data: []const u8, size: u32, crc: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for ([_]bool{ false, true }) |central| {
        try w.writeInt(u32, if (central) 0x02014b50 else 0x04034b50, .little);
        if (central) try w.writeInt(u16, 20, .little);
        for ([_]u16{ 20, flags, method, 0, 0 }) |v| try w.writeInt(u16, v, .little);
        for ([_]u32{ crc, @intCast(packed_data.len), size }) |v| try w.writeInt(u32, v, .little);
        try w.writeInt(u16, name.len, .little);
        try w.writeInt(u16, 0, .little);
        if (central) {
            for ([_]u16{ 0, 0, 0 }) |v| try w.writeInt(u16, v, .little);
            try w.writeInt(u32, 0, .little);
            try w.writeInt(u32, 0, .little); // the local header's offset
        }
        try w.writeAll(name);
        if (!central) try w.writeAll(packed_data);
    }
    const directory = 30 + name.len + packed_data.len;
    try w.writeInt(u32, 0x06054b50, .little);
    for ([_]u16{ 0, 0, 1, 1 }) |v| try w.writeInt(u16, v, .little);
    try w.writeInt(u32, @intCast(46 + name.len), .little);
    try w.writeInt(u32, @intCast(directory), .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

test "zip: a deflated file is inflated, and a file the reader can't take says why" {
    // "Hello world\n" in one fixed-code deflate block
    const deflated = [_]u8{ 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00 };
    const crc = std.hash.Crc32.hash("Hello world\n");
    const archive = try oneFile("hello.txt", 8, 0, &deflated, 12, crc);
    defer testing.allocator.free(archive);
    const read = try zip.Archive.open(testing.allocator, archive);
    defer read.deinit(testing.allocator);
    const data = try read.read(testing.allocator, read.entries[0], 1 << 16);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("Hello world\n", data);

    // A CRC-32 that isn't the data's; an encrypted file; a method but stored or deflated
    inline for (.{ .{ 8, 0, crc + 1, error.Corrupt }, .{ 8, 1, crc, error.Unsupported }, .{ 12, 0, crc, error.Unsupported } }) |case| {
        const bad = try oneFile("hello.txt", case[0], case[1], &deflated, 12, case[2]);
        defer testing.allocator.free(bad);
        const opened = try zip.Archive.open(testing.allocator, bad);
        defer opened.deinit(testing.allocator);
        try testing.expectError(case[3], opened.read(testing.allocator, opened.entries[0], 1 << 16));
    }
    try testing.expectError(error.NotAnArchive, zip.Archive.open(testing.allocator, "solid part\nendsolid part\n"));
}
