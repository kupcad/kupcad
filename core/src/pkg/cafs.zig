const std = @import("std");
const builtin = @import("builtin");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const Store = @import("store.zig").Store;
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

    /// Resolves the absolute physical path of a blob within the CAFS based on its hash
    pub fn blobPath(self: *Cafs, hash_hex: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/files/{s}", .{ self.global_dir_path, hash_hex });
    }

    /// Hard links a file from CAFS to the local project store via VFS
    pub fn linkBlob(self: *Cafs, hash_hex: []const u8, dest_path: []const u8) !void {
        const source_path = try self.blobPath(hash_hex);
        defer self.allocator.free(source_path);

        self.fs.hardLink(source_path, dest_path) catch |err| switch (err) {
            error.CrossDeviceLink, error.FileNotFound, error.OperationUnsupported => {
                // Fallback: Read physically from CAFS since VFS might be strictly in-memory
                const cwd = std.Io.Dir.cwd();

                // Securely stream the entire file dynamically to prevent TOCTOU vulnerabilities
                // caused by relying on potentially stale stat.size attributes.
                const content = try cwd.readFileAlloc(self.io, source_path, self.allocator, .unlimited);
                defer self.allocator.free(content);

                // Write to the destination VFS natively
                try self.fs.writeFile(dest_path, content);
            },
            else => return err,
        };
    }

    /// Offline-First Resolver: Checks if `commit_sha` is fully cached in SQLite Store/CAFS.
    /// Fast Path: Returns cached file map immediately without network/extraction.
    /// Fallback: Extracts tarball stream from `reader`, ingests to CAFS, and registers in Store.
    pub fn resolvePackage(
        self: *Cafs,
        store: *Store,
        pkg_id: []const u8,
        commit_sha: []const u8,
        provider_name: []const u8,
        reader: ?*std.Io.Reader,
    ) !std.StringHashMap([]const u8) {
        // 1. Offline Store Lookup Guard: Fast-path short-circuit
        if (try store.getPackageFiles(self.allocator, pkg_id, commit_sha)) |cached_map| {
            return cached_map;
        }

        // 2. Cache Miss: Ensure a valid network stream reader is provided
        const stream_reader = reader orelse return error.PackageNotFoundOffline;

        // 3. Fallback: Extract stream into PID-isolated temporary path and ingest to CAFS
        var file_map = try self.extractTarball(stream_reader);
        errdefer {
            var it = file_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            file_map.deinit();
        }

        // 4. Compute Merkle integrity & register in SQLite Store
        const integrity = try Store.computeIntegrity(self.allocator, &file_map);
        defer self.allocator.free(integrity);

        try store.registerPackage(pkg_id, commit_sha, provider_name, integrity, &file_map);

        return file_map;
    }

    /// Links all resolved package files into a target project directory via VFS
    pub fn materializePackage(
        self: *Cafs,
        files_map: *const std.StringHashMap([]const u8),
        dest_dir: []const u8,
    ) !void {
        var it = files_map.iterator();
        while (it.next()) |entry| {
            const rel_path = entry.key_ptr.*;
            const hash_hex = entry.value_ptr.*;

            const dest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dest_dir, rel_path });
            defer self.allocator.free(dest_path);

            try self.linkBlob(hash_hex, dest_path);
        }
    }

    pub fn extractTarball(
        self: *Cafs,
        reader: *std.Io.Reader,
    ) !std.StringHashMap([]const u8) {
        var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(reader, .gzip, &window_buffer);

        const cwd = std.Io.Dir.cwd();

        // Safely resolve a unique Process or Thread ID depending on the OS target
        const pid: usize = switch (builtin.os.tag) {
            .linux => @bitCast(@as(isize, std.os.linux.getpid())),
            .windows => @intCast(std.os.windows.kernel32.GetCurrentProcessId()),
            .wasi, .freestanding => 0,
            else => std.Thread.getCurrentId(), // Fallback to OS thread ID for macOS/BSD
        };

        // Combine nanosecond timestamp with the PID for collision-proof isolation
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}/tmp_{d}_{d}", .{ self.global_dir_path, std.Io.Clock.real.now(self.io).nanoseconds, pid });
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

    /// Streams data into a temporary file, hashes it, applies 0444, and atomically commits it to CAFS
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
