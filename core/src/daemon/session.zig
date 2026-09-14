const std = @import("std");
const workspace = @import("../core/workspace.zig");
const VM = @import("../vm/vm.zig").VM;
const Workspace = workspace.Workspace;
const ModuleId = workspace.ModuleId;

pub const SessionNode = struct {
    verified_at: u64 = 0,
    changed_at: u64 = 0,
    output_hash: u64 = 0,
    is_stale: bool = true,
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
        var it = self.reverse_deps.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.reverse_deps.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.workspace.deinit();
        self.vm.deinit();
    }

    /// Step 1: Import Graph Construction
    pub fn buildReverseGraph(self: *ScriptSession) !void {
        // Ensure our metadata array aligns with the Workspace module count
        while (self.nodes.items.len < self.workspace.modules.items.len) {
            try self.nodes.append(self.allocator, .{});
        }

        // Clear previous edges
        var it = self.reverse_deps.iterator();
        while (it.next()) |entry| entry.value_ptr.clearRetainingCapacity();

        // Invert the forward dependencies extracted from the AST
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

        // BFS up the reverse dependency graph to mark parents as stale
        while (queue.pop()) |current_id| {
            var node = &self.nodes.items[@intFromEnum(current_id)];
            if (node.is_stale) continue; // Already marked

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

        // Post-Order traversal: Ensure dependencies are evaluated first
        for (mod.deps.items) |dep_id| {
            try self.evaluateModule(dep_id);
        }

        // [Execution Logic goes here: Compile and VM Interpret]
        // Example: Hash the resulting wyhash of the executed module
        const new_hash: u64 = 0; // Placeholder for executed value digest

        if (new_hash == node.output_hash) {
            // THE EARLY CUTOFF: Output didn't change! Halt trace.
            node.verified_at = self.global_revision;
            node.is_stale = false;
            return;
        }

        // Output changed. Propagate.
        node.output_hash = new_hash;
        node.changed_at = self.global_revision;
        node.verified_at = self.global_revision;
        node.is_stale = false;
    }
};
