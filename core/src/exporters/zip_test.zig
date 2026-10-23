//! The zip writer (zip.zig): an archive std.zip reads back to the files given, each with
//! its CRC-32, and the same bytes for the same files.

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
