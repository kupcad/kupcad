//! `ScriptSession`: evaluates a workspace of modules incrementally. It keeps each module's
//! output and the reverse import graph, marks an edited file and its importers stale, and
//! evaluates only those again, stopping early where an output's hash is unchanged. Used by
//! the LSP, `kupcad watch` and `kupcad build`.

const std = @import("std");
const workspace = @import("../core/workspace.zig");
const api = @import("../api.zig");
const common_errors = @import("../core/errors.zig");
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
    source_hash: u64 = 0,
    is_stale: bool = true,
    /// OWNED copy of the module's output. Handles from ensureConcrete / the
    /// display list are borrowed (vm.dag_cache or VM own them), so the session
    /// clones before storing and destroys only its own clones.
    cached_handle: ?geom.GeometryHandle = null,

    pub fn deinit(self: *SessionNode) void {
        if (self.cached_handle) |h| kernel.destruct(h);
        self.cached_handle = null;
    }
};

/// A module whose source has errors: syntax errors, ones the resolver finds (such as
/// `break` outside a loop) or a compile error (such as assigning to `cube`). The session
/// owns `diagnostics` and their messages; the workspace's own parse of a module skips the
/// resolver, so it can't report these itself.
pub const Failure = struct {
    module: ModuleId,
    diagnostics: []common_errors.Diagnostic,
};

pub const ScriptSession = struct {
    allocator: std.mem.Allocator,
    workspace: Workspace,
    vm: VM,
    global_revision: u64 = 1,

    // Parallel array to Workspace.modules tracking runtime cache state
    nodes: std.ArrayList(SessionNode) = .empty,

    // Reverse Adjacency List: ModuleId -> Parent ModuleIds
    reverse_deps: std.AutoHashMapUnmanaged(ModuleId, std.ArrayList(ModuleId)) = .empty,

    /// What stopped the last evaluation with error.ParseError or error.CompileError, so
    /// callers can show it.
    failure: ?Failure = null,

    /// Values for `param(:name)`, such as `kupcad build --param`. Owned, keys included.
    /// Every evaluation injects them after registering the standard library, which makes
    /// a fresh `params` map (injecting once, before evaluating, used to be wiped by it).
    params: std.StringHashMapUnmanaged(f64) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !ScriptSession {
        var vm = try VM.init(allocator, io);
        vm.runs_many_scripts = true;
        return .{
            .allocator = allocator,
            .workspace = Workspace.init(allocator),
            .vm = vm,
        };
    }

    /// Replaces the parameters with copies of `params`.
    pub fn setParams(self: *ScriptSession, params: std.StringHashMapUnmanaged(f64)) !void {
        self.clearParams();
        try self.params.ensureTotalCapacity(self.allocator, params.count());
        var it = params.iterator();
        while (it.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.key_ptr.*);
            self.params.putAssumeCapacity(name, entry.value_ptr.*);
        }
    }

    fn clearParams(self: *ScriptSession) void {
        var it = self.params.keyIterator();
        while (it.next()) |name| self.allocator.free(name.*);
        self.params.clearRetainingCapacity();
    }

    pub fn deinit(self: *ScriptSession) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        var it = self.reverse_deps.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.reverse_deps.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.clearFailure();
        self.clearParams();
        self.params.deinit(self.allocator);
        self.workspace.deinit();
        self.vm.deinit();
    }

    fn clearFailure(self: *ScriptSession) void {
        const failure = self.failure orelse return;
        for (failure.diagnostics) |d| self.allocator.free(d.message);
        self.allocator.free(failure.diagnostics);
        self.failure = null;
    }

    /// Replaces the failure with copies of `diagnostics` (which belong to a Document or a
    /// Compiler about to go away).
    fn setFailure(self: *ScriptSession, module: ModuleId, diagnostics: []const common_errors.Diagnostic) !void {
        self.clearFailure();
        const copies = try self.allocator.alloc(common_errors.Diagnostic, diagnostics.len);
        var copied: usize = 0;
        errdefer {
            for (copies[0..copied]) |d| self.allocator.free(d.message);
            self.allocator.free(copies);
        }
        for (diagnostics, copies) |d, *copy| {
            copy.* = .{ .loc = d.loc, .code = d.code, .message = try self.allocator.dupe(u8, d.message) };
            copied += 1;
        }
        self.failure = .{ .module = module, .diagnostics = copies };
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

        var queue = std.ArrayList(ModuleId).empty;
        defer queue.deinit(self.allocator);

        try queue.append(self.allocator, root_id);

        while (queue.pop()) |current_id| {
            var node = &self.nodes.items[@backingInt(current_id)];
            if (node.is_stale) continue;

            node.is_stale = true;

            if (self.reverse_deps.get(current_id)) |parents| {
                for (parents.items) |p_id| try queue.append(self.allocator, p_id);
            }
        }
    }

    /// Forgets the module at `path` (an editor closed it): its cached output and its place in
    /// the import graph. Modules that imported it are evaluated again next time.
    pub fn removeModule(self: *ScriptSession, path: []const u8) !void {
        const id = self.workspace.path_to_id.get(path) orelse return;
        try self.markFileEdited(path);

        const index = @backingInt(id);
        var node = self.nodes.orderedRemove(index);
        node.deinit();
        if (self.failure) |*failure| {
            const failed = @backingInt(failure.module);
            if (failed == index) self.clearFailure() else if (failed > index) failure.module = @fromBackingInt(failed - 1);
        }
        _ = try self.workspace.removeModule(path);
        try self.buildReverseGraph();
    }

    /// Step 3: Lazy Re-evaluation & Early Cutoff (Pull Phase)
    pub fn evaluateWorkspace(self: *ScriptSession) !void {
        // A `cancel` from before this evaluation doesn't stop it.
        self.vm.cancel_token.store(false, .release);
        return self.evaluateUntilCancelled();
    }

    /// `evaluateWorkspace` without clearing an earlier `cancel` first, for a host that clears
    /// it itself under the lock it cancels under, so a cancel can't fall in between and be
    /// lost (the LSP's inbox). A cancelled evaluation leaves the rest of the modules stale.
    pub fn evaluateUntilCancelled(self: *ScriptSession) !void {
        self.clearFailure();

        const sorted = try self.workspace.sortModules();
        defer self.allocator.free(sorted);

        for (sorted) |mod_id| {
            try self.evaluateModule(mod_id);
        }
    }

    pub fn evaluateModule(self: *ScriptSession, mod_id: ModuleId) !void {
        var node = &self.nodes.items[@backingInt(mod_id)];

        if (!node.is_stale and node.verified_at == self.global_revision) return; // Cache hit

        const mod = &self.workspace.modules.items[@backingInt(mod_id)];

        // --- Topological Recompilation Check ---
        var s_hasher = std.hash.Wyhash.init(0);
        s_hasher.update(mod.source);
        const current_source_hash = s_hasher.final();

        var needs_recompile = false;
        if (node.source_hash != current_source_hash) {
            needs_recompile = true;
        } else if (node.output_hash == 0) {
            needs_recompile = true;
        } else {
            for (mod.deps.items) |dep_id| {
                const dep_node = &self.nodes.items[@backingInt(dep_id)];
                // If the dependency changed AFTER this module was last verified, we must recompile
                if (dep_node.changed_at > node.verified_at) {
                    needs_recompile = true;
                    break;
                }
            }
        }

        if (!needs_recompile) {
            node.verified_at = self.global_revision;
            node.is_stale = false;
            return;
        }
        // --------------------------------------------

        var doc = api.Document.parse(self.allocator, mod.source) catch |err| {
            log.err("Parse failed for module '{s}': {}", .{ mod.path, err });
            return err;
        };
        defer doc.deinit();
        if (doc.diagnostics.len > 0) {
            try self.setFailure(mod_id, doc.diagnostics);
            return error.ParseError;
        }

        var out_chunk = chunk.Chunk.init();
        defer out_chunk.free(self.allocator);

        self.vm.line_index = &doc.line_index;
        // The Document goes away with this call; the pointer used to outlive it.
        defer self.vm.line_index = null;
        try registry.registerStandardLibrary(&self.vm);
        try api.injectParamsIntoVm(&self.vm, self.params);

        var comp = Compiler.forDocument(self.allocator, &doc, &out_chunk, &self.vm);
        defer comp.deinit();
        comp.module_path = mod.path;
        // Modules importing this one read it through the VM's import cache, which would
        // keep serving its old exports.
        self.vm.forgetModule(mod.path);

        comp.compile(doc.tree.root) catch |err| {
            const diagnostic = comp.errorDiagnostic() orelse return err;
            try self.setFailure(mod_id, &.{diagnostic});
            return error.CompileError;
        };

        self.vm.resetRunOutput();
        const result = self.vm.interpret(&out_chunk);
        if (result != .ok) return error.RuntimeError;

        // Borrowed: owned by vm.dag_cache (ensureConcrete) or by vm.display_list.
        var borrowed_handle: ?geom.GeometryHandle = null;
        if (self.vm.stack_top > 0) {
            const final_val = self.vm.stack[0];
            if (final_val.isGeometry()) {
                borrowed_handle = try self.vm.ensureConcrete(final_val);
            }
        } else if (self.vm.display_list.items.len > 0) {
            borrowed_handle = self.vm.display_list.items[self.vm.display_list.items.len - 1];
        }
        // Take our own copy: the cache may evict the borrowed one on the next GC.
        const new_handle: ?geom.GeometryHandle = if (borrowed_handle) |h|
            (kernel.clone(h) orelse return error.RuntimeError)
        else
            null;
        errdefer if (new_handle) |h| kernel.destruct(h);

        const new_hash = try self.fingerprintOutput(new_handle, mod.source);

        if (new_hash == node.output_hash and node.output_hash != 0) {
            // Output unchanged: keep the existing copy, drop the fresh one.
            if (new_handle) |h| kernel.destruct(h);
            node.verified_at = self.global_revision;
            node.source_hash = current_source_hash;
            node.is_stale = false;
            return;
        }

        if (node.cached_handle) |old_h| {
            kernel.destruct(old_h);
        }
        node.cached_handle = new_handle;
        node.output_hash = new_hash;
        node.source_hash = current_source_hash;
        node.changed_at = self.global_revision;
        node.verified_at = self.global_revision;
        node.is_stale = false;
    }

    /// What the viewport would show for this output: the mesh of the result and of
    /// every ghost (positions and material slots), and the materials. The fingerprint
    /// was the bounding box and volume alone, so a colour change, a hole moved inside
    /// the part or a symmetric rotation never reached the viewport. An engine that
    /// can't mesh yet is fingerprinted by the source instead, which hides nothing.
    fn fingerprintOutput(self: *ScriptSession, handle: ?geom.GeometryHandle, source: []const u8) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        var meshed = false;
        if (handle) |h| meshed = try kernel.hashMesh(&hasher, self.allocator, h);
        for (self.vm.display_list.items) |ghost| {
            if (try kernel.hashMesh(&hasher, self.allocator, ghost)) meshed = true;
        }
        if (!meshed) hasher.update(source);
        for (self.vm.materials.items) |mat| mat.hashInto(&hasher);
        return hasher.final();
    }

    pub fn cancel(self: *ScriptSession) void {
        self.vm.cancel_token.store(true, .release);
    }
};
