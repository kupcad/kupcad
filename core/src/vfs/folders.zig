//! `Folders`: a read-only `Vfs` of a few folders on disk, each read by absolute paths under
//! it (and only within it, as `NativeVfs` confines a path): the language server reads a
//! document opened from outside the workspace's folder from the project folder it is in, so
//! it imports its neighbours as `kupcad run` does, and nothing past that project.

const std = @import("std");
const Vfs = @import("vfs.zig").Vfs;
const NativeVfs = @import("native.zig").NativeVfs;

pub const Folders = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    folders: std.ArrayList(Folder) = .empty,

    const Folder = struct {
        /// Absolute, owned
        path: []u8,
        files: NativeVfs,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Folders {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Folders) void {
        for (self.folders.items) |folder| {
            folder.files.root_dir.close(self.io);
            self.allocator.free(folder.path);
        }
        self.folders.deinit(self.allocator);
    }

    /// Reads the folder at `path` (absolute) from now on; a folder it reads already, once.
    pub fn add(self: *Folders, path: []const u8) !void {
        for (self.folders.items) |folder| if (std.mem.eql(u8, folder.path, path)) return;
        const dir = try std.Io.Dir.cwd().openDir(self.io, path, .{});
        errdefer dir.close(self.io);
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.folders.append(self.allocator, .{ .path = owned, .files = NativeVfs.init(self.io, dir) });
    }

    pub fn vfs(self: *Folders) Vfs {
        return .{ .ptr = self, .vtable = &.{
            .makePath = refuse,
            .readFile = readFile,
            .writeFile = refuseWrite,
            .symLink = refuseLink,
        } };
    }

    /// The file at `path`, absolute, read from the folder it is under; none for one under no
    /// folder.
    fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *Folders = @ptrCast(@alignCast(ptr));
        for (self.folders.items) |*folder| {
            const inner = under(path, folder.path) orelse continue;
            return folder.files.vfs().readFile(allocator, inner);
        }
        return error.FileNotFound;
    }

    fn refuse(_: *anyopaque, _: []const u8) anyerror!void {
        return error.AccessDenied;
    }

    fn refuseWrite(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.AccessDenied;
    }

    fn refuseLink(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.AccessDenied;
    }
};

/// `path` from `folder` when it is under it, else null.
fn under(path: []const u8, folder: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, folder) or path.len <= folder.len + 1) return null;
    return if (std.fs.path.isSep(path[folder.len])) path[folder.len + 1 ..] else null;
}
