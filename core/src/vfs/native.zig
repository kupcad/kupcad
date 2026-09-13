const std = @import("std");
const Vfs = @import("vfs.zig").Vfs;

pub const NativeVfs = struct {
    io: std.Io,
    root_dir: std.Io.Dir,

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
            },
        };
    }

    /// Validates that a path does not escape the virtual filesystem root
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
        try ensureSafePath(path);
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.root_dir.createDirPath(self.io, path);
    }

    fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        try ensureSafePath(path);
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        const file = try self.root_dir.openFile(self.io, path, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const file_size: usize = @intCast(stat.size);

        const buffer = try allocator.alloc(u8, file_size);
        const bytes_read = try file.readStreaming(self.io, &.{buffer});
        if (bytes_read != file_size) return error.RuntimeError;

        return buffer;
    }

    fn writeFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        try ensureSafePath(path);
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.root_dir.writeFile(self.io, .{ .sub_path = path, .data = data });
    }

    fn hardLink(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
        try ensureSafePath(old_path);
        try ensureSafePath(new_path);
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.root_dir.hardLink(old_path, self.root_dir, new_path, self.io, .{});
    }

    fn symLink(ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void {
        try ensureSafePath(target_path);
        try ensureSafePath(link_path);
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        try self.root_dir.symLink(self.io, target_path, link_path, .{});
    }
};
