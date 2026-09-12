const std = @import("std");
const builtin = @import("builtin");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Cafs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    global_dir_path: []const u8,
    fs: Vfs,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, global_dir_path: []const u8, fs: Vfs) !Cafs {
        const cwd = std.Io.Dir.cwd();

        // Use native I/O for the global CAFS directories
        cwd.createDirPath(io, global_dir_path) catch {};

        const files_path = try std.fmt.allocPrint(allocator, "{s}/files", .{global_dir_path});
        defer allocator.free(files_path);
        cwd.createDirPath(io, files_path) catch {};

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}/tmp", .{global_dir_path});
        defer allocator.free(tmp_path);
        cwd.createDirPath(io, tmp_path) catch {};

        return .{
            .allocator = allocator,
            .io = io,
            .global_dir_path = try allocator.dupe(u8, global_dir_path),
            .fs = fs,
        };
    }

    pub fn deinit(self: *Cafs) void {
        self.allocator.free(self.global_dir_path);
    }

    /// Hard links a file from CAFS to the local project store via VFS
    pub fn linkBlob(self: *Cafs, hash_hex: []const u8, dest_path: []const u8) !void {
        const source_path = try std.fmt.allocPrint(self.allocator, "{s}/files/{s}", .{ self.global_dir_path, hash_hex });
        defer self.allocator.free(source_path);

        self.fs.hardLink(source_path, dest_path) catch |err| switch (err) {
            error.CrossDeviceLink, error.FileNotFound => {
                // Fallback: Read physically from CAFS since VFS might be strictly in-memory
                const cwd = std.Io.Dir.cwd();
                var file = try cwd.openFile(self.io, source_path, .{});
                defer file.close(self.io);

                const stat = try file.stat(self.io);
                const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
                const content = try self.allocator.alloc(u8, size);
                defer self.allocator.free(content);

                _ = try file.readPositionalAll(self.io, content, 0);

                // Write to the destination VFS natively
                try self.fs.writeFile(dest_path, content);
            },
            else => return err,
        };
    }

    /// Extracts a gzipped tarball stream directly into the CAFS.
    /// Returns a map of `[filepath] -> [sha256_hash]`.
    pub fn extractTarball(
        self: *Cafs,
        reader: *std.Io.Reader,
    ) !std.StringHashMap([]const u8) {
        var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(reader, .gzip, &window_buffer);

        const cwd = std.Io.Dir.cwd();
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}/tmp_{d}", .{ self.global_dir_path, std.Io.Clock.real.now(self.io).nanoseconds });
        defer self.allocator.free(tmp_path);

        try cwd.createDirPath(self.io, tmp_path);
        defer cwd.deleteTree(self.io, tmp_path) catch {};

        var tmp_dir = try cwd.openDir(self.io, tmp_path, .{ .iterate = true });
        defer tmp_dir.close(self.io);

        try std.tar.extract(self.io, tmp_dir, &decompress.reader, .{});

        var file_map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = file_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            file_map.deinit();
        }

        try self.ingestDir(tmp_dir, "", &file_map);

        return file_map;
    }

    fn ingestDir(
        self: *Cafs,
        dir: std.Io.Dir,
        rel_path: []const u8,
        file_map: *std.StringHashMap([]const u8),
    ) !void {
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const item_rel_path = if (rel_path.len == 0)
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rel_path, entry.name });
            defer self.allocator.free(item_rel_path);

            switch (entry.kind) {
                .file => {
                    var file = try dir.openFile(self.io, entry.name, .{});
                    defer file.close(self.io);

                    var buf: [8192]u8 = undefined;
                    var file_reader = file.reader(self.io, &buf);
                    const hash_hex = try self.saveStream(&file_reader.interface);

                    const map_key = try self.allocator.dupe(u8, item_rel_path);
                    try file_map.put(map_key, hash_hex);
                },
                .directory => {
                    var sub_dir = try dir.openDir(self.io, entry.name, .{ .iterate = true });
                    defer sub_dir.close(self.io);
                    try self.ingestDir(sub_dir, item_rel_path, file_map);
                },
                else => {},
            }
        }
    }

    /// Streams data into a temporary file, hashes it, applies 0444, and atomically commits it to CAFS.
    fn saveStream(self: *Cafs, reader: *std.Io.Reader) ![]const u8 {
        var hasher = Sha256.init(.{});

        var rand_buf: [8]u8 = undefined;
        self.io.random(&rand_buf);
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}/tmp/blob_{x}", .{ self.global_dir_path, &rand_buf });
        defer self.allocator.free(tmp_path);

        const cwd = std.Io.Dir.cwd();
        var file = try cwd.createFile(self.io, tmp_path, .{ .read = true });

        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try reader.readSliceShort(&buf);
            if (bytes_read == 0) break;

            hasher.update(buf[0..bytes_read]);
            try file.writeStreamingAll(self.io, buf[0..bytes_read]);
        }

        if (builtin.os.tag != .windows) {
            try file.setPermissions(self.io, std.Io.File.Permissions.fromMode(0o444));
        }
        file.close(self.io);

        const hash_out = hasher.finalResult();
        const hash_hex = try std.fmt.allocPrint(self.allocator, "{x}", .{&hash_out});

        const final_path = try std.fmt.allocPrint(self.allocator, "{s}/files/{s}", .{ self.global_dir_path, hash_hex });
        defer self.allocator.free(final_path);

        if (cwd.access(self.io, final_path, .{})) |_| {
            try cwd.deleteFile(self.io, tmp_path);
        } else |_| {
            cwd.rename(tmp_path, cwd, final_path, self.io) catch |err| {
                cwd.deleteFile(self.io, tmp_path) catch {};
                return err;
            };
        }

        return hash_hex;
    }
};
