const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const api = @import("../api.zig");
const lsp_actions = @import("lsp_actions.zig");
const lsp_inbox = @import("lsp_inbox.zig");
const lsp_hints = @import("lsp_hints.zig");
const ast = @import("../core/ast.zig");
const manifest = @import("../stdlib/manifest.zig");
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const kernel = @import("../kernel/kernel.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const ScriptSession = @import("../daemon/session.zig").ScriptSession;
const viewport_ws = @import("../daemon/viewport_ws.zig");
const ViewportWsServer = viewport_ws.ViewportWsServer;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const Vfs = @import("../vfs/vfs.zig").Vfs;
const ReadOnlyVfs = @import("../vfs/readonly.zig").ReadOnlyVfs;
const project_config = @import("config.zig");
const ProjectConfig = project_config.ProjectConfig;
const limits = @import("../core/limits.zig");

const logger = std.log.scoped(.lsp);

/// Instruction budget for hover evaluation so the LSP doesn't hang on infinite loops.
/// Custom notification telling the editor where the viewport WebSocket listens.
pub const VIEWPORT_READY_NOTIFICATION = "kupcad/viewportReady";
/// Environment variable overriding the preferred viewport port ("0" = always ephemeral).
pub const VIEWPORT_PORT_ENV = "KUPCAD_VIEWPORT_PORT";

pub const USAGE =
    \\Usage: kupcad lsp
    \\
    \\Starts the language server on stdin and stdout. Editors start it themselves;
    \\the VS Code extension runs it for .kup files.
    \\
;

/// Resolves the preferred viewport port from the environment, defaulting to DEFAULT_PORT.
pub fn preferredViewportPort(environ: *const std.process.Environ.Map) u16 {
    const raw = environ.get(VIEWPORT_PORT_ENV) orelse return viewport_ws.DEFAULT_PORT;
    return std.fmt.parseInt(u16, raw, 10) catch viewport_ws.DEFAULT_PORT;
}

pub const DocumentBuffer = struct {
    uri: []const u8,
    /// What the session and imports call it (Handler.modulePath), owned.
    module_path: []const u8,
    source: []const u8,
    doc: ?api.Document = null,

    pub fn deinit(self: *DocumentBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.module_path);
        allocator.free(self.source);
        if (self.doc) |*d| d.deinit();
    }
};

const ScopeContext = struct {
    def_name: ?[]const u8 = null,
    class_name: ?[]const u8 = null,
};

/// A document run once for its hovers. It used to run again for every hover, in a fresh
/// VM capped at 500k instructions, so a big model's hovers showed nothing; now it runs
/// once per version of the workspace, under the preview's limit, and every hover reads
/// what that run left. Heap-allocated: the VM must not move.
pub const HoverRun = struct {
    allocator: std.mem.Allocator,
    /// The document it ran (owned).
    uri: []const u8,
    vm: VM,
    program: chunk.Chunk,

    /// Runs `doc` (known in the project as `module_path`) on `sandbox`, which must not
    /// write: the document is untrusted. Null when it doesn't compile: running an
    /// incomplete chunk broke the VM's invariants, and its diagnostics say why.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, sandbox: Vfs, doc: *const api.Document, uri: []const u8, module_path: []const u8) !?*HoverRun {
        const self = try allocator.create(HoverRun);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .uri = try allocator.dupe(u8, uri), .vm = undefined, .program = chunk.Chunk.init() };
        errdefer allocator.free(self.uri);
        self.vm = try VM.init(allocator, io);
        errdefer self.vm.deinit();
        // VM.init defaults to a NativeVfs rooted at cwd; replace it before any script code runs.
        self.vm.vfs = sandbox;
        self.vm.mute_errors = true; // its errors are the document's diagnostics
        self.vm.instruction_limit = limits.INTERACTIVE_INSTRUCTION_LIMIT;
        try registry.registerStandardLibrary(&self.vm);

        var comp = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &self.program, &self.vm);
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
        allocator.free(self.uri);
        allocator.destroy(self);
    }

    /// What the run knows about the value at `target_node` of `doc` (the document it ran):
    /// a variable's value, or a call's, with a shape's measurements.
    pub fn writeFacts(self: *HoverRun, doc: *const api.Document, target_node: ast.NodeIndex, writer: anytype) !void {
        const node = doc.tree.getNode(target_node) orelse return error.NoValue;
        var val: value.Value = value.Value.initNil();

        if (node.tag == .identifier) {
            const name = doc.tree.getString(@as(ast.StringId, @fromBackingInt(node.data)));
            val = self.vm.globals.get(name) orelse return error.NoValue;
        } else if (node.tag == .assignment) {
            const assign = doc.tree.assignment(node);
            const name = doc.tree.getString(assign.name);
            val = self.vm.globals.get(name) orelse return error.NoValue;
        } else if (node.tag == .method_call) {
            // The call alone, in the run's VM, so it sees the run's variables.
            var expr_chunk = chunk.Chunk.init();
            defer expr_chunk.free(self.allocator);
            var expr_comp = Compiler.init(self.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &expr_chunk, &self.vm);
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

                if (kernel.supports(engine, .mesh)) if (kernel.getMesh(self.allocator, handle)) |mesh| {
                    defer self.allocator.free(mesh.vert_props);
                    defer self.allocator.free(mesh.tri_verts);
                    try writer.print("- **Topology:** `{d}` Vertices, `{d}` Faces\n", .{ mesh.vert_props.len / mesh.num_prop, mesh.tri_verts.len / 3 });
                };
            } else |_| {}
        } else if (val.isCrossSection()) { //2D SAFE RESOLUTION
            try writer.print("\n---\n### 📐 2D Profile\n", .{});

            if (self.vm.ensureConcreteCrossSection(val)) |cs_handle| {
                if (kernel.supports(cs_handle.engine, .sketch_measure)) {
                    const area = kernel.crossSectionArea(cs_handle);
                    const rect = kernel.crossSectionBounds(cs_handle);

                    const w = rect.max[0] - rect.min[0];
                    const l = rect.max[1] - rect.min[1];

                    try writer.print("- **Bounds:** W: `{d:.2}` L: `{d:.2}` mm\n", .{ w, l });
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

inline fn findEnclosingScope(doc: *const api.Document, start_node: ast.NodeIndex) ScopeContext {
    var current = start_node;
    var ctx = ScopeContext{};

    while (current != .none) {
        const p_idx = doc.parents[@backingInt(current)];
        if (p_idx == .none) break;
        const p_node = doc.tree.getNode(p_idx) orelse break;
        switch (p_node.tag) {
            .def_stmt => {
                if (ctx.def_name == null) {
                    const ds = doc.tree.defStmt(p_node);
                    ctx.def_name = doc.tree.getString(ds.name);
                }
            },
            .class_stmt => {
                if (ctx.class_name == null) {
                    const cs = doc.tree.classStmt(p_node);
                    const name_node = doc.tree.getNode(cs.name);
                    if (name_node) |nn| {
                        if (nn.tag == .identifier) {
                            ctx.class_name = doc.tree.getString(@as(ast.StringId, @fromBackingInt(nn.data)));
                        }
                    }
                }
            },
            else => {},
        }
        current = p_idx;
    }
    return ctx;
}

/// A diagnostic as `textDocument/publishDiagnostics` sends it.
const PublishedDiagnostic = struct {
    const Position = struct { line: u32, character: u32 };

    range: struct { start: Position, end: Position },
    severity: u32,
    source: []const u8,
    message: []const u8,
    /// The lint rule's id, which editors show beside the message.
    code: ?[]const u8 = null,
};

pub const Handler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    offset_encoding: lsp.offsets.Encoding = .@"utf-16",
    files: std.StringHashMapUnmanaged(DocumentBuffer) = .empty,

    session: *ScriptSession,
    /// Null when the viewport server failed to start; language features keep working.
    ws_server: ?*ViewportWsServer,
    mem_vfs: *MemoryVfs,
    /// Read-only VFS every LSP-run VM uses (session + hover).
    sandbox: *ReadOnlyVfs,
    /// The project's files on disk, as imports read them: rooted at `root` once the editor
    /// names it. Null when there are none to read (tests).
    workspace_fs: ?*NativeVfs,
    /// The workspace folder the editor opened (absolute, owned): documents are known by
    /// their path relative to it, so their relative imports find each other.
    root: ?[]u8 = null,
    /// The directory `workspace_fs` was re-rooted at, closed with the handler.
    root_dir: ?std.Io.Dir = null,
    /// The module path of the document last edited, whose mesh the viewport shows (owned).
    preview_module: ?[]u8 = null,
    /// The last document run for hovers, until any document changes (imports make any
    /// edit matter).
    hover_run: ?*HoverRun = null,
    /// An edit hasn't been evaluated yet.
    preview_pending: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: *lsp.Transport,
        session: *ScriptSession,
        ws_server: ?*ViewportWsServer,
        mem_vfs: *MemoryVfs,
        sandbox: *ReadOnlyVfs,
        workspace_fs: ?*NativeVfs,
    ) Handler {
        session.vm.instruction_limit = limits.INTERACTIVE_INSTRUCTION_LIMIT;
        return .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .offset_encoding = .@"utf-16",
            .files = .empty,
            .session = session,
            .ws_server = ws_server,
            .mem_vfs = mem_vfs,
            .sandbox = sandbox,
            .workspace_fs = workspace_fs,
        };
    }

    /// Replaces the module source in the session; the preview of `uri` is evaluated once the
    /// editor goes quiet (`evaluatePreview`, run by the inbox), not on every keystroke.
    /// Uses upsertModule: addModule returns error.DuplicateModule for known paths, and the old
    /// "catch -> patch source" path never ran, so the viewport kept rendering stale code.
    /// The module is named by its path in the project (modulePath), and its unsaved text
    /// is what imports of it read; the modules importing it are evaluated again with it.
    fn syncSession(self: *Handler, module_path: []const u8, source: []const u8) !void {
        try self.mem_vfs.vfs().writeFile(module_path, source);

        _ = try self.session.workspace.upsertModule(module_path, source);
        try self.session.workspace.linkDependencies();
        try self.session.buildReverseGraph();
        try self.session.markFileEdited(module_path);

        self.dropHoverRun();
        const previewed = try self.allocator.dupe(u8, module_path);
        if (self.preview_module) |old| self.allocator.free(old);
        self.preview_module = previewed;
        self.preview_pending = true;
    }

    /// The run of `buf` for hovers: the last one if it ran this document, else a new one.
    fn hoverRun(self: *Handler, buf: DocumentBuffer, doc: *const api.Document) !?*HoverRun {
        if (self.hover_run) |run| {
            if (std.mem.eql(u8, run.uri, buf.uri)) return run;
            self.dropHoverRun();
        }
        self.hover_run = try HoverRun.create(self.allocator, self.io, self.sandbox.vfs(), doc, buf.uri, buf.module_path);
        return self.hover_run;
    }

    fn dropHoverRun(self: *Handler) void {
        if (self.hover_run) |run| run.destroy();
        self.hover_run = null;
    }

    /// What the session and imports call the document at `uri`: its path relative to the
    /// workspace root (as `./hw.kup` in another file resolves), else its absolute path, else
    /// the URI itself (an unsaved buffer). They used to know it by its URI, which no import
    /// names, so open documents never linked. Caller owns the result.
    fn modulePath(self: *const Handler, allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const path = try documentPath(scratch.allocator(), uri) orelse return allocator.dupe(u8, uri);
        if (self.root) |root| {
            if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/') {
                return allocator.dupe(u8, path[root.len + 1 ..]);
            }
        }
        return allocator.dupe(u8, path);
    }

    /// Takes the workspace folder from `initialize`: its first folder, else its root URI.
    fn setRoot(self: *Handler, request: lsp.types.InitializeParams) !void {
        const uri = if (request.workspaceFolders) |folders| (if (folders.len > 0) folders[0].uri else null) else null;
        const root_uri = uri orelse request.rootUri orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const path = try documentPath(scratch.allocator(), root_uri) orelse return;
        const trimmed = std.mem.trimEnd(u8, path, "/");
        self.root = try self.allocator.dupe(u8, trimmed);
        if (self.workspace_fs) |fs| {
            const dir = try std.Io.Dir.cwd().openDir(self.io, trimmed, .{});
            self.root_dir = dir;
            fs.root_dir = dir;
        }
    }

    /// Evaluates the session and streams the edited document's mesh to the viewport. An edit
    /// that arrives meanwhile cancels it (the inbox sets the VM's cancel token).
    pub fn evaluatePreview(self: *Handler) void {
        self.preview_pending = false;
        const uri = self.preview_module orelse return;
        // Stopped by a message (the inbox's cancel): run again once the editor is quiet. The
        // modules it finished stay evaluated, so the next run picks up where it stopped.
        defer if (self.session.vm.cancel_token.load(.acquire)) {
            self.preview_pending = true;
        };
        // A script that doesn't parse, compile or run is the user's to fix, not a server fault.
        self.session.evaluateUntilCancelled() catch |err| switch (err) {
            error.ParseError, error.CompileError, error.RuntimeError, error.Cancelled => {
                logger.debug("{s} did not evaluate: {}", .{ uri, err });
                return;
            },
            else => {
                logger.warn("Session evaluation failed: {}", .{err});
                return;
            },
        };
        if (self.ws_server) |ws| {
            ws.broadcastSessionMesh(self.session, uri) catch |err| logger.warn("Viewport broadcast failed: {}", .{err});
        }
    }

    /// The preview as the inbox's slow work.
    pub fn previewWork(self: *Handler) lsp_inbox.Work {
        const Hooks = struct {
            fn pending(context: *anyopaque) bool {
                const handler: *Handler = @ptrCast(@alignCast(context));
                return handler.preview_pending;
            }
            fn run(context: *anyopaque) void {
                const handler: *Handler = @ptrCast(@alignCast(context));
                handler.evaluatePreview();
            }
        };
        return .{ .context = self, .pending = Hooks.pending, .run = Hooks.run, .cancel = &self.session.vm.cancel_token };
    }

    pub fn deinit(self: *Handler) void {
        self.dropHoverRun();
        if (self.preview_module) |m| self.allocator.free(m);
        if (self.root) |r| self.allocator.free(r);
        if (self.root_dir) |d| d.close(self.io);
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
    }

    pub fn initialize(
        self: *Handler,
        _: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        logger.info("Initializing server", .{});
        self.setRoot(request) catch |err| logger.warn("Could not open the workspace folder: {}; imports are read from the current directory", .{err});

        if (request.capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |encoding| {
                self.offset_encoding = switch (encoding) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }

        const server_capabilities = serverCapabilities(self.offset_encoding);
        if (builtin.mode == .debug) {
            lsp.basic_server.validateServerCapabilities(Handler, server_capabilities);
        }

        return .{
            .serverInfo = .{
                .name = "kupcad-lsp",
                .version = "0.1.0",
            },
            .capabilities = server_capabilities,
        };
    }

    /// What the server offers. Every capability needs its handler: lsp_kit checks that in
    /// Debug builds, so declaring inlay hints as plain `true` (which promises
    /// `inlayHint/resolve` too) made a Debug server panic on `initialize`.
    pub fn serverCapabilities(encoding: lsp.offsets.Encoding) lsp.types.ServerCapabilities {
        return .{
            .positionEncoding = switch (encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .text_document_sync_options = .{
                    .openClose = true,
                    .change = .Full,
                },
            },
            .documentFormattingProvider = .{ .bool = true },
            .hoverProvider = .{ .bool = true },
            // The hints are complete when sent: nothing to resolve later.
            .inlayHintProvider = .{ .inlay_hint_options = .{ .resolveProvider = false } },
            .completionProvider = .{
                .triggerCharacters = &.{ ".", ":" },
            },
            .documentSymbolProvider = .{ .bool = true },
            .codeActionProvider = .{ .bool = true },
        };
    }

    pub fn initialized(self: *Handler, arena: std.mem.Allocator, _: lsp.types.InitializedParams) void {
        // Tell the editor which port the viewport actually bound (it may be ephemeral), so the
        // extension never has to hard-code it. Sent after `initialized` per LSP lifecycle rules.
        const ws = self.ws_server orelse return;
        const Params = struct { port: u16 };
        self.transport.writeNotification(self.io, arena, VIEWPORT_READY_NOTIFICATION, Params, .{ .port = ws.port }, .{}) catch |err| {
            logger.warn("Failed to announce viewport port: {}", .{err});
        };
    }

    pub fn shutdown(_: *Handler, _: std.mem.Allocator, _: void) ?void {
        return null;
    }

    pub fn exit(_: *Handler, _: std.mem.Allocator, _: void) void {}

    inline fn useUtf8(self: *const Handler) bool {
        return self.offset_encoding == .@"utf-8";
    }

    inline fn getColumn(self: *const Handler, line_index: *const api.LineIndex, offset: u32) u32 {
        return if (self.useUtf8()) line_index.getUtf8Column(offset) else line_index.getUtf16Column(offset);
    }

    pub fn @"textDocument/didOpen"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidOpenParams,
    ) !void {
        logger.debug("Opened {s}", .{params.textDocument.uri});
        if (self.files.fetchRemove(params.textDocument.uri)) |kv| {
            var old_doc = kv.value;
            old_doc.deinit(self.allocator);
        }

        const uri_dup = try self.allocator.dupe(u8, params.textDocument.uri);
        const module_path = try self.modulePath(self.allocator, params.textDocument.uri);
        const source_dup = try self.allocator.dupe(u8, params.textDocument.text);

        const parsed_doc = api.Document.parse(self.allocator, source_dup) catch null;
        try self.files.put(self.allocator, uri_dup, .{
            .uri = uri_dup,
            .module_path = module_path,
            .source = source_dup,
            .doc = parsed_doc,
        });

        try self.syncSession(module_path, source_dup);

        try self.runDiagnostics(arena, params.textDocument.uri, params.textDocument.text);
    }

    pub fn @"textDocument/didChange"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidChangeParams,
    ) !void {
        logger.debug("Changed {s}", .{params.textDocument.uri});
        if (params.contentChanges.len > 0) {
            switch (params.contentChanges[0]) {
                .text_document_content_change_whole_document => |doc_change| {
                    if (self.files.getPtr(params.textDocument.uri)) |buf| {
                        self.allocator.free(buf.source);
                        if (buf.doc) |*d| d.deinit();

                        buf.source = try self.allocator.dupe(u8, doc_change.text);
                        buf.doc = api.Document.parse(self.allocator, buf.source) catch null;

                        try self.syncSession(buf.module_path, buf.source);
                    }
                    try self.runDiagnostics(arena, params.textDocument.uri, doc_change.text);
                },
                else => {},
            }
        }
    }

    pub fn @"textDocument/didClose"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidCloseParams,
    ) !void {
        const uri = params.textDocument.uri;
        logger.debug("Closed {s}", .{uri});
        // The editor keeps the last diagnostics it was sent for a file until told otherwise.
        try self.publishDiagnostics(arena, uri, &.{});
        self.dropHoverRun();
        var closed = (self.files.fetchRemove(uri) orelse return).value;
        defer closed.deinit(self.allocator);
        try self.session.removeModule(closed.module_path);
        _ = self.mem_vfs.deleteFile(closed.module_path);
    }

    pub fn @"textDocument/formatting"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.document_formatting.Params,
    ) !?[]const lsp.types.TextEdit {
        logger.debug("Formatting requested for {s}", .{params.textDocument.uri});
        const doc_buf = self.files.get(params.textDocument.uri) orelse return null;
        const source = doc_buf.source;

        const config = self.projectConfig(arena, params.textDocument.uri);
        const formatted = api.formatCode(arena, source, config.fmt) catch |err| {
            logger.debug("Not formatted: {}", .{err});
            return null;
        };

        var line_index = try api.LineIndex.init(arena, source);
        const end_offset: u32 = @intCast(source.len);
        const end_line = line_index.getLine(end_offset);
        const end_char = self.getColumn(&line_index, end_offset);

        var edits = std.ArrayListUnmanaged(lsp.types.TextEdit).empty;
        try edits.append(arena, .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = end_line, .character = end_char },
            },
            .newText = formatted,
        });
        return edits.items;
    }

    /// Context-Aware Hover Provider using doc.parents, doc.symbols, and lsp.offsets.positionToIndex
    pub fn @"textDocument/hover"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.Hover.Params,
    ) ?lsp.types.Hover {
        logger.debug("Hover requested for {s}", .{params.textDocument.uri});
        const buf = self.files.get(params.textDocument.uri) orelse return null;
        const doc = buf.doc orelse return null;

        const target_offset = lsp.offsets.positionToIndex(buf.source, params.position, self.offset_encoding);

        var found_token_idx: ?u24 = null;
        for (doc.tokens.starts, 0..) |start, i| {
            const len = doc.tokens.lengths[i];
            if (target_offset >= start and target_offset < start + len) {
                found_token_idx = @intCast(i);
                break;
            }
        }

        const tok_idx = found_token_idx orelse return null;

        var found_node_idx: ast.NodeIndex = .none;
        for (doc.tree.nodes.items, 0..) |node, i| {
            if (node.main_token == tok_idx) {
                found_node_idx = @fromBackingInt(@as(u32, @intCast(i)));
                break;
            }
        }

        if (found_node_idx == .none) return null;
        const target_node = doc.tree.getNode(found_node_idx).?;
        const scope = findEnclosingScope(&doc, found_node_idx);

        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();

        // AST Base Formatting
        if (target_node.tag == .identifier) {
            const name = doc.tree.getString(@as(ast.StringId, @fromBackingInt(target_node.data)));
            const sym = doc.symbols[@backingInt(found_node_idx)];
            out.writer.print("```kupcad\n(variable) {s}\n```\n", .{name}) catch return null;
            out.writer.print("**Scope:** `{s}` (slot `{d}`)\n\n", .{ @tagName(sym.kind), sym.index }) catch return null;
        } else if (target_node.tag == .method_call) {
            const mc = doc.tree.methodCall(target_node);
            const m_name = doc.tree.getString(mc.method_name);
            out.writer.print("```kupcad\n(method) {s}(...)\n```\n", .{m_name}) catch return null;
        } else if (target_node.tag == .number) {
            const num_val = doc.tree.number(target_node);
            out.writer.print("```kupcad\n(number) {d}\n```\n", .{num_val}) catch return null;
        }

        // What running the document says about it (bounds, volume, ...).
        if (self.hoverRun(buf, &doc)) |maybe_run| {
            if (maybe_run) |run| run.writeFacts(&doc, found_node_idx, &out.writer) catch |err| {
                logger.debug("Hover: no value to show: {}", .{err});
            };
        } else |err| logger.warn("Hover: could not run the document: {}", .{err});

        // Add scope footer
        if (scope.def_name) |dn| {
            out.writer.print("\n*Enclosing Method:* `{s}`\n", .{dn}) catch return null;
        }
        if (scope.class_name) |cn| {
            out.writer.print("*Enclosing Class:* `{s}`\n", .{cn}) catch return null;
        }

        return .{
            .contents = .{
                .markup_content = .{
                    .kind = .markdown,
                    .value = out.written(),
                },
            },
        };
    }

    pub fn @"textDocument/inlayHint"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.InlayHint.Params,
    ) !?[]const lsp.types.InlayHint {
        logger.debug("Inlay hints requested for {s}", .{params.textDocument.uri});
        const buf = self.files.get(params.textDocument.uri) orelse return null;
        const doc = buf.doc orelse return null;

        var hints = std.ArrayListUnmanaged(lsp.types.InlayHint).empty;
        var line_index = try api.LineIndex.init(arena, buf.source);

        for (try lsp_hints.hints(arena, &doc)) |hint| {
            const label = switch (hint.kind) {
                .parameter => try arena.print("{s}:", .{hint.name}),
                .type => try arena.print(": {s}", .{hint.name}),
            };
            try hints.append(arena, .{
                .position = .{ .line = line_index.getLine(hint.offset), .character = self.getColumn(&line_index, hint.offset) },
                .label = .{ .string = label },
                .kind = if (hint.kind == .parameter) .Parameter else .Type,
                .paddingLeft = false,
                .paddingRight = hint.kind == .parameter,
            });
        }

        return hints.items;
    }

    pub fn @"textDocument/completion"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.completion.Params,
    ) !lsp.ResultType("textDocument/completion") {
        logger.debug("Completion requested for {s}", .{params.textDocument.uri});

        var items = std.ArrayListUnmanaged(lsp.types.completion.Item).empty;

        // Safely fetch the current document source buffer
        const doc_buf = self.files.get(params.textDocument.uri) orelse return .{ .completion_items = items.items };

        // Find the exact byte index of the user's cursor
        const cursor_offset = lsp.offsets.positionToIndex(doc_buf.source, params.position, self.offset_encoding);

        var is_method_call = false;
        var i = cursor_offset;

        // Scan backwards through the source code from the cursor
        while (i > 0) {
            i -= 1;
            const c = doc_buf.source[i];

            // Skip over the characters of the word the user is currently typing (e.g. "tra")
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '?' or c == '!') {
                continue;
            }

            // We hit a boundary! If it's a dot, we are inside a method chain
            if (c == '.') {
                is_method_call = true;
            }
            break;
        }

        if (is_method_call) {
            // CONTEXT: After a dot `.`
            // Suggest strictly mesh methods
            for (manifest.mesh_methods) |mm| {
                try items.append(arena, .{
                    .label = mm.name,
                    .kind = .Method,
                });
            }
        } else {
            // CONTEXT: Standard Scope
            // Suggest Classes, Global Functions, and Primitives
            for (manifest.lsp_completions) |name| {
                const is_class = name.len > 0 and std.ascii.isUpper(name[0]);
                try items.append(arena, .{
                    .label = name,
                    .kind = if (is_class) .Class else .Function, // "Function" icon fits globals better
                });
            }
        }

        return .{ .completion_items = items.items };
    }

    pub fn @"textDocument/documentSymbol"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentSymbol.Params,
    ) !lsp.ResultType("textDocument/documentSymbol") {
        logger.debug("Document symbol requested for {s}", .{params.textDocument.uri});
        const doc_buf = self.files.get(params.textDocument.uri) orelse return null;
        const doc = doc_buf.doc orelse return null;

        var symbols = std.ArrayListUnmanaged(lsp.types.DocumentSymbol).empty;
        var line_index = try api.LineIndex.init(arena, doc_buf.source);

        // Capture node by reference using `*node`
        for (doc.tree.nodes.items, 0..) |*node, i| {
            var sym_name: ?[]const u8 = null;
            var sym_kind: lsp.types.SymbolKind = .Variable;

            switch (node.tag) {
                .def_stmt => {
                    const ds = doc.tree.defStmt(node);
                    if (ds.name != .none) sym_name = doc.tree.getString(ds.name);
                    sym_kind = .Function;
                },
                .class_stmt => {
                    const cs = doc.tree.classStmt(node);
                    const name_node = doc.tree.getNode(cs.name);
                    if (name_node != null and name_node.?.tag == .identifier) {
                        sym_name = doc.tree.getString(@as(ast.StringId, @fromBackingInt(name_node.?.data)));
                    }
                    sym_kind = .Class;
                },
                .module_stmt => {
                    const ms = doc.tree.moduleStmt(node);
                    if (ms.name != .none) sym_name = doc.tree.getString(ms.name);
                    sym_kind = .Module;
                },
                .assignment => {
                    if (doc.parents[i] == .none) {
                        const assign = doc.tree.assignment(node);
                        if (assign.name != .none) sym_name = doc.tree.getString(assign.name);
                        sym_kind = .Variable;
                    }
                },
                else => continue,
            }

            if (sym_name) |name| {
                const start_offset = doc.tokens.starts[node.main_token];
                const length = doc.tokens.lengths[node.main_token];
                const end_offset = start_offset + length;

                const start_pos = lsp.types.Position{
                    .line = line_index.getLine(start_offset),
                    .character = self.getColumn(&line_index, start_offset),
                };
                const end_pos = lsp.types.Position{
                    .line = line_index.getLine(end_offset),
                    .character = self.getColumn(&line_index, end_offset),
                };

                const range = lsp.types.Range{ .start = start_pos, .end = end_pos };

                try symbols.append(arena, .{
                    .name = name,
                    .kind = sym_kind,
                    .range = range,
                    .selectionRange = range,
                });
            }
        }

        return .{ .document_symbols = symbols.items };
    }

    /// Quick fixes for the lint findings on the asked lines (cli/lsp_actions.zig): each
    /// finding's fix, and an action that disables its rule for the line.
    pub fn @"textDocument/codeAction"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.CodeAction.Params,
    ) !lsp.ResultType("textDocument/codeAction") {
        const doc_buf = self.files.get(params.textDocument.uri) orelse return null;
        const encoding: lsp_actions.Encoding = if (self.useUtf8()) .utf8 else .utf16;
        const config = self.projectConfig(arena, params.textDocument.uri);
        const found = try lsp_actions.actionsFor(arena, self.io, doc_buf.source, config.lint, params.range.start.line, params.range.end.line, encoding);

        const results = try arena.alloc(lsp.types.CodeAction.Result, found.len);
        for (found, results) |action, *result| {
            const edits = try arena.alloc(lsp.types.TextEdit, action.edits.len);
            for (action.edits, edits) |e, *out| out.* = .{
                .range = .{
                    .start = .{ .line = e.start.line, .character = e.start.character },
                    .end = .{ .line = e.end.line, .character = e.end.character },
                },
                .newText = e.text,
            };
            var changes: std.json.ArrayHashMap([]const lsp.types.TextEdit) = .{};
            try changes.map.put(arena, params.textDocument.uri, edits);
            result.* = .{ .code_action = .{
                .title = action.title,
                .kind = .quickfix,
                .isPreferred = action.preferred,
                .edit = .{ .changes = changes },
            } };
        }
        return results;
    }

    pub fn @"kupcad/setParam"(_: *Handler, _: std.mem.Allocator, params: std.json.Value) !void {
        logger.debug("Received interactive parameter update: {}", .{params});
    }

    /// The settings for the document at `uri`, from the `.kupcad.json` nearest its folder, so
    /// they don't depend on the directory the editor started the server in. The defaults
    /// when there is none, or when it can't be read (logged).
    fn projectConfig(self: *Handler, arena: std.mem.Allocator, uri: []const u8) ProjectConfig {
        const document = documentPath(arena, uri) catch return .{};
        const path = document orelse return .{};
        const dir = std.fs.path.dirname(path) orelse return .{};
        const found = ProjectConfig.find(self.io, arena, dir) catch |err| {
            logger.warn("Could not look for {s} above {s}: {}", .{ project_config.FILE_NAME, dir, err });
            return .{};
        } orelse return .{};
        var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
        return ProjectConfig.load(self.io, arena, found, &where) catch |err| {
            logger.warn("{s}:{d}:{d}: {s}; using the default settings", .{ found, where.line, where.column, ProjectConfig.describeError(err) });
            return .{};
        };
    }

    fn runDiagnostics(self: *Handler, arena: std.mem.Allocator, uri: []const u8, source: []const u8) !void {
        const config = self.projectConfig(arena, uri);
        const diags = api.checkCode(self.allocator, self.io, source, config.lint) catch |err| {
            logger.err("Linter failed: {}", .{err});
            return;
        };
        defer api.freeDiagnostics(self.allocator, diags);

        var line_index = try api.LineIndex.init(arena, source);
        var lsp_diags: std.ArrayListUnmanaged(PublishedDiagnostic) = .empty;

        for (diags) |d| {
            const start_line = line_index.getLine(d.loc.offset);
            const start_char = self.getColumn(&line_index, d.loc.offset);

            var end_line = start_line;
            var end_char = start_char;

            if (d.loc.length > 0) {
                // Standard multi-character token
                const end_offset = d.loc.offset + d.loc.length;
                end_line = line_index.getLine(end_offset);
                end_char = self.getColumn(&line_index, end_offset);
            } else {
                // Zero-length token (EOF, missing semicolon, etc)
                // Draw a 1-character wide squiggly explicitly on the same line
                end_char = start_char + 1;
            }

            try lsp_diags.append(arena, .{
                .range = .{
                    .start = .{ .line = start_line, .character = start_char },
                    .end = .{ .line = end_line, .character = end_char },
                },
                .severity = switch (d.severity) {
                    .@"error" => 1,
                    .warning => 2,
                    .info => 3,
                },
                .message = d.message,
                .source = "kupcad",
                .code = d.rule,
            });
        }
        try self.publishDiagnostics(arena, uri, lsp_diags.items);
    }

    /// Replaces the diagnostics the editor shows for `uri` (none clears them).
    fn publishDiagnostics(self: *Handler, arena: std.mem.Allocator, uri: []const u8, diagnostics: []const PublishedDiagnostic) !void {
        const Params = struct { uri: []const u8, diagnostics: []const PublishedDiagnostic };
        try self.transport.writeNotification(self.io, arena, "textDocument/publishDiagnostics", Params, .{
            .uri = uri,
            .diagnostics = diagnostics,
        }, .{});
    }

    pub fn onResponse(
        _: *Handler,
        _: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        logger.warn("Received unexpected response: {?}", .{response.id});
    }
};

/// The file a `file:` URI names (percent-decoding it), or null for another scheme, such as
/// an editor's unsaved `untitled:` buffer.
pub fn documentPath(arena: std.mem.Allocator, uri: []const u8) !?[]const u8 {
    const parsed = std.Uri.parse(uri) catch return null;
    if (!std.mem.eql(u8, parsed.scheme, "file")) return null;
    const path = try parsed.path.toRawMaybeAlloc(arena);
    // Windows: file:///C:/dir/part.kup is the path C:/dir/part.kup.
    if (builtin.os.tag == .windows and path.len >= 3 and path[0] == '/' and path[2] == ':') return path[1..];
    return path;
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator) !@import("outcome.zig").Outcome {
    // 1. Setup global dependencies
    var mem_vfs = MemoryVfs.init(allocator);
    defer mem_vfs.deinit();

    // Imports may read workspace files (jailed to cwd by NativeVfs), but never write.
    var workspace_ro = NativeVfs.init(init.io, std.Io.Dir.cwd());
    var sandbox = ReadOnlyVfs.init(mem_vfs.vfs(), workspace_ro.vfs());

    var session = try ScriptSession.init(allocator, init.io);
    defer session.deinit();
    session.vm.vfs = sandbox.vfs();

    // 2. Viewport WebSocket server. Failure here must not take down language features.
    const preferred_port = preferredViewportPort(init.environ_map);
    var ws_storage: ViewportWsServer = undefined;
    var ws_server: ?*ViewportWsServer = null;
    if (ViewportWsServer.initWithFallback(allocator, init.io, preferred_port)) |srv| {
        ws_storage = srv;
        if (ws_storage.start()) |_| {
            ws_server = &ws_storage;
        } else |err| {
            logger.warn("Viewport server failed to start: {}; continuing without it", .{err});
            ws_storage.deinit();
        }
    } else |err| {
        logger.warn("Viewport server unavailable: {}; continuing without it", .{err});
    }
    defer if (ws_server) |ws| ws.deinit();

    // 3. Bind everything to the LSP Handler
    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler = Handler.init(allocator, init.io, transport, &session, ws_server, &mem_vfs, &sandbox, &workspace_ro);
    defer handler.deinit();

    // Messages come through the inbox, which evaluates the preview when the editor goes
    // quiet, cancels a stale evaluation and drops cancelled requests (cli/lsp_inbox.zig).
    var inbox = lsp_inbox.Inbox.init(allocator, init.io, transport, handler.previewWork());
    try inbox.start();
    defer inbox.deinit();

    try lsp.basic_server.run(init.io, allocator, &inbox.transport, &handler, logger.err);
    return .success;
}

test "LSP: every declared capability has its handler" {
    inline for (.{ .@"utf-8", .@"utf-16", .@"utf-32" }) |encoding| {
        lsp.basic_server.validateServerCapabilities(Handler, Handler.serverCapabilities(encoding));
    }
}
