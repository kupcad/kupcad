//! `MemoryVfs`: a `Vfs` held in memory (files, directories and symlinks), for the LSP's
//! open documents, the WASM build and tests.

const std = @import("std");
const Vfs = @import("vfs.zig").Vfs;
const owned_keys = @import("../core/owned_keys.zig");

pub const NodeKind = enum { file, directory, symlink };

/// A path's node: its content (a file's bytes, a symlink's target) its own.
pub const MemoryNode = struct {
    kind: NodeKind,
    content: ?[]const u8 = null,
};

pub const MemoryVfs = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(MemoryNode),

    pub fn init(allocator: std.mem.Allocator) MemoryVfs {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(MemoryNode).init(allocator),
        };
    }

    pub fn deinit(self: *MemoryVfs) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.content) |c| self.allocator.free(c);
            self.allocator.free(entry.key_ptr.*);
        }
        self.nodes.deinit();
    }

    /// Removes the file at `path` (the LSP drops a document the editor closed); false if
    /// there is none.
    pub fn deleteFile(self: *MemoryVfs, path: []const u8) bool {
        const entry = self.nodes.fetchRemove(path) orelse return false;
        if (entry.value.content) |c| self.allocator.free(c);
        self.allocator.free(entry.key);
        return true;
    }

    /// Puts `node` at `path`, which gets its own copy of the path when new; what was there
    /// is freed (a link onto an existing path leaked its content and the new path copy).
    fn replaceNode(self: *MemoryVfs, path: []const u8, node: MemoryNode) !void {
        const gop = try owned_keys.getOrPutOwned(&self.nodes, self.allocator, path);
        const old: ?MemoryNode = if (gop.found_existing) gop.value_ptr.* else null;
        gop.value_ptr.* = node;
        if (old) |o| if (o.content) |c| self.allocator.free(c);
    }

    pub fn vfs(self: *MemoryVfs) Vfs {
        return .{
            .ptr = self,
            .vtable = &.{
                .makePath = makePath,
                .readFile = readFile,
                .writeFile = writeFile,
                .symLink = symLink,
            },
        };
    }

    fn makePath(ptr: *anyopaque, path: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        if (self.nodes.contains(path)) return;

        const path_dup = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_dup);

        try self.nodes.put(path_dup, .{ .kind = .directory });
    }

    fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const node = self.nodes.get(path) orelse return error.FileNotFound;
        if (node.kind != .file or node.content == null) return error.AccessDenied;
        return try allocator.dupe(u8, node.content.?);
    }

    /// Writes `data` at `path`. A path hard-linked to another gets content of its own
    /// (the other keeps what they shared).
    fn writeFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const data_dup = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_dup);
        try self.replaceNode(path, .{ .kind = .file, .content = data_dup });
    }

    fn symLink(ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const target_dup = try self.allocator.dupe(u8, target_path);
        errdefer self.allocator.free(target_dup);
        try self.replaceNode(link_path, .{ .kind = .symlink, .content = target_dup });
    }
};
