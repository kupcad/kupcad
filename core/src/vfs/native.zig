//! `NativeVfs`: the `Vfs` over a real directory, confining every path to it: no absolute
//! paths, no `..` above it, symlink targets kept inside, and what a path really names (a
//! symlink inside the root may lead out of it) under the root; `hardLinkTrusted` links in a
//! file from the package store outside it.

const std = @import("std");
const limits = @import("../core/limits.zig");
const Vfs = @import("vfs.zig").Vfs;

pub const NativeVfs = struct {
    io: std.Io,
    root_dir: std.Io.Dir,
    /// Largest file a read takes (error.FileTooBig past it): a read allocates the file's
    /// size first, and no import takes more.
    max_read_bytes: u64 = limits.MAX_READ_BYTES,

    /// Initializes NativeVfs using the provided directory.
    pub fn init(io: std.Io, root_dir: std.Io.Dir) NativeVfs {
        return .{ .io = io, .root_dir = root_dir };
    }

    pub fn vfs(self: *NativeVfs) Vfs {
        return .{
            .ptr = self,
            .vtable = &.{
                .makePath = makePath,
                .readFile = readFile,
                .writeFile = writeFile,
                .hardLink = hardLink,
                .symLink = symLink,
                .hardLinkTrusted = hardLinkTrusted,
            },
        };
    }

    /// Refuses `path` unless it stays in the root: as written (ensureSafePath), and as the
    /// file system resolves it, where a symlink inside the root may lead outside it (a
    /// project cloned from the internet may hold one). What isn't there yet (a file to
    /// write, directories to make) is judged by the nearest of its ancestors that is.
    fn confine(self: *NativeVfs, path: []const u8) !void {
        try ensureSafePath(path);
        var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = root_buf[0..try self.root_dir.realPath(self.io, &root_buf)];
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const real = try self.realOfNearest(path, &buf);
        const inside = std.mem.startsWith(u8, real, root) and
            (real.len == root.len or std.fs.path.isSep(real[root.len]));
        if (!inside) return error.AccessDenied;
    }

    /// The real path of `path`, or of the nearest ancestor of it that exists: the root's,
    /// for one at the top.
    fn realOfNearest(self: *NativeVfs, path: []const u8, buf: []u8) ![]const u8 {
        var at: ?[]const u8 = path;
        while (at) |sub_path| : (at = std.fs.path.dirname(sub_path)) {
            const len = self.root_dir.realPathFile(self.io, sub_path, buf) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            return buf[0..len];
        }
        return buf[0..try self.root_dir.realPath(self.io, buf)];
    }

    /// Validates that a path does not escape the virtual filesystem root, as written
    fn ensureSafePath(path: []const u8) !void {
        if (std.fs.path.isAbsolute(path)) return error.AccessDenied;

        var depth: isize = 0;
        var it = std.mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, "..")) {
                depth -= 1;
                if (depth < 0) return error.AccessDenied;
            } else if (!std.mem.eql(u8, component, ".")) {
                depth += 1;
            }
        }
    }

    fn makePath(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.confine(path);
        try self.root_dir.createDirPath(self.io, path);
    }

    fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.confine(path);
        const file = try self.root_dir.openFile(self.io, path, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        if (stat.size > self.max_read_bytes) return error.FileTooBig;
        const file_size: usize = @intCast(stat.size);

        const buffer = try allocator.alloc(u8, file_size);
        // Free on the short-read error path below; the caller only owns it on success.
        errdefer allocator.free(buffer);
        const bytes_read = try file.readStreaming(self.io, &.{buffer});
        if (bytes_read != file_size) return error.RuntimeError;

        return buffer;
    }

    fn writeFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.confine(path);
        try self.root_dir.writeFile(self.io, .{ .sub_path = path, .data = data });
    }

    fn hardLink(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.confine(old_path);
        try self.confine(new_path);
        try self.root_dir.hardLink(old_path, self.root_dir, new_path, self.io, .{});
    }

    /// Links a trusted absolute source (the CAFS store, outside the sandbox root)
    /// into the sandbox. Only absolute sources are accepted so this can't be used
    /// as a back door for relative, script-supplied paths; the destination is
    /// still confined by ensureSafePath. An existing destination is replaced so
    /// re-installs refresh links.
    fn hardLinkTrusted(ptr: *anyopaque, trusted_abs_source: []const u8, new_path: []const u8) anyerror!void {
        if (!std.fs.path.isAbsolute(trusted_abs_source)) return error.AccessDenied;
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.confine(new_path);
        const cwd = std.Io.Dir.cwd();
        cwd.hardLink(trusted_abs_source, self.root_dir, new_path, self.io, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try self.root_dir.deleteFile(self.io, new_path);
                try cwd.hardLink(trusted_abs_source, self.root_dir, new_path, self.io, .{});
            },
            else => return err,
        };
    }

    /// Validates a symlink target *relative to the link's directory* (which is how
    /// the OS resolves it) and requires it to stay inside the root. Absolute
    /// targets are always rejected.
    fn ensureSafeLinkTarget(link_path: []const u8, target_path: []const u8) !void {
        if (target_path.len == 0 or std.fs.path.isAbsolute(target_path)) return error.AccessDenied;

        var depth: isize = 0;
        if (std.fs.path.dirname(link_path)) |link_dir| {
            var dir_it = std.mem.tokenizeAny(u8, link_dir, "/\\");
            while (dir_it.next()) |component| {
                if (std.mem.eql(u8, component, "..")) {
                    depth -= 1;
                } else if (!std.mem.eql(u8, component, ".")) {
                    depth += 1;
                }
            }
        }

        var it = std.mem.tokenizeAny(u8, target_path, "/\\");
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, "..")) {
                depth -= 1;
                if (depth < 0) return error.AccessDenied;
            } else if (!std.mem.eql(u8, component, ".")) {
                depth += 1;
            }
        }
    }

    fn symLink(ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.confine(link_path);
        try ensureSafeLinkTarget(link_path, target_path);
        self.root_dir.symLink(self.io, target_path, link_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Re-install: replace a stale *symlink* (e.g. pointing at an old commit),
                // but never delete a real file/directory that happens to be there.
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const n = self.root_dir.readLink(self.io, link_path, &buf) catch return err;
                if (std.mem.eql(u8, buf[0..n], target_path)) return;
                try self.root_dir.deleteFile(self.io, link_path);
                try self.root_dir.symLink(self.io, target_path, link_path, .{});
            },
            else => return err,
        };
    }
};
