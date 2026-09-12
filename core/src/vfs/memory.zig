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
        // Track addresses we have already freed to prevent double-frees from hard links
        var freed_ptrs = std.AutoHashMap(usize, void).init(self.allocator);
        defer freed_ptrs.deinit();

        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.content) |c| {
                const ptr_val = @intFromPtr(c.ptr);
                if (!freed_ptrs.contains(ptr_val)) {
                    self.allocator.free(c);
                    freed_ptrs.put(ptr_val, {}) catch {};
                }
            }
            // Free the path string (key)
            self.allocator.free(entry.key_ptr.*);
        }
        self.nodes.deinit();
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
        const path_dup = try self.allocator.dupe(u8, path);
        try self.nodes.put(path_dup, .{ .kind = .directory });
    }

    fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const node = self.nodes.get(path) orelse return error.FileNotFound;
        if (node.kind != .file or node.content == null) return error.AccessDenied;
        return try allocator.dupe(u8, node.content.?);
    }

    fn writeFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const path_dup = try self.allocator.dupe(u8, path);
        const data_dup = try self.allocator.dupe(u8, data);
        try self.nodes.put(path_dup, .{ .kind = .file, .content = data_dup });
    }

    fn hardLink(ptr: *anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        var source_node = self.nodes.getPtr(old_path) orelse return error.FileNotFound;
        source_node.nlink += 1;
        const new_path_dup = try self.allocator.dupe(u8, new_path);
        try self.nodes.put(new_path_dup, source_node.*);
    }

    fn symLink(ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void {
        const self: *MemoryVfs = @ptrCast(@alignCast(ptr));
        const link_dup = try self.allocator.dupe(u8, link_path);
        const target_dup = try self.allocator.dupe(u8, target_path);
        try self.nodes.put(link_dup, .{ .kind = .symlink, .content = target_dup });
    }
};
