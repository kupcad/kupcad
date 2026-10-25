//! `ScriptSession`: evaluates a workspace of modules incrementally. It keeps each module's
//! output, the files its last run read as data and the reverse import graph, marks an
//! edited file (a module or a data file) and its importers stale, and evaluates only those
//! again, stopping early where an output's hash is unchanged. Used by the LSP, `kupcad
//! watch` and `kupcad build`. A `RunObserver` is told of each run while the VM still holds
//! what it left: the language server's preview makes its frame there.

const std = @import("std");
const workspace = @import("../frontend/workspace.zig");
const api = @import("../api.zig");
const ParamValues = api.ParamValues;
const common_errors = @import("../core/errors.zig");
const import_path = @import("../core/import_path.zig");
const import_kind = @import("../core/import_kind.zig");
const limits = @import("../core/limits.zig");
const exports_fingerprint = @import("exports_fingerprint.zig");
const chunk = @import("../vm/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../core/geometry_handle.zig");
const Stopwatch = @import("../core/stopwatch.zig").Stopwatch;
const VM = @import("../vm/vm.zig").VM;
const Vfs = @import("../vfs/vfs.zig").Vfs;
const RunWarning = @import("../vm/run_report.zig").Warning;

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
    /// The files the module's last run read as data (VM.files_read), owned: a change to one
    /// runs it again though its source is the same.
    files_read: std.ArrayList([]u8) = .empty,
    /// What the module's last run warned of (VM.report), each message owned: an editor
    /// shows them beside its lint findings.
    warnings: std.ArrayList(RunWarning) = .empty,
    /// It runs again though its source is the same: a file it read changed
    /// (ScriptSession.markDataFileEdited), its host wants what a run leaves
    /// (ScriptSession.runAgain), or its last run failed. Set as a run starts and cleared once
    /// it ran without an error, so a failed run runs again next time and isn't taken for its
    /// last output: not even when its source is back to the one that made that output.
    must_run: bool = false,

    pub fn deinit(self: *SessionNode, allocator: std.mem.Allocator) void {
        if (self.cached_handle) |h| kernel.destruct(h);
        self.cached_handle = null;
        self.forgetFilesRead(allocator);
        self.files_read.deinit(allocator);
        self.forgetWarnings(allocator);
        self.warnings.deinit(allocator);
    }

    fn forgetWarnings(self: *SessionNode, allocator: std.mem.Allocator) void {
        for (self.warnings.items) |w| allocator.free(w.message);
        self.warnings.clearRetainingCapacity();
    }

    /// Takes what `vm`'s run warned of as this module's, in place of the last run's.
    fn rememberWarnings(self: *SessionNode, allocator: std.mem.Allocator, vm: *const VM) !void {
        self.forgetWarnings(allocator);
        try self.warnings.ensureTotalCapacity(allocator, vm.report.warnings.items.len);
        for (vm.report.warnings.items) |w| {
            self.warnings.appendAssumeCapacity(.{ .message = try allocator.dupe(u8, w.message), .position = w.position });
        }
    }

    fn forgetFilesRead(self: *SessionNode, allocator: std.mem.Allocator) void {
        for (self.files_read.items) |path| allocator.free(path);
        self.files_read.clearRetainingCapacity();
    }

    /// Takes the files `vm`'s run read as this module's, in place of the last run's.
    fn rememberFilesRead(self: *SessionNode, allocator: std.mem.Allocator, vm: *const VM) !void {
        self.forgetFilesRead(allocator);
        try self.files_read.ensureTotalCapacity(allocator, vm.files_read.count());
        var paths = vm.files_read.keyIterator();
        while (paths.next()) |path| self.files_read.appendAssumeCapacity(try allocator.dupe(u8, path.*));
    }

    pub fn hasRead(self: *const SessionNode, path: []const u8) bool {
        for (self.files_read.items) |read| {
            if (std.mem.eql(u8, read, path)) return true;
        }
        return false;
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

/// A module's run, as the session's observer learns of it.
pub const ModuleRun = struct {
    path: []const u8,
    source: []const u8,
    /// The parse the run compiled.
    doc: *const api.Document,
    /// Holds what the run left, until the session goes on.
    vm: *VM,
    /// It ended without an error; else the VM's last error says why.
    ok: bool,
    /// How long it ran, in nanoseconds.
    run_ns: u64,
};

/// Told of every module the session runs, right after the run: the VM still holds what it
/// left (its last value, ghosts, materials and report), of which the session keeps only a
/// copy of the shape. It mustn't change the session.
pub const RunObserver = struct {
    context: *anyopaque,
    ran: *const fn (context: *anyopaque, run: ModuleRun) void,
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

    /// Values for `param(:name)`, such as `kupcad build -p` and `-P` give. Every evaluation
    /// injects them after registering the standard library, which makes a fresh `params` map
    /// (injecting once, before evaluating, used to be wiped by it).
    params: ParamValues = .{},

    observer: ?RunObserver = null,

    /// A session whose scripts read and write files through `files`: the disk for `kupcad
    /// build` and `watch`, the LSP's read-only sandbox, `.none` for no files at all.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, files: Vfs) !ScriptSession {
        var vm = try VM.init(allocator, io);
        vm.runs_many_scripts = true;
        vm.vfs = files;
        return .{
            .allocator = allocator,
            .workspace = Workspace.init(allocator),
            .vm = vm,
        };
    }

    /// Replaces the parameters with `params`, which the session takes: the caller's copy is
    /// emptied. They must have been made with the session's allocator. Any module may read
    /// them, so every module runs again at the next evaluation.
    pub fn setParams(self: *ScriptSession, params: *ParamValues) void {
        self.params.deinit(self.allocator);
        self.params = params.*;
        params.* = .{};
        self.global_revision += 1;
        for (self.nodes.items) |*node| {
            node.must_run = true;
            node.is_stale = true;
        }
    }

    pub fn deinit(self: *ScriptSession) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        var it = self.reverse_deps.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.reverse_deps.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.clearFailure();
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

    /// Adds to the workspace every module the loaded modules import or re-export from, read
    /// through the VM's file system (in the language server, the open documents first, then
    /// the disk), until none is missing, then links the dependencies. Only the root used to
    /// be in it, and its imports came from the VM's cache, so an edit to a module never
    /// showed. A file that can't be read (a package not installed, a missing one) or is too
    /// large to parse is left to the import to report.
    pub fn loadImports(self: *ScriptSession) !void {
        const ws = &self.workspace;
        var i: usize = 0;
        while (i < ws.modules.items.len) : (i += 1) {
            var wanted: std.ArrayList([]u8) = .empty;
            defer {
                for (wanted.items) |path| self.allocator.free(path);
                wanted.deinit(self.allocator);
            }
            {
                // The module slice may move when a module is added, so its imports are
                // gathered first.
                const mod = &ws.modules.items[i];
                for (mod.doc.tree.nodes.items) |*node| {
                    const reference = import_kind.referenceOf(&mod.doc.tree, node) orelse continue;
                    // A file it reads as data is watched once a run has read it
                    if (reference.kind != .module) continue;
                    const path = try import_path.resolve(self.allocator, mod.path, reference.path);
                    if (ws.path_to_id.contains(path)) {
                        self.allocator.free(path);
                        continue;
                    }
                    try wanted.append(self.allocator, path);
                }
            }
            for (wanted.items) |path| {
                if (ws.path_to_id.contains(path)) continue;
                const source = self.vm.vfs.readFile(self.allocator, path) catch continue;
                defer self.allocator.free(source);
                if (source.len > limits.MAX_SOURCE_BYTES) continue;
                _ = try ws.addModule(path, source);
            }
        }
        try ws.linkDependencies();
        try self.buildReverseGraph();
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

    /// Marks stale every module whose last run read the data file at `path` (`import_json`,
    /// `import_stl`), and their importers, so the next evaluation runs them again though
    /// their source is the same. False when no module read it.
    pub fn markDataFileEdited(self: *ScriptSession, path: []const u8) !bool {
        var found = false;
        for (self.nodes.items, 0..) |node, i| {
            if (!node.hasRead(path)) continue;
            try self.runAgain(self.workspace.modules.items[i].path);
            found = true;
        }
        return found;
    }

    /// Makes the module at `path` run at the next evaluation though nothing it reads changed
    /// (its importers run after it if its output changes): a host wants what a run leaves
    /// besides the output the session keeps (the language server's preview, its frame).
    pub fn runAgain(self: *ScriptSession, path: []const u8) !void {
        const id = self.workspace.path_to_id.get(path) orelse return error.UnknownModule;
        self.nodes.items[@backingInt(id)].must_run = true;
        try self.markFileEdited(path);
    }

    /// Forgets the module at `path` (an editor closed it): its cached output and its place in
    /// the import graph. Modules that imported it are evaluated again next time.
    pub fn removeModule(self: *ScriptSession, path: []const u8) !void {
        const id = self.workspace.path_to_id.get(path) orelse return;
        try self.markFileEdited(path);
        // Its importers import it afresh, not from the VM's cache
        self.vm.forgetModule(path);

        const index = @backingInt(id);
        // The workspace first: a removal that fails there leaves the nodes matching it
        _ = try self.workspace.removeModule(path);
        var node = self.nodes.orderedRemove(index);
        node.deinit(self.allocator);
        if (self.failure) |*failure| {
            const failed = @backingInt(failure.module);
            if (failed == index) self.clearFailure() else if (failed > index) failure.module = @fromBackingInt(failed - 1);
        }
        try self.buildReverseGraph();
    }

    /// Step 3: Lazy Re-evaluation & Early Cutoff (Pull Phase)
    pub fn evaluateWorkspace(self: *ScriptSession) !void {
        // A `cancel` from before this evaluation doesn't stop it.
        self.vm.cancel_token.store(false, .release);
        return self.evaluateModules(null);
    }

    /// Evaluates the module at `path` and the modules it imports, the rest staying as they
    /// are: the language server shows one document of the many open, and one that doesn't
    /// parse stopped another's preview. An earlier `cancel` isn't cleared first, for a host
    /// that clears it itself under the lock it cancels under, so a cancel can't fall in
    /// between and be lost (the LSP's inbox). A cancelled evaluation leaves the rest stale.
    pub fn evaluateWithImports(self: *ScriptSession, path: []const u8) !void {
        const id = self.workspace.path_to_id.get(path) orelse return error.UnknownModule;
        var needed = try self.withImports(id);
        defer needed.deinit(self.allocator);
        return self.evaluateModules(&needed);
    }

    /// Evaluates the modules, dependencies first: those in `only` (by index), or all.
    fn evaluateModules(self: *ScriptSession, only: ?*const std.bit_set.Dynamic) !void {
        self.clearFailure();

        const sorted = try self.workspace.sortModules();
        defer self.allocator.free(sorted);

        for (sorted) |mod_id| {
            if (only) |needed| if (!needed.isSet(@backingInt(mod_id))) continue;
            try self.evaluateModule(mod_id);
        }
    }

    /// The indices of the module `id` and of every module it imports, directly or not.
    fn withImports(self: *ScriptSession, id: ModuleId) !std.bit_set.Dynamic {
        var found = try std.bit_set.Dynamic.initEmpty(self.allocator, self.workspace.modules.items.len);
        errdefer found.deinit(self.allocator);
        var pending: std.ArrayList(ModuleId) = .empty;
        defer pending.deinit(self.allocator);
        try pending.append(self.allocator, id);
        while (pending.pop()) |current| {
            const index = @backingInt(current);
            if (found.isSet(index)) continue;
            found.set(index);
            try pending.appendSlice(self.allocator, self.workspace.modules.items[index].deps.items);
        }
        return found;
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
        if (node.source_hash != current_source_hash or node.must_run) {
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

        // Until it runs without an error: whatever stops it (a parse, a compile, the run, its
        // output) leaves it to run next time, its source the same as its last output's or not
        node.must_run = true;

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
        // The module runs as on a VM of its own: the names another module's run defined,
        // or its own last run's, aren't its
        self.vm.forgetScriptGlobals();
        try registry.registerStandardLibrary(&self.vm);
        try api.injectParams(&self.vm, &self.params);

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
        var clock = Stopwatch.start(self.vm.io);
        const result = self.vm.interpret(&out_chunk);
        const run_ns = clock.lap();
        // A failed run is watched too: fixing the file it couldn't read runs it again
        try node.rememberFilesRead(self.allocator, &self.vm);
        try node.rememberWarnings(self.allocator, &self.vm);
        if (self.observer) |o| o.ran(o.context, .{ .path = mod.path, .source = mod.source, .doc = &doc, .vm = &self.vm, .ok = result == .ok, .run_ns = run_ns });
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

        const new_hash = try self.fingerprintOutput(new_handle, mod);

        if (new_hash == node.output_hash and node.output_hash != 0) {
            // Output unchanged: keep the existing copy, drop the fresh one.
            if (new_handle) |h| kernel.destruct(h);
            node.verified_at = self.global_revision;
            node.source_hash = current_source_hash;
            node.must_run = false;
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
        node.must_run = false;
        node.is_stale = false;
    }

    /// What the viewport would show for this output and what importers see of it: the
    /// mesh of the result and of every ghost (positions and material slots), the
    /// materials, and the module's exports (exports_fingerprint.zig). The fingerprint was
    /// the bounding box and volume alone, so a colour change, a hole moved inside the part
    /// or a symmetric rotation never reached the viewport. A shape an engine can't mesh yet
    /// is fingerprinted by the source instead, which hides nothing. A module without a
    /// shape was fingerprinted by its source alone, so one that re-exports, or exports what
    /// it computed from an import, never passed a change of its import on.
    fn fingerprintOutput(self: *ScriptSession, handle: ?geom.GeometryHandle, mod: *const workspace.Module) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        var unmeshed = false;
        if (handle) |h| unmeshed = !try kernel.hashMesh(&hasher, self.allocator, h);
        for (self.vm.display_list.items) |ghost| {
            if (!try kernel.hashMesh(&hasher, self.allocator, ghost)) unmeshed = true;
        }
        if (unmeshed) hasher.update(mod.source);
        for (self.vm.materials.items) |mat| mat.hashInto(&hasher);
        // An export not hashed by content changed: this evaluation is its revision
        if (mod.exports.count() > 0 and !exports_fingerprint.hashExports(&hasher, &self.vm)) {
            hasher.update(std.mem.asBytes(&self.global_revision));
        }
        return hasher.final();
    }

    pub fn cancel(self: *ScriptSession) void {
        self.vm.cancel_token.store(true, .release);
    }
};
