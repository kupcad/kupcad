const std = @import("std");

pub const VfsTag = enum { native, memory };

/// A Data-Oriented Virtual File System for WASM and Native execution.
pub const Vfs = struct {
    tag: VfsTag,
    memory_files: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn initNative() Vfs {
        return .{ .tag = .native };
    }

    pub fn initMemory() Vfs {
        return .{ .tag = .memory };
    }

    pub fn deinit(self: *Vfs, allocator: std.mem.Allocator) void {
        if (self.tag == .memory) {
            self.memory_files.deinit(allocator);
        }
    }

    pub fn putMemoryFile(self: *Vfs, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
        if (self.tag != .memory) return;
        try self.memory_files.put(allocator, path, content);
    }

    pub fn readFile(self: *Vfs, allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
        switch (self.tag) {
            .native => {
                const cwd = std.Io.Dir.cwd();
                const file = try cwd.openFile(io, path, .{});
                defer file.close(io);

                const stat = try file.stat(io);
                const file_size: usize = std.math.cast(usize, stat.size) orelse return error.OutOfMemory;

                const file_buf = try allocator.alloc(u8, file_size);
                errdefer allocator.free(file_buf);

                const bytes_read = try file.readStreaming(io, &.{file_buf});
                if (bytes_read != file_size) return error.RuntimeError;

                return file_buf;
            },
            .memory => {
                const content = self.memory_files.get(path) orelse return error.FileNotFound;
                return try allocator.dupe(u8, content);
            },
        }
    }

    pub fn writeFile(self: *Vfs, io: std.Io, path: []const u8, data: []const u8) !void {
        switch (self.tag) {
            .native => {
                const cwd = std.Io.Dir.cwd();
                try cwd.writeFile(io, .{
                    .sub_path = path,
                    .data = data,
                });
            },
            .memory => {
                return error.ReadOnlyFileSystem;
            },
        }
    }
};
