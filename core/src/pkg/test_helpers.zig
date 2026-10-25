//! Shared helpers for the pkg test files: in-memory tarballs, absolute-path
//! file writes, store row counts and a slow HTTP host. No `test` blocks; not registered
//! in root.zig.

const std = @import("std");
const testing = std.testing;
const Store = @import("store.zig").Store;
const string_map = @import("string_map.zig");

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
    _ = std.mem.print(field[0 .. field.len - 1], "{o:0>[1]}", .{ value, field.len - 1 }) catch unreachable;
    field[field.len - 1] = 0;
}

pub fn buildTar(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
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
        _ = std.mem.print(h[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
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
    var out: std.ArrayList(u8) = .empty;
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
    string_map.deinitOwned(testing.allocator, map);
}

/// Runs a single-row `SELECT ... AS n` / `COUNT(*)` query.
pub fn countRows(store: *Store, sql: []const u8) !i64 {
    const stmt = try store.db.prepare(sql);
    defer stmt.deinit();
    return (try stmt.one(struct { n: i64 }, .{})).?.n;
}

// ---------------------------------------------------------------------------
// A slow HTTP host
// ---------------------------------------------------------------------------

/// Serves one GET on 127.0.0.1, on a thread of its own, as a host that slows and stops does:
/// its head (unless `head` is false), then `pieces` bytes of a body of `length`, one each
/// `gap`, and then nothing, the connection held open until `stop`.
pub const SlowServer = struct {
    server: std.Io.net.Server,
    port: u16,
    options: Options,
    stopping: std.Io.Event = .unset,
    thread: std.Thread,

    pub const Options = struct {
        head: bool = true,
        pieces: usize = 0,
        gap: std.Io.Duration = .zero,
        length: usize = 64,
    };

    pub fn start(self: *SlowServer, options: Options) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const server = try address.listen(testing.io, .{});
        self.* = .{ .server = server, .port = server.socket.address.getPort(), .options = options, .thread = undefined };
        errdefer self.server.deinit(testing.io);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    /// Also when no client came: a throwaway connection wakes a pending accept.
    pub fn stop(self: *SlowServer) void {
        self.stopping.set(testing.io);
        const address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch unreachable;
        if (address.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
        self.thread.join();
        self.server.deinit(testing.io);
    }

    /// The URL of `path` on this host, in `buffer`.
    pub fn url(self: *const SlowServer, buffer: []u8, path: []const u8) ![]const u8 {
        return std.mem.print(buffer, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    fn serve(self: *SlowServer) void {
        self.serveOne() catch {};
    }

    fn serveOne(self: *SlowServer) !void {
        const stream = try self.server.accept(testing.io);
        defer stream.close(testing.io);
        if (self.stopping.isSet()) return;
        var r_buf: [4096]u8 = undefined;
        var reader = stream.reader(testing.io, &r_buf);
        while (!std.mem.eql(u8, try reader.interface.takeDelimiterInclusive('\n'), "\r\n")) {}
        var w_buf: [256]u8 = undefined;
        var writer = stream.writer(testing.io, &w_buf);
        if (self.options.head) {
            try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{self.options.length});
            try writer.interface.flush();
            for (0..self.options.pieces) |_| {
                try testing.io.sleep(self.options.gap, .awake);
                try writer.interface.writeByte('x');
                try writer.interface.flush();
            }
        }
        self.stopping.waitUncancelable(testing.io);
    }
};
