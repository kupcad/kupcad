const std = @import("std");
const ast = @import("ast.zig");
const Document = @import("document.zig").Document;

pub const ModuleId = enum(u32) { _ };

pub const Module = struct {
    id: ModuleId,
    path: []const u8,
    source: []const u8,
    doc: Document,
    deps: std.ArrayListUnmanaged(ModuleId) = .empty,
    // Maps the string representation of an exported symbol to its original AST NodeIndex
    exports: std.StringHashMapUnmanaged(ast.StringId) = .empty,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        self.doc.deinit();
        self.deps.deinit(allocator);
        self.exports.deinit(allocator);
    }
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayListUnmanaged(Module) = .empty,
    path_to_id: std.StringHashMapUnmanaged(ModuleId) = .empty,

    pub fn init(allocator: std.mem.Allocator) Workspace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.modules.items) |*mod| {
            mod.deinit(self.allocator);
        }
        self.modules.deinit(self.allocator);
        self.path_to_id.deinit(self.allocator);
    }

    /// Adds a raw module to the workspace. (File I/O is handled by the caller to remain WASM compatible)
    pub fn addModule(self: *Workspace, path: []const u8, source: []const u8) !ModuleId {
        if (self.path_to_id.get(path)) |existing_id| return existing_id;

        const doc = try Document.parseRaw(self.allocator, source);
        const id: ModuleId = @enumFromInt(self.modules.items.len);

        try self.modules.append(self.allocator, .{
            .id = id,
            .path = try self.allocator.dupe(u8, path),
            .source = try self.allocator.dupe(u8, source),
            .doc = doc,
        });

        try self.path_to_id.put(self.allocator, self.modules.items[@intFromEnum(id)].path, id);
        return id;
    }

    /// O(N) Flat-array scan to extract dependencies natively from the AST
    pub fn linkDependencies(self: *Workspace) !void {
        for (self.modules.items) |*mod| {
            mod.deps.clearRetainingCapacity();
            mod.exports.clearRetainingCapacity();

            for (mod.doc.tree.nodes.items) |*node| {
                if (node.tag == .import_stmt) {
                    const import_stmt = mod.doc.tree.importStmt(node);
                    const dep_path = mod.doc.tree.getString(import_stmt.path);

                    if (self.path_to_id.get(dep_path)) |dep_id| {
                        try mod.deps.append(self.allocator, dep_id);
                    }
                } else if (node.tag == .export_stmt) {
                    const export_stmt = mod.doc.tree.exportStmt(node);
                    const symbols = mod.doc.tree.getAliasPairs(export_stmt.symbols);

                    for (symbols) |sym| {
                        const alias_str = mod.doc.tree.getString(sym.alias);
                        try mod.exports.put(self.allocator, alias_str, sym.original);
                    }
                }
            }
        }
    }

    /// Kahn's Algorithm: Topologically sorts modules from Leaf (no dependencies) to Root.
    pub fn sortModules(self: *Workspace) ![]const ModuleId {
        const count = self.modules.items.len;

        var unmet_deps = try self.allocator.alloc(u32, count);
        defer self.allocator.free(unmet_deps);

        var dependents = try self.allocator.alloc(std.ArrayListUnmanaged(ModuleId), count);
        defer {
            for (dependents) |*list| list.deinit(self.allocator);
            self.allocator.free(dependents);
        }
        @memset(dependents, .empty);

        for (self.modules.items, 0..) |*mod, i| {
            unmet_deps[i] = @intCast(mod.deps.items.len);
            for (mod.deps.items) |dep_id| {
                try dependents[@intFromEnum(dep_id)].append(self.allocator, @enumFromInt(i));
            }
        }

        var queue = std.ArrayListUnmanaged(ModuleId).empty;
        defer queue.deinit(self.allocator);

        for (unmet_deps, 0..) |unmet, i| {
            if (unmet == 0) try queue.append(self.allocator, @enumFromInt(i));
        }

        var sorted = std.ArrayListUnmanaged(ModuleId).empty;
        errdefer sorted.deinit(self.allocator);

        while (queue.pop()) |u| {
            try sorted.append(self.allocator, u);

            for (dependents[@intFromEnum(u)].items) |v| {
                unmet_deps[@intFromEnum(v)] -= 1;
                if (unmet_deps[@intFromEnum(v)] == 0) {
                    try queue.append(self.allocator, v);
                }
            }
        }

        if (sorted.items.len != count) {
            return error.CircularDependency;
        }

        return sorted.toOwnedSlice(self.allocator);
    }
};
