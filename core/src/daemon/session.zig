const std = @import("std");
const workspace = @import("../core/workspace.zig");
const api = @import("../api.zig");
const chunk = @import("../vm/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../kernel/geometry_handle.zig");
const VM = @import("../vm/vm.zig").VM;

const Workspace = workspace.Workspace;
const ModuleId = workspace.ModuleId;

const log = std.log.scoped(.session);

pub const SessionNode = struct {
    verified_at: u64 = 0,
    changed_at: u64 = 0,
    output_hash: u64 = 0,
    is_stale: bool = true,
    cached_handle: ?geom.GeometryHandle = null,

    pub fn deinit(self: *SessionNode) void {
        // Ownership remains with the VM's Garbage Collector.
        // We only clear the reference.
        self.cached_handle = null;
    }
};

pub const ScriptSession = struct {
    allocator: std.mem.Allocator,
    workspace: Workspace,
    vm: VM,
    global_revision: u64 = 1,

    // Parallel array to Workspace.modules tracking runtime cache state
    nodes: std.ArrayListUnmanaged(SessionNode) = .empty,

    // Reverse Adjacency List: ModuleId -> Parent ModuleIds
    reverse_deps: std.AutoHashMapUnmanaged(ModuleId, std.ArrayListUnmanaged(ModuleId)) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ScriptSession {
        return .{
            .allocator = allocator,
            .workspace = Workspace.init(allocator),
            .vm = try VM.init(allocator, io),
        };
    }

    pub fn deinit(self: *ScriptSession) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        var it = self.reverse_deps.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.reverse_deps.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.workspace.deinit();
        self.vm.deinit();
    }

    /// Step 1: Import Graph Construction
    pub fn buildReverseGraph(self: *ScriptSession) !void {
        while (self.nodes.items.len < self.workspace.modules.items.len) {
            try self.nodes.append(self.allocator, .{});
        }

        var it = self.reverse_deps.iterator();
        while (it.next()) |entry| entry.value_ptr.clearRetainingCapacity();

        for (self.workspace.modules.items) |mod| {
            for (mod.deps.items) |dep_id| {
                const gop = try self.reverse_deps.getOrPut(self.allocator, dep_id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, mod.id);
            }
        }
    }

    /// Step 2: Selective Invalidation Pass (Reverse BFS)
    pub fn markFileEdited(self: *ScriptSession, path: []const u8) !void {
        const root_id = self.workspace.path_to_id.get(path) orelse return error.UnknownModule;

        self.global_revision += 1;

        var queue = std.ArrayListUnmanaged(ModuleId).empty;
        defer queue.deinit(self.allocator);

        try queue.append(self.allocator, root_id);

        while (queue.pop()) |current_id| {
            var node = &self.nodes.items[@intFromEnum(current_id)];
            if (node.is_stale) continue;

            node.is_stale = true;

            if (self.reverse_deps.get(current_id)) |parents| {
                for (parents.items) |p_id| try queue.append(self.allocator, p_id);
            }
        }
    }

    /// Step 3: Lazy Re-evaluation & Early Cutoff (Pull Phase)
    pub fn evaluateModule(self: *ScriptSession, mod_id: ModuleId) !void {
        var node = &self.nodes.items[@intFromEnum(mod_id)];

        if (!node.is_stale and node.verified_at == self.global_revision) return; // Cache hit

        const mod = &self.workspace.modules.items[@intFromEnum(mod_id)];

        for (mod.deps.items) |dep_id| {
            try self.evaluateModule(dep_id);
        }

        var doc = api.Document.parse(self.allocator, mod.source) catch |err| {
            log.err("Parse failed for module '{s}': {}", .{ mod.path, err });
            return err;
        };
        defer doc.deinit();

        if (doc.diagnostics.len > 0) return error.ParseError;

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(self.allocator);

        self.vm.line_index = &doc.line_index;
        try registry.registerStandardLibrary(&self.vm);

        var comp = Compiler.init(self.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &self.vm);
        defer comp.deinit();

        try comp.compile(doc.tree.root);

        const result = self.vm.interpret(&out_chunk);
        if (result != .ok) return error.RuntimeError;

        var new_handle: ?geom.GeometryHandle = null;
        if (self.vm.stack_top > 0) {
            const final_val = self.vm.stack[0];
            if (final_val.isGeometry()) {
                new_handle = try self.vm.ensureConcrete(final_val);
            }
        } else if (self.vm.display_list.items.len > 0) {
            new_handle = self.vm.display_list.items[self.vm.display_list.items.len - 1];
        }

        var hasher = std.hash.Wyhash.init(0);
        if (new_handle) |h| {
            if (kernel.boundingBox(h)) |bbox| {
                hasher.update(std.mem.asBytes(&bbox.min));
                hasher.update(std.mem.asBytes(&bbox.max));
            }
            const vol = kernel.volume(h);
            hasher.update(std.mem.asBytes(&vol));
        } else {
            hasher.update(mod.source);
        }
        const new_hash = hasher.final();

        if (new_hash == node.output_hash and node.output_hash != 0) {
            // Output geometry is topologically identical! Halt downstream propagation.
            node.verified_at = self.global_revision;
            node.is_stale = false;
            return;
        }

        node.cached_handle = new_handle;
        node.output_hash = new_hash;
        node.changed_at = self.global_revision;
        node.verified_at = self.global_revision;
        node.is_stale = false;
    }
};
