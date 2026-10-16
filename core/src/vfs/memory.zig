const std = @import("std");
const Vfs = @import("vfs.zig").Vfs;

pub const NodeKind = enum { file, directory, symlink };

pub const MemoryNode = struct {
    kind: NodeKind,
    content: ?[]const u8 = null,
    nlink: u32 = 1,
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
            if (entry.value_ptr.content) |c| {
                // Content hard links share is freed by the last node holding it; nothing
                // here allocates (a tracking map used to, and panicked when it couldn't).
                entry.value_ptr.content = null;
                self.releaseContent(c);
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.nodes.deinit();
    }

    /// Removes the file at `path` (the LSP drops a document the editor closed); false if
    /// there is none. Content a hard link still shares is kept for it.
    pub fn deleteFile(self: *MemoryVfs, path: []const u8) bool {
        const entry = self.nodes.fetchRemove(path) orelse return false;
        if (entry.value.content) |c| self.releaseContent(c);
        self.allocator.free(entry.key);
        return true;
    }

    /// Frees `content` unless a node still shares it (a hard link).
    fn releaseContent(self: *MemoryVfs, content: []const u8) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (node.content) |other| if (other.ptr == content.ptr) return;
        }
        self.allocator.free(content);
    }

    /// Puts `node` at `path`, which gets its own copy of the path when new. What was
    /// there is released first, unless a hard link still shares its content: a write
    /// over a linked path freed the content under the other link, and a link onto an
    /// existing path leaked both the old node's content and the new path copy.
    fn replaceNode(self: *MemoryVfs, path: []const u8, node: MemoryNode) !void {
        const gop = try self.nodes.getOrPut(path);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            gop.value_ptr.* = node;
            if (old.content) |c| self.releaseContent(c);
            return;
        }
        gop.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
            self.nodes.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = node;
    }

    pub fn vfs(self: *MemoryVfs) Vfs {
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

    fn hardLink(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const source_node = self.nodes.getPtr(old_path) orelse return error.FileNotFound;
        source_node.nlink += 1;
        try self.replaceNode(new_path, source_node.*);
    }

    fn symLink(ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const target_dup = try self.allocator.dupe(u8, target_path);
        errdefer self.allocator.free(target_dup);
        try self.replaceNode(link_path, .{ .kind = .symlink, .content = target_dup });
    }
};
