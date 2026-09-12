const std = @import("std");
const Vfs = @import("vfs.zig").Vfs;

pub const NativeVfs = struct {
    io: std.Io,

    pub fn init(io: std.Io) NativeVfs {
        return .{ .io = io };
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

    fn makePath(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, path);
    }

    fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        const file = try cwd.openFile(self.io, path, .{});
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const file_size: usize = @intCast(stat.size);

        const buffer = try allocator.alloc(u8, file_size);
        const bytes_read = try file.readStreaming(self.io, &.{buffer});
        if (bytes_read != file_size) return error.RuntimeError;

        return buffer;
    }

    fn writeFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = data });
    }

    fn hardLink(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        try cwd.hardLink(old_path, cwd, new_path, self.io, .{});
    }

    fn symLink(ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void {
        const self: *NativeVfs = @ptrCast(@alignCast(ptr));
        const cwd = std.Io.Dir.cwd();
        try cwd.symLink(self.io, target_path, link_path, .{});
    }
};
