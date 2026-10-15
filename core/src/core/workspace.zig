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

    /// Adds a NEW raw module to the workspace. (File I/O is handled by the caller to remain WASM compatible)
    /// Returns error.DuplicateModule if the path is already registered: silently returning the
    /// existing id used to make callers believe their (new) source was stored when it was not.
    /// Use `upsertModule` / `updateModuleSource` to replace the source of a known module.
    pub fn addModule(self: *Workspace, path: []const u8, source: []const u8) !ModuleId {
        if (self.path_to_id.contains(path)) return error.DuplicateModule;

        const path_dup = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_dup);
        const source_dup = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_dup);

        var doc = try Document.parseRaw(self.allocator, source_dup);
        errdefer doc.deinit();

        const id: ModuleId = @fromBackingInt(@as(u32, @intCast(self.modules.items.len)));
        try self.path_to_id.ensureUnusedCapacity(self.allocator, 1);
        try self.modules.append(self.allocator, .{
            .id = id,
            .path = path_dup,
            .source = source_dup,
            .doc = doc,
        });

        self.path_to_id.putAssumeCapacity(path_dup, id);
        return id;
    }

    /// Replaces the source (and re-parses the AST) of an existing module.
    /// Callers must re-run `linkDependencies` afterwards since imports/exports may have changed.
    pub fn updateModuleSource(self: *Workspace, id: ModuleId, source: []const u8) !void {
        const mod = &self.modules.items[@backingInt(id)];

        const source_dup = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_dup);
        const doc = try Document.parseRaw(self.allocator, source_dup);

        // Only swap once everything succeeded so a failed update leaves the old state intact.
        self.allocator.free(mod.source);
        mod.doc.deinit();
        mod.source = source_dup;
        mod.doc = doc;
    }

    /// Adds the module if it is unknown, otherwise replaces its source. Used by the LSP and
    /// `kupcad watch` so edits are actually re-evaluated instead of hitting stale code.
    pub fn upsertModule(self: *Workspace, path: []const u8, source: []const u8) !ModuleId {
        if (self.path_to_id.get(path)) |id| {
            try self.updateModuleSource(id, source);
            return id;
        }
        return self.addModule(path, source);
    }

    /// Forgets the module at `path` (an editor closed it); false if it isn't known. The ids
    /// after it shift down by one, and dependencies are re-linked, so every id stays valid.
    pub fn removeModule(self: *Workspace, path: []const u8) !bool {
        const entry = self.path_to_id.fetchRemove(path) orelse return false;
        const index = @backingInt(entry.value);
        var removed = self.modules.orderedRemove(index);
        removed.deinit(self.allocator); // frees the path, which was the map's key
        for (self.modules.items[index..], index..) |*mod, i| {
            mod.id = @fromBackingInt(@as(u32, @intCast(i)));
            self.path_to_id.getPtr(mod.path).?.* = mod.id;
        }
        try self.linkDependencies();
        return true;
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
                try dependents[@backingInt(dep_id)].append(self.allocator, @fromBackingInt(@as(u32, @intCast(i))));
            }
        }

        var queue = std.ArrayListUnmanaged(ModuleId).empty;
        defer queue.deinit(self.allocator);

        for (unmet_deps, 0..) |unmet, i| {
            if (unmet == 0) try queue.append(self.allocator, @fromBackingInt(@as(u32, @intCast(i))));
        }

        var sorted = std.ArrayListUnmanaged(ModuleId).empty;
        errdefer sorted.deinit(self.allocator);

        while (queue.pop()) |u| {
            try sorted.append(self.allocator, u);

            for (dependents[@backingInt(u)].items) |v| {
                unmet_deps[@backingInt(v)] -= 1;
                if (unmet_deps[@backingInt(v)] == 0) {
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
