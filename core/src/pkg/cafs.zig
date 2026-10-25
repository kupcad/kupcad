//! `Cafs`: the content-addressed file store of installed packages, one blob per SHA-256 of a
//! file's contents. `extractTarball` streams a package archive into it with path and size
//! checks, and `linkBlob` hard-links a blob into a project.

const std = @import("std");
const builtin = @import("builtin");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const limits = @import("limits.zig");
const string_map = @import("string_map.zig");
const owned_keys = @import("../core/owned_keys.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const log = std.log.scoped(.pkg);

/// Extra decompressed bytes allowed beyond file contents for tar headers/padding.
const TAR_METADATA_SLACK_BYTES: u64 = 64 * 1024 * 1024;

/// How an archive's entries map onto the package's files.
pub const ArchiveLayout = enum {
    /// Every entry sits in one top folder the host adds (`repo-<sha>/` from GitHub and
    /// GitLab, `repo/` from Gitea), which is not part of the package: it is stripped, so an
    /// import finds a package's files at the repository's paths.
    wrapped,
    /// The archive's root is the package's root (a `file:` or http archive).
    flat,
};

/// An extracted package: its files and, for a `wrapped` archive, the top folder stripped.
pub const Archive = struct {
    /// Package-relative path -> blob hash, both owned.
    files: std.StringHashMap([]const u8),
    /// The top folder every entry of a `wrapped` archive must share (owned); empty for `flat`.
    root: []const u8,

    pub fn deinit(self: *Archive, allocator: std.mem.Allocator) void {
        string_map.deinitOwned(allocator, &self.files);
        allocator.free(self.root);
    }

    /// `path` without the top folder, which the first file sets and every other must share.
    fn unwrap(self: *Archive, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const slash = std.mem.findScalar(u8, path, '/') orelse return error.UnexpectedArchiveLayout;
        const folder = path[0..slash];
        if (self.root.len == 0) {
            self.root = try allocator.dupe(u8, folder);
        } else if (!std.mem.eql(u8, self.root, folder)) return error.UnexpectedArchiveLayout;
        return path[slash + 1 ..];
    }
};

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
    /// VFS's trusted-source link API; the destination stays sandboxed. The blob is what
    /// its name says first (verifyBlob): a store's file is linked into every project
    /// installing it, and written through such a link (where the store's files can be
    /// written to), it would reach them all.
    pub fn linkBlob(self: *Cafs, hash_hex: []const u8, dest_path: []const u8) !void {
        const source_path = try self.blobPath(hash_hex);
        defer self.allocator.free(source_path);
        try self.verifyBlob(source_path, hash_hex);

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

    /// Streams a gzip'd tarball straight into the CAFS without ever materializing
    /// the archive on disk. Only regular files are ingested:
    /// - symlink entries are skipped (never created), so a later entry can't write
    ///   through a planted link to a location outside the package;
    /// - entry paths are sanitized (no absolute paths, `..`, `\\`, `:` or NUL);
    /// - total decompressed bytes and file count are capped (gzip / tar bombs);
    /// - a `wrapped` archive's top folder is stripped, and must be the same for every file;
    /// - two names that are one file on a case-insensitive disk are refused
    ///   (DuplicateArchiveEntry), and so is a file where another's folder is
    ///   (ArchivePathConflict): linking either into a project failed half-way, or kept one.
    pub fn extractTarball(
        self: *Cafs,
        reader: *std.Io.Reader,
        layout: ArchiveLayout,
    ) !Archive {
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

        var archive: Archive = .{ .files = .init(self.allocator), .root = &.{} };
        errdefer archive.deinit(self.allocator);
        const file_map = &archive.files;

        // The files' paths, and their folders', in ASCII lower case: what a case-insensitive
        // disk takes for one name
        var taken: Taken = .{ .allocator = self.allocator };
        defer taken.deinit();

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

            const entry_path = try sanitizeEntryPath(&sanitize_buffer, entry.name);
            const rel_path = switch (layout) {
                .flat => entry_path,
                .wrapped => try archive.unwrap(self.allocator, entry_path),
            };

            if (file_map.count() >= self.extract_limits.max_file_count) return error.ArchiveTooManyFiles;
            if (entry.size > max_total - total_bytes) return error.ArchiveTooLarge;
            total_bytes += entry.size;

            // Duplicate entries would silently replace content after the fact.
            if (file_map.contains(rel_path)) return error.DuplicateArchiveEntry;
            try taken.claim(rel_path);

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

        return archive;
    }

    /// The names an archive's files take on disk, folded to ASCII lower case: each file's, and
    /// each folder a file is in.
    const Taken = struct {
        allocator: std.mem.Allocator,
        files: std.StringHashMapUnmanaged(void) = .empty,
        folders: std.StringHashMapUnmanaged(void) = .empty,

        fn deinit(self: *Taken) void {
            owned_keys.deinit(&self.files, self.allocator, .borrowed);
            owned_keys.deinit(&self.folders, self.allocator, .borrowed);
        }

        /// Takes `path` for a file: refused when one folded the same is, or when it is a
        /// folder of one, or one of its folders is one.
        fn claim(self: *Taken, path: []const u8) !void {
            const folded = try std.ascii.allocLowerString(self.allocator, path);
            defer self.allocator.free(folded);
            if (self.files.contains(folded)) return error.DuplicateArchiveEntry;
            if (self.folders.contains(folded)) return error.ArchivePathConflict;
            var at: usize = 0;
            while (std.mem.findScalarPos(u8, folded, at, '/')) |slash| : (at = slash + 1) {
                if (self.files.contains(folded[0..slash])) return error.ArchivePathConflict;
            }
            at = 0;
            while (std.mem.findScalarPos(u8, folded, at, '/')) |slash| : (at = slash + 1) {
                _ = try owned_keys.getOrPutOwned(&self.folders, self.allocator, folded[0..slash]);
            }
            _ = try owned_keys.getOrPutOwned(&self.files, self.allocator, folded);
        }
    };

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

            if (builtin.target.os.tag != .windows) {
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

    /// error.BlobCorrupted unless the blob at `path` hashes to `hash_hex`, its name.
    fn verifyBlob(self: *Cafs, path: []const u8, hash_hex: []const u8) !void {
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        var hasher = Sha256.init(.{});
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = file.readStreaming(self.io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            hasher.update(buf[0..n]);
        }
        const digest = hasher.finalResult();
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &hex, hash_hex)) return error.BlobCorrupted;
    }

    /// Whether the blob named `hash_hex` holds what its name says (a file changed in the
    /// store, or cut short, doesn't).
    pub fn isIntact(self: *Cafs, hash_hex: []const u8) !bool {
        const path = try self.blobPath(hash_hex);
        defer self.allocator.free(path);
        self.verifyBlob(path, hash_hex) catch |err| switch (err) {
            error.BlobCorrupted => return false,
            else => return err,
        };
        return true;
    }

    /// Whether `name` is a blob's: a SHA-256 in lower-case hex.
    pub fn isBlobName(name: []const u8) bool {
        if (name.len != 2 * Sha256.digest_length) return false;
        for (name) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
        return true;
    }

    /// Reads a CAFS blob (trusted, absolute path) with an explicit size cap.
    pub fn readBlob(self: *Cafs, allocator: std.mem.Allocator, hash_hex: []const u8, max_bytes: usize) ![]u8 {
        const path = try self.blobPath(hash_hex);
        defer self.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(max_bytes));
    }
};
