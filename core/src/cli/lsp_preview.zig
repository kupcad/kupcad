//! Where the language server runs scripts: the preview of the last edited document, which
//! the viewport shows, and the run its hovers read values from. `Preview` is what the
//! handler (lsp.zig) calls. `SessionPreview` does the work in this process, over a
//! `ScriptSession`; the server runs it in a worker process (lsp_worker.zig), so a run that
//! crashes (an abort in the C++ kernel, which no Zig code can catch) ends the worker, not
//! the server. Tests drive a `SessionPreview` directly.

const std = @import("std");
const api = @import("../api.zig");
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const kernel = @import("../kernel/kernel.zig");
const gltf = @import("../exporters/3d/gltf.zig");
const limits = @import("../core/limits.zig");
const registry = @import("../stdlib/registry.zig");
const VM = @import("../vm/vm.zig").VM;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const ScriptSession = @import("../daemon/session.zig").ScriptSession;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const ReadOnlyVfs = @import("../vfs/readonly.zig").ReadOnlyVfs;
const Vfs = @import("../vfs/vfs.zig").Vfs;

const logger = std.log.scoped(.lsp);

/// How a preview's evaluation ended.
pub const Outcome = union(enum) {
    /// The document's model as GLB, for the viewport (owned by the allocator passed).
    mesh: []u8,
    /// It ran, and left nothing the viewport can show (no solid, or an engine without meshes).
    nothing,
    /// It didn't parse, compile or run: the user's to fix, as the diagnostics say.
    failed,
    /// A message stopped it: it runs again once the editor is quiet.
    cancelled,
    /// The process running it ended (the worker's, which the server replaces).
    crashed,
};

/// Frees what Preview.filesRead gave.
pub fn freeFiles(allocator: std.mem.Allocator, files: []const []u8) void {
    for (files) |path| allocator.free(path);
    allocator.free(files);
}

pub const Preview = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setRoot: *const fn (ptr: *anyopaque, root: []const u8) anyerror!void,
        update: *const fn (ptr: *anyopaque, module_path: []const u8, source: []const u8) anyerror!void,
        remove: *const fn (ptr: *anyopaque, module_path: []const u8) anyerror!void,
        fileChanged: *const fn (ptr: *anyopaque, path: []const u8) anyerror!bool,
        filesRead: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]u8,
        evaluate: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, module_path: []const u8, want_mesh: bool) Outcome,
        hoverFacts: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, module_path: []const u8, node: ast.NodeIndex) anyerror!?[]u8,
        cancelToken: *const fn (ptr: *anyopaque) *std.atomic.Value(bool),
        takeCrash: *const fn (ptr: *anyopaque) ?[]const u8,
    };

    /// Imports read the project's files from `root` (absolute), the workspace folder.
    pub fn setRoot(self: Preview, root: []const u8) !void {
        return self.vtable.setRoot(self.ptr, root);
    }

    /// The document at `module_path` (its path in the project) now reads `source`.
    pub fn update(self: Preview, module_path: []const u8, source: []const u8) !void {
        return self.vtable.update(self.ptr, module_path, source);
    }

    pub fn remove(self: Preview, module_path: []const u8) !void {
        return self.vtable.remove(self.ptr, module_path);
    }

    /// The file at `path` (its path in the project) changed on disk: a module a document
    /// imports, not open itself, is read again, and the modules that read the file as data
    /// (`import_json`, `import_stl`) or import it run again. False when nothing read it, so
    /// nothing has to run.
    pub fn fileChanged(self: Preview, path: []const u8) !bool {
        return self.vtable.fileChanged(self.ptr, path);
    }

    /// The files the modules' last runs read as data, by their paths in the project, sorted
    /// and each once (owned by `allocator`; freeFiles frees them): what the editor is asked
    /// to watch.
    pub fn filesRead(self: Preview, allocator: std.mem.Allocator) ![][]u8 {
        return self.vtable.filesRead(self.ptr, allocator);
    }

    /// Runs what changed and gives the model of `module_path` (`nothing` in its place unless
    /// `want_mesh`: no viewer is watching); `cancelToken` stops it.
    pub fn evaluate(self: Preview, allocator: std.mem.Allocator, module_path: []const u8, want_mesh: bool) Outcome {
        return self.vtable.evaluate(self.ptr, allocator, module_path, want_mesh);
    }

    /// What a run of `module_path` knows about the value at `node` of its syntax tree, as
    /// Markdown (owned by `allocator`; empty when it has no value there), or null when the
    /// document doesn't compile.
    pub fn hoverFacts(self: Preview, allocator: std.mem.Allocator, module_path: []const u8, node: ast.NodeIndex) !?[]u8 {
        return self.vtable.hoverFacts(self.ptr, allocator, module_path, node);
    }

    /// Set to stop an evaluation (the inbox sets it when a message arrives).
    pub fn cancelToken(self: Preview) *std.atomic.Value(bool) {
        return self.vtable.cancelToken(self.ptr);
    }

    /// What the process running the scripts was doing when it ended unexpectedly, once per
    /// end (valid until the next call), or null: whichever call noticed, the user is told.
    pub fn takeCrash(self: Preview) ?[]const u8 {
        return self.vtable.takeCrash(self.ptr);
    }
};

/// The documents, the session evaluating them, and the run hovers read, in this process.
/// Lives in place: the session and the sandbox point into it.
pub const SessionPreview = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The open documents' text, as imports read it before the files on disk.
    documents: MemoryVfs,
    /// The project's files, read-only; null when there are none to read (tests).
    workspace: ?NativeVfs,
    /// The directory `workspace` was re-rooted at, closed with the preview.
    workspace_dir: ?std.Io.Dir = null,
    /// What every run here reads through, and can't write: the documents are untrusted.
    sandbox: ReadOnlyVfs,
    session: ScriptSession,
    /// The last run for hovers, until a document changes (imports make any change matter).
    hover: ?Hover = null,

    const Hover = struct {
        module_path: []u8,
        doc: api.Document,
        /// Null when the document doesn't compile.
        run: ?*HoverRun,
    };

    /// `read_workspace`: imports may read the files under the working directory (until
    /// `setRoot` names the workspace folder).
    pub fn init(self: *SessionPreview, allocator: std.mem.Allocator, io: std.Io, read_workspace: bool) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .documents = MemoryVfs.init(allocator),
            .workspace = if (read_workspace) NativeVfs.init(io, std.Io.Dir.cwd()) else null,
            .sandbox = undefined,
            .session = undefined,
        };
        errdefer self.documents.deinit();
        self.sandbox = ReadOnlyVfs.init(self.documents.vfs(), if (self.workspace) |*w| w.vfs() else null);
        self.session = try ScriptSession.init(allocator, io);
        self.session.vm.vfs = self.sandbox.vfs();
        self.session.vm.hooks.setLimit(limits.INTERACTIVE_INSTRUCTION_LIMIT);
        self.session.vm.setMemoryLimit(limits.INTERACTIVE_MEMORY_LIMIT);
    }

    pub fn deinit(self: *SessionPreview) void {
        self.dropHover();
        self.session.deinit();
        self.documents.deinit();
        if (self.workspace_dir) |d| d.close(self.io);
    }

    pub fn preview(self: *SessionPreview) Preview {
        return .{ .ptr = self, .vtable = &.{
            .setRoot = setRootImpl,
            .update = updateImpl,
            .remove = removeImpl,
            .fileChanged = fileChangedImpl,
            .filesRead = filesReadImpl,
            .evaluate = evaluateImpl,
            .hoverFacts = hoverFactsImpl,
            .cancelToken = cancelTokenImpl,
            .takeCrash = takeCrashImpl,
        } };
    }

    pub fn setRoot(self: *SessionPreview, root: []const u8) !void {
        const workspace = if (self.workspace) |*w| w else return;
        const dir = try std.Io.Dir.cwd().openDir(self.io, root, .{});
        if (self.workspace_dir) |old| old.close(self.io);
        self.workspace_dir = dir;
        workspace.root_dir = dir;
    }

    /// Replaces the module's source; the modules importing it are evaluated again with it.
    /// The modules it imports that aren't open are read from disk into the session, so a
    /// change to one on disk shows (fileChanged): they ran from the VM's import cache, which
    /// kept the first version it read.
    pub fn update(self: *SessionPreview, module_path: []const u8, source: []const u8) !void {
        self.dropHover();
        try self.documents.vfs().writeFile(module_path, source);
        _ = try self.session.workspace.upsertModule(module_path, source);
        try self.session.loadImports();
        try self.session.markFileEdited(module_path);
    }

    /// Forgets a document the editor closed. One that another document imports is read
    /// from disk again, as it is now.
    pub fn remove(self: *SessionPreview, module_path: []const u8) !void {
        self.dropHover();
        try self.session.removeModule(module_path);
        _ = self.documents.deleteFile(module_path);
        try self.session.loadImports();
    }

    pub fn fileChanged(self: *SessionPreview, path: []const u8) !bool {
        var affected = try self.session.markDataFileEdited(path);
        if (self.session.workspace.path_to_id.contains(path) and !self.documents.nodes.contains(path)) {
            try self.reloadModule(path);
            affected = true;
        }
        if (affected) self.dropHover();
        return affected;
    }

    /// Reads a module that isn't open again, with the imports it gained; one that can't be
    /// read (deleted) is forgotten, and its importers say it is missing.
    fn reloadModule(self: *SessionPreview, path: []const u8) !void {
        const source = self.sandbox.vfs().readFile(self.allocator, path) catch {
            return self.session.removeModule(path);
        };
        defer self.allocator.free(source);
        _ = try self.session.workspace.upsertModule(path, source);
        try self.session.loadImports();
        try self.session.markFileEdited(path);
    }

    pub fn filesRead(self: *SessionPreview, allocator: std.mem.Allocator) ![][]u8 {
        var unique: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer unique.deinit(allocator);
        for (self.session.nodes.items) |node| {
            for (node.files_read.items) |path| try unique.put(allocator, path, {});
        }
        const files = try allocator.alloc([]u8, unique.count());
        var copied: usize = 0;
        errdefer freeFiles(allocator, files[0..copied]);
        for (unique.keys(), files) |path, *file| {
            file.* = try allocator.dupe(u8, path);
            copied += 1;
        }
        std.mem.sortUnstable([]u8, files, {}, lessThan);
        return files;
    }

    fn lessThan(_: void, a: []u8, b: []u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    /// Evaluates what changed (modules it finished stay evaluated, even when a message
    /// stops it) and builds the model of `module_path` as GLB.
    pub fn evaluate(self: *SessionPreview, allocator: std.mem.Allocator, module_path: []const u8, want_mesh: bool) Outcome {
        self.session.evaluateUntilCancelled() catch |err| switch (err) {
            // A script that doesn't parse, compile or run is the user's to fix, not a fault.
            error.ParseError, error.CompileError, error.RuntimeError => {
                logger.debug("{s} did not evaluate: {}", .{ module_path, err });
                return if (self.cancelled()) .cancelled else .failed;
            },
            error.Canceled => return .cancelled,
            else => {
                logger.warn("Session evaluation failed: {}", .{err});
                return .failed;
            },
        };
        if (self.cancelled()) return .cancelled;
        if (!want_mesh) return .nothing;
        const id = self.session.workspace.path_to_id.get(module_path) orelse return .nothing;
        const handle = self.session.nodes.items[@backingInt(id)].cached_handle orelse return .nothing;
        if (!kernel.supports(handle.engine, .mesh)) {
            logger.warn("the viewport can't show this model: the {s} engine can't {s} yet", .{ handle.engine.scriptName(), kernel.Feature.mesh.describe() });
            return .nothing;
        }
        const parts = [_]gltf.Part{.{ .handle = handle }};
        const glb = gltf.buildGltfBuffer(allocator, &self.session.vm, &parts, null, .glb) catch |err| {
            logger.warn("Failed to build the preview's GLB: {}", .{err});
            return .nothing;
        };
        return .{ .mesh = @constCast(glb) };
    }

    fn cancelled(self: *SessionPreview) bool {
        return self.session.vm.cancel_token.load(.acquire);
    }

    pub fn hoverFacts(self: *SessionPreview, allocator: std.mem.Allocator, module_path: []const u8, node: ast.NodeIndex) !?[]u8 {
        const hover = try self.hoverFor(module_path);
        const run = hover.run orelse return null;
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        run.writeFacts(&hover.doc, node, &out.writer) catch |err| switch (err) {
            error.NoValue => {},
            else => |e| return e,
        };
        return try out.toOwnedSlice();
    }

    /// The run of `module_path` for hovers: the last one if it ran this document, else a new one.
    fn hoverFor(self: *SessionPreview, module_path: []const u8) !*Hover {
        if (self.hover) |*hover| {
            if (std.mem.eql(u8, hover.module_path, module_path)) return hover;
            self.dropHover();
        }
        const source = try self.documents.vfs().readFile(self.allocator, module_path);
        defer self.allocator.free(source);
        const path = try self.allocator.dupe(u8, module_path);
        errdefer self.allocator.free(path);
        var doc = try api.Document.parse(self.allocator, source);
        errdefer doc.deinit();
        const run = try HoverRun.create(self.allocator, self.io, self.sandbox.vfs(), &doc, module_path);
        self.hover = .{ .module_path = path, .doc = doc, .run = run };
        return &self.hover.?;
    }

    fn dropHover(self: *SessionPreview) void {
        const hover = &(self.hover orelse return);
        if (hover.run) |run| run.destroy();
        hover.doc.deinit();
        self.allocator.free(hover.module_path);
        self.hover = null;
    }

    fn setRootImpl(ptr: *anyopaque, root: []const u8) anyerror!void {
        return cast(ptr).setRoot(root);
    }
    fn updateImpl(ptr: *anyopaque, module_path: []const u8, source: []const u8) anyerror!void {
        return cast(ptr).update(module_path, source);
    }
    fn removeImpl(ptr: *anyopaque, module_path: []const u8) anyerror!void {
        return cast(ptr).remove(module_path);
    }
    fn fileChangedImpl(ptr: *anyopaque, path: []const u8) anyerror!bool {
        return cast(ptr).fileChanged(path);
    }
    fn filesReadImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]u8 {
        return cast(ptr).filesRead(allocator);
    }
    fn evaluateImpl(ptr: *anyopaque, allocator: std.mem.Allocator, module_path: []const u8, want_mesh: bool) Outcome {
        return cast(ptr).evaluate(allocator, module_path, want_mesh);
    }
    fn hoverFactsImpl(ptr: *anyopaque, allocator: std.mem.Allocator, module_path: []const u8, node: ast.NodeIndex) anyerror!?[]u8 {
        return cast(ptr).hoverFacts(allocator, module_path, node);
    }
    fn cancelTokenImpl(ptr: *anyopaque) *std.atomic.Value(bool) {
        return &cast(ptr).session.vm.cancel_token;
    }
    /// A crash here ends the server too, so there is never one to tell of.
    fn takeCrashImpl(_: *anyopaque) ?[]const u8 {
        return null;
    }
    fn cast(ptr: *anyopaque) *SessionPreview {
        return @ptrCast(@alignCast(ptr));
    }
};

/// A document run once for its hovers. It used to run again for every hover, in a fresh
/// VM capped at 500k instructions, so a big model's hovers showed nothing; now it runs
/// once per version of the workspace, under the preview's limit, and every hover reads
/// what that run left. Heap-allocated: the VM must not move.
pub const HoverRun = struct {
    allocator: std.mem.Allocator,
    vm: VM,
    program: chunk.Chunk,

    /// Runs `doc` (known in the project as `module_path`) on `sandbox`, which must not
    /// write: the document is untrusted. Null when it doesn't compile: running an
    /// incomplete chunk broke the VM's invariants, and its diagnostics say why.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, sandbox: Vfs, doc: *const api.Document, module_path: []const u8) !?*HoverRun {
        const self = try allocator.create(HoverRun);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .vm = undefined, .program = chunk.Chunk.init() };
        self.vm = try VM.init(allocator, io);
        errdefer self.vm.deinit();
        // VM.init defaults to a NativeVfs rooted at cwd; replace it before any script code runs.
        self.vm.vfs = sandbox;
        self.vm.mute_errors = true; // its errors are the document's diagnostics
        self.vm.hooks.setLimit(limits.INTERACTIVE_INSTRUCTION_LIMIT);
        self.vm.setMemoryLimit(limits.INTERACTIVE_MEMORY_LIMIT);
        try registry.registerStandardLibrary(&self.vm);

        var comp = Compiler.forDocument(allocator, doc, &self.program, &self.vm);
        defer comp.deinit();
        comp.module_path = module_path;
        comp.compile(doc.tree.root) catch |err| {
            logger.debug("Hover: the document doesn't compile: {}", .{err});
            self.destroy();
            return null;
        };
        // A run that stops early still leaves what it defined before stopping.
        _ = self.vm.interpret(&self.program);
        return self;
    }

    pub fn destroy(self: *HoverRun) void {
        const allocator = self.allocator;
        self.program.free(allocator);
        self.vm.deinit();
        allocator.destroy(self);
    }

    /// What the run knows about the value at `target_node` of `doc` (the document it ran):
    /// a variable's value, or a call's, with a shape's measurements.
    pub fn writeFacts(self: *HoverRun, doc: *const api.Document, target_node: ast.NodeIndex, writer: anytype) !void {
        const node = doc.tree.getNode(target_node) orelse return error.NoValue;
        var val: value.Value = value.Value.initNil();

        if (node.tag == .identifier or node.tag == .assignment) {
            const name = if (node.tag == .identifier) doc.tree.getString(@as(ast.StringId, @fromBackingInt(node.data))) else doc.tree.getString(doc.tree.assignment(node).name);
            val = self.vm.globals.get(name) orelse return error.NoValue;
        } else if (node.tag == .method_call) {
            // The call alone, in the run's VM, so it sees the run's variables.
            var expr_chunk = chunk.Chunk.init();
            defer expr_chunk.free(self.allocator);
            var expr_comp = Compiler.forDocument(self.allocator, doc, &expr_chunk, &self.vm);
            defer expr_comp.deinit();
            expr_comp.compile(target_node) catch return error.NoValue;
            const res = self.vm.interpret(&expr_chunk);
            if (res != .ok or self.vm.stack_top == 0) return error.NoValue;
            val = self.vm.stack[self.vm.stack_top - 1];
        } else {
            return;
        }

        // 3. Concretize and write Markdown while memory is safe
        if (val.isGeometry()) {
            try writer.print("\n---\n### 🧊 3D Solid\n", .{});

            if (self.vm.ensureConcrete(val)) |handle| {
                // Only what the engine can measure: a B-Rep part would otherwise show zeros.
                const engine = handle.engine;
                if (kernel.supports(engine, .bounding_box)) if (kernel.boundingBox(handle)) |bx| {
                    const dx = bx.max[0] - bx.min[0];
                    const dy = bx.max[1] - bx.min[1];
                    const dz = bx.max[2] - bx.min[2];
                    try writer.print("- **Bounds:** W: `{d:.2}` L: `{d:.2}` H: `{d:.2}` mm\n", .{ dx, dy, dz });
                };

                if (kernel.supports(engine, .volume)) try writer.print("- **Volume:** `{d:.2}` mm³\n", .{kernel.volume(handle)});
                if (kernel.supports(engine, .surface_area)) try writer.print("- **Surface Area:** `{d:.2}` mm²\n", .{kernel.surfaceArea(handle)});
                if (kernel.supports(engine, .genus)) {
                    const gen = kernel.genus(handle);
                    if (gen > 0) try writer.print("- **Holes (Genus):** `{d}`\n", .{gen});
                }

                // Counted, not tessellated: the mesh used to be built and copied for this line.
                if (kernel.numTris(handle)) |tris| try writer.print("- **Topology:** `{d}` Vertices, `{d}` Faces\n", .{ kernel.numVerts(handle), tris });
            } else |_| {}
        } else if (val.isCrossSection()) { //2D SAFE RESOLUTION
            try writer.print("\n---\n### 📐 2D Profile\n", .{});

            if (self.vm.ensureConcreteCrossSection(val)) |cs_handle| {
                if (kernel.supports(cs_handle.engine, .sketch_measure)) {
                    const area = kernel.crossSectionArea(cs_handle);
                    if (kernel.crossSectionBounds(cs_handle)) |rect| {
                        const w = rect.max[0] - rect.min[0];
                        const l = rect.max[1] - rect.min[1];
                        try writer.print("- **Bounds:** W: `{d:.2}` L: `{d:.2}` mm\n", .{ w, l });
                    } else {
                        try writer.print("- **Bounds:** empty\n", .{});
                    }
                    try writer.print("- **Area:** `{d:.2}` mm²\n", .{area});
                }
            } else |_| {}
        } else if (val.isString()) {
            try writer.writeAll("\n---\n*(String)* `");
            try val.stringify(true, writer);
            try writer.writeAll("`\n");
        } else if (val.isBool()) {
            try writer.print("\n---\n*(Boolean)* `{}`\n", .{val.asBool()});
        }
    }
};
