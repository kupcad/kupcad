//! Shared helpers for the pkg test files: in-memory tarballs, absolute-path
//! file writes and store row counts. No `test` blocks; not registered in root.zig.

const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;

// ---------------------------------------------------------------------------
// In-memory tar / gzip builders (hand-rolled ustar + stored-deflate gzip)
// ---------------------------------------------------------------------------

pub const TarEntry = struct {
    name: []const u8,
    kind: enum { file, symlink, dir } = .file,
    data: []const u8 = "",
    link: []const u8 = "",
};

fn writeOctal(field: []u8, value: u64) void {
    // N-1 octal digits followed by NUL
    _ = std.fmt.bufPrint(field[0 .. field.len - 1], "{o:0>[1]}", .{ value, field.len - 1 }) catch unreachable;
    field[field.len - 1] = 0;
}

pub fn buildTar(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (entries) |e| {
        var h: [512]u8 = @splat(0);
        @memcpy(h[0..e.name.len], e.name);
        writeOctal(h[100..108], if (e.kind == .dir) 0o755 else 0o644);
        writeOctal(h[108..116], 0);
        writeOctal(h[116..124], 0);
        writeOctal(h[124..136], e.data.len);
        writeOctal(h[136..148], 0);
        h[156] = switch (e.kind) {
            .file => '0',
            .symlink => '2',
            .dir => '5',
        };
        @memcpy(h[157..][0..e.link.len], e.link);
        @memcpy(h[257..263], "ustar\x00");
        @memcpy(h[263..265], "00");
        @memset(h[148..156], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        _ = std.fmt.bufPrint(h[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
        try out.appendSlice(allocator, &h);
        try out.appendSlice(allocator, e.data);
        const pad = (512 - e.data.len % 512) % 512;
        try out.appendNTimes(allocator, 0, pad);
    }
    try out.appendNTimes(allocator, 0, 1024);
    return out.toOwnedSlice(allocator);
}

/// gzip container with uncompressed ("stored") deflate blocks.
pub fn gzipStored(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff });
    var off: usize = 0;
    while (true) {
        const n = @min(data.len - off, 65535);
        const final = off + n == data.len;
        try out.append(allocator, if (final) 1 else 0);
        const len: u16 = @intCast(n);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
        try out.appendSlice(allocator, data[off..][0..n]);
        off += n;
        if (final) break;
    }
    const crc = std.hash.Crc32.hash(data);
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, crc)));
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @truncate(data.len)))));
    return out.toOwnedSlice(allocator);
}

pub fn buildTarGz(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    const tar = try buildTar(allocator, entries);
    defer allocator.free(tar);
    return gzipStored(allocator, tar);
}

// ---------------------------------------------------------------------------
// Filesystem / store
// ---------------------------------------------------------------------------

pub fn writeAbs(path: []const u8, data: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, data);
}

pub fn freeMap(map: *std.StringHashMap([]const u8)) void {
    Store.freeFileMap(testing.allocator, map);
}

/// Runs a single-row `SELECT ... AS n` / `COUNT(*)` query.
pub fn countRows(store: *Store, sql: []const u8) !i64 {
    const stmt = try store.db.prepare(sql);
    defer stmt.deinit();
    return (try stmt.one(struct { n: i64 }, .{}, .{})).?.n;
}
