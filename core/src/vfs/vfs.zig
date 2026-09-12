const std = @import("std");

pub const Vfs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        makePath: *const fn (ptr: *anyopaque, path: []const u8) anyerror!void,
        readFile: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
        writeFile: *const fn (ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void,
        hardLink: *const fn (ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void,
        symLink: *const fn (ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void,
    };

    pub inline fn makePath(self: Vfs, path: []const u8) !void {
        return self.vtable.makePath(self.ptr, path);
    }

    pub inline fn readFile(self: Vfs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.vtable.readFile(self.ptr, allocator, path);
    }

    pub inline fn writeFile(self: Vfs, path: []const u8, data: []const u8) !void {
        return self.vtable.writeFile(self.ptr, path, data);
    }

    pub inline fn hardLink(self: Vfs, old_path: []const u8, new_path: []const u8) !void {
        return self.vtable.hardLink(self.ptr, old_path, new_path);
    }

    pub inline fn symLink(self: Vfs, target_path: []const u8, link_path: []const u8) !void {
        return self.vtable.symLink(self.ptr, target_path, link_path);
    }
};
