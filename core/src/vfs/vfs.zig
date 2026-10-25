//! `Vfs`: the file system interface the VM and package manager write through, a pointer and
//! vtable for reading, writing, making directories and linking. Implemented by `native.zig`,
//! `memory.zig` and `readonly.zig`, and by `Vfs.none`, which has no files.

const std = @import("std");

pub const Vfs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// No files, and nothing can be written: what a VM reads and writes through until its
    /// host gives it a file system, so a host that gives none lets a script touch no disk.
    /// A read finds nothing (error.FileNotFound); a write or a link is refused
    /// (error.AccessDenied).
    pub const none: Vfs = .{ .ptr = &None.state, .vtable = &None.vtable };

    pub const VTable = struct {
        makePath: *const fn (ptr: *anyopaque, path: []const u8) anyerror!void,
        readFile: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
        writeFile: *const fn (ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void,
        symLink: *const fn (ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void,
        /// Hard links from a *trusted* absolute source (e.g. the global CAFS store,
        /// which lives outside the sandbox root) to a sandboxed destination.
        /// Optional: backends without a physical filesystem leave it null.
        hardLinkTrusted: ?*const fn (ptr: *anyopaque, trusted_abs_source: []const u8, new_path: []const u8) anyerror!void = null,
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

    /// Never pass a path derived from untrusted input as `trusted_abs_source`;
    /// only the destination is sandbox-checked.
    pub inline fn hardLinkTrusted(self: Vfs, trusted_abs_source: []const u8, new_path: []const u8) !void {
        const f = self.vtable.hardLinkTrusted orelse return error.OperationUnsupported;
        return f(self.ptr, trusted_abs_source, new_path);
    }

    pub inline fn symLink(self: Vfs, target_path: []const u8, link_path: []const u8) !void {
        return self.vtable.symLink(self.ptr, target_path, link_path);
    }
};

const None = struct {
    /// What `Vfs.none` points at: it has no state, but a Vfs needs a pointer.
    var state: u8 = 0;

    const vtable: Vfs.VTable = .{
        .makePath = makePath,
        .readFile = readFile,
        .writeFile = writeFile,
        .symLink = link,
    };

    fn makePath(_: *anyopaque, _: []const u8) anyerror!void {
        return error.AccessDenied;
    }

    fn readFile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        return error.FileNotFound;
    }

    fn writeFile(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.AccessDenied;
    }

    fn link(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        return error.AccessDenied;
    }
};
