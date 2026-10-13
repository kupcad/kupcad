const std = @import("std");
const builtin = @import("builtin");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const Store = @import("store.zig").Store;
const limits = @import("limits.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const log = std.log.scoped(.pkg);

/// Extra decompressed bytes allowed beyond file contents for tar headers/padding.
const TAR_METADATA_SLACK_BYTES: u64 = 64 * 1024 * 1024;

pub const ExtractLimits = struct {
    max_total_bytes: u64 = limits.MAX_EXTRACTED_TOTAL_BYTES,
    max_file_count: usize = limits.MAX_EXTRACTED_FILE_COUNT,
};

/// Normalizes a tar entry name into a safe relative path, or fails.
/// Rejects anything that could resolve outside the package root or that has a
/// different meaning on another OS (backslashes, drive letters / ADS via ':').
pub fn sanitizeEntryPath(buffer: []u8, name: []const u8) ![]const u8 {
    if (name.len == 0 or name[0] == '/') return error.UnsafeArchivePath;
    var len: usize = 0;
    var comp_it = std.mem.splitScalar(u8, name, '/');
    while (comp_it.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return error.UnsafeArchivePath;
        for (component) |c| {
            if (c == 0 or c == '\\' or c == ':') return error.UnsafeArchivePath;
        }
        if (len > 0) {
            if (len >= buffer.len) return error.UnsafeArchivePath;
            buffer[len] = '/';
            len += 1;
        }
        if (component.len > buffer.len - len) return error.UnsafeArchivePath;
        @memcpy(buffer[len..][0..component.len], component);
        len += component.len;
    }
    if (len == 0) return error.UnsafeArchivePath;
    return buffer[0..len];
}

pub const Cafs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    global_dir_path: []const u8,
    fs: Vfs,
    extract_limits: ExtractLimits = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, global_dir_path: []const u8, fs: Vfs) !Cafs {
        const cwd = std.Io.Dir.cwd();

        // Use native I/O for the global CAFS directories
        cwd.createDirPath(io, global_dir_path) catch |err| std.log.warn("Failed to create CAFS dir: {}", .{err});

        const files_path = try allocator.print("{s}/files", .{global_dir_path});
        defer allocator.free(files_path);
        cwd.createDirPath(io, files_path) catch |err| std.log.warn("Failed to create CAFS files dir: {}", .{err});

        const tmp_path = try allocator.print("{s}/tmp", .{global_dir_path});
        defer allocator.free(tmp_path);
        cwd.createDirPath(io, tmp_path) catch |err| std.log.warn("Failed to create CAFS tmp dir: {}", .{err});

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
        return self.allocator.print("{s}/files/{s}", .{ self.global_dir_path, hash_hex });
    }

    /// Hard links a file from CAFS to the local project store via VFS.
    /// The CAFS blob path is absolute and owned by us, so it goes through the
    /// VFS's trusted-source link API; the destination stays sandboxed.
    pub fn linkBlob(self: *Cafs, hash_hex: []const u8, dest_path: []const u8) !void {
        const source_path = try self.blobPath(hash_hex);
        defer self.allocator.free(source_path);

        self.fs.hardLinkTrusted(source_path, dest_path) catch |err| switch (err) {
            // NOTE: AccessDenied is deliberately *not* here: it means the sandbox
            // rejected the destination, and must not be bypassed via writeFile.
            error.CrossDevice, error.CrossDeviceLink, error.OperationUnsupported, error.LinkQuotaExceeded => {
                // Fallback: Read physically from CAFS since VFS might be strictly in-memory
                // or on another device.
                const cwd = std.Io.Dir.cwd();

                // Stream the whole file (bounded) instead of trusting a possibly stale stat.size.
                const content = try cwd.readFileAlloc(self.io, source_path, self.allocator, .limited(limits.MAX_BLOB_COPY_BYTES));
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
        expected_integrity: ?[]const u8,
    ) !std.StringHashMap([]const u8) {
        // 1. Offline Store Lookup Guard: Fast-path short-circuit
        if (try store.getPackageFiles(self.allocator, pkg_id, commit_sha)) |cached_map| {
            var map = cached_map;
            errdefer Store.freeFileMap(self.allocator, &map);
            // Cached content is verified too: the index may have been tampered with.
            if (expected_integrity) |expected| try Store.verifyIntegrity(self.allocator, &map, expected, .current);
            return map;
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

        // Never register (or hand out) content that doesn't match the pinned integrity.
        if (expected_integrity) |expected| {
            if (!std.mem.eql(u8, integrity, expected)) return error.IntegrityMismatch;
        }

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

            const dest_path = try self.allocator.print("{s}/{s}", .{ dest_dir, rel_path });
            defer self.allocator.free(dest_path);

            try self.linkBlob(hash_hex, dest_path);
        }
    }

    /// Streams a gzip'd tarball straight into the CAFS without ever materializing
    /// the archive on disk. Only regular files are ingested:
    /// - symlink entries are skipped (never created), so a later entry can't write
    ///   through a planted link to a location outside the package;
    /// - entry paths are sanitized (no absolute paths, `..`, `\\`, `:` or NUL);
    /// - total decompressed bytes and file count are capped (gzip / tar bombs).
    pub fn extractTarball(
        self: *Cafs,
        reader: *std.Io.Reader,
    ) !std.StringHashMap([]const u8) {
        var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompress: std.compress.flate.Decompress = .init(reader, .gzip, &window_buffer);

        // Hard cap on decompressed bytes, including tar headers / padding / skipped
        // entries, so a tiny archive cannot expand into unbounded work.
        const max_total = self.extract_limits.max_total_bytes;
        var limited_buf: [8192]u8 = undefined;
        var limited: std.Io.Reader.Limited = .init(&decompress.reader, .limited64(max_total + TAR_METADATA_SLACK_BYTES), &limited_buf);

        var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var sanitize_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var it: std.tar.Iterator = .init(&limited.interface, .{
            .file_name_buffer = &file_name_buffer,
            .link_name_buffer = &link_name_buffer,
        });

        var file_map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var map_it = file_map.iterator();
            while (map_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            file_map.deinit();
        }

        var total_bytes: u64 = 0;
        while (true) {
            const maybe_entry = it.next() catch |err| {
                if (limited.remaining == .nothing) return error.ArchiveTooLarge;
                return err;
            };
            const entry = maybe_entry orelse break;

            switch (entry.kind) {
                .directory => continue,
                .sym_link => {
                    log.warn("Skipping symlink entry '{s}' in package archive (symlinks are never extracted)", .{entry.name});
                    continue;
                },
                .file => {},
            }

            const rel_path = try sanitizeEntryPath(&sanitize_buffer, entry.name);

            if (file_map.count() >= self.extract_limits.max_file_count) return error.ArchiveTooManyFiles;
            if (entry.size > max_total - total_bytes) return error.ArchiveTooLarge;
            total_bytes += entry.size;

            // Duplicate entries would silently replace content after the fact.
            if (file_map.contains(rel_path)) return error.DuplicateArchiveEntry;

            const hash_hex = self.saveExact(it.reader, entry.size) catch |err| {
                if (limited.remaining == .nothing) return error.ArchiveTooLarge;
                return err;
            };
            errdefer self.allocator.free(hash_hex);
            // Content was consumed manually; tell the iterator not to skip it again.
            it.unread_file_bytes = 0;

            const map_key = try self.allocator.dupe(u8, rel_path);
            errdefer self.allocator.free(map_key);
            try file_map.put(map_key, hash_hex);
        }

        return file_map;
    }

    /// Streams exactly `size` bytes into a temporary file, hashes it, applies 0444, and atomically commits it to CAFS
    fn saveExact(self: *Cafs, reader: *std.Io.Reader, size: u64) ![]const u8 {
        var hasher = Sha256.init(.{});

        var rand_buf: [8]u8 = undefined;
        self.io.random(&rand_buf);
        const tmp_path = try self.allocator.print("{s}/tmp/blob_{x}", .{ self.global_dir_path, &rand_buf });
        defer self.allocator.free(tmp_path);

        const cwd = std.Io.Dir.cwd();
        var file = try cwd.createFile(self.io, tmp_path, .{ .read = true, .exclusive = true });
        var committed = false;
        defer if (!committed) {
            cwd.deleteFile(self.io, tmp_path) catch |e| std.log.warn("Failed to delete tmp file: {}", .{e});
        };
        {
            defer file.close(self.io);

            var buf: [8192]u8 = undefined;
            var remaining = size;
            while (remaining > 0) {
                const n: usize = @intCast(@min(remaining, buf.len));
                reader.readSliceAll(buf[0..n]) catch |err| switch (err) {
                    error.EndOfStream => return error.UnexpectedEndOfStream,
                    else => return err,
                };
                hasher.update(buf[0..n]);
                try file.writeStreamingAll(self.io, buf[0..n]);
                remaining -= n;
            }

            if (builtin.os.tag != .windows) {
                try file.setPermissions(self.io, std.Io.File.Permissions.fromMode(0o444));
            }
        }

        const hash_out = hasher.finalResult();
        const hash_hex = try self.allocator.print("{x}", .{&hash_out});
        errdefer self.allocator.free(hash_hex);

        const final_path = try self.allocator.print("{s}/files/{s}", .{ self.global_dir_path, hash_hex });
        defer self.allocator.free(final_path);

        if (cwd.access(self.io, final_path, .{})) |_| {
            // Identical content already stored; the deferred cleanup removes the tmp copy.
        } else |_| {
            try cwd.rename(tmp_path, cwd, final_path, self.io);
            committed = true;
        }

        return hash_hex;
    }

    /// Reads a CAFS blob (trusted, absolute path) with an explicit size cap.
    pub fn readBlob(self: *Cafs, allocator: std.mem.Allocator, hash_hex: []const u8, max_bytes: usize) ![]u8 {
        const path = try self.blobPath(hash_hex);
        defer self.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(max_bytes));
    }
};
