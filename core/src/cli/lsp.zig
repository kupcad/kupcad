//! `kupcad lsp`: the language server on stdin and stdout. `Handler` answers the editor's
//! requests (hover, completion, formatting, diagnostics, code actions, symbols, inlay hints)
//! and, through a `Preview` (lsp_preview.zig), runs the last edited document for the
//! viewport WebSocket server (daemon/viewport_ws.zig) and for hovers: in a worker process
//! (lsp_worker.zig), so a script whose run crashes leaves the server running.

const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const build_info = @import("build_info");
const api = @import("../api.zig");
const lsp_actions = @import("lsp_actions.zig");
const lsp_inbox = @import("lsp_inbox.zig");
const lsp_hints = @import("lsp_hints.zig");
const ast = @import("../core/ast.zig");
const manifest = @import("../stdlib/manifest.zig");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const Outcome = @import("outcome.zig").Outcome;
const lsp_preview = @import("lsp_preview.zig");
const Preview = lsp_preview.Preview;
const SessionPreview = lsp_preview.SessionPreview;
const freeFiles = lsp_preview.freeFiles;
const lsp_worker = @import("lsp_worker.zig");
const Args = @import("args.zig").Args;
const viewport_ws = @import("../daemon/viewport_ws.zig");
const ViewportWsServer = viewport_ws.ViewportWsServer;
const ReadOnlyVfs = @import("../vfs/readonly.zig").ReadOnlyVfs;
const project_config = @import("config.zig");
const ProjectConfig = project_config.ProjectConfig;

const logger = std.log.scoped(.lsp);

/// Custom notification telling the editor where the viewport WebSocket listens.
pub const VIEWPORT_READY_NOTIFICATION = "kupcad/viewportReady";
/// Environment variable overriding the preferred viewport port ("0" = always ephemeral).
pub const VIEWPORT_PORT_ENV = "KUPCAD_VIEWPORT_PORT";
/// What the server's requests to the editor are called (`kupcad/1`, ...), so their answers
/// are known for its own.
const REQUEST_ID_PREFIX = "kupcad/";
/// The registration the data-file watchers are made under (Handler.watchFilesRead).
const WATCH_REGISTRATION_ID = REQUEST_ID_PREFIX ++ "data-files";
const WATCHED_FILES_METHOD = "workspace/didChangeWatchedFiles";

pub const USAGE =
    \\Usage: kupcad lsp
    \\
    \\Starts the language server on stdin and stdout. Editors start it themselves;
    \\the VS Code extension runs it for .kup files. It runs scripts in a worker
    \\process of its own (kupcad lsp --preview-worker), which it restarts if it crashes.
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

/// `client/registerCapability` of the data-file watchers, as it is sent.
const WatchRegistrations = struct {
    registrations: []const Registration,

    const Registration = struct {
        id: []const u8,
        method: []const u8,
        registerOptions: struct { watchers: []const Watcher },
    };
    /// A file by its path relative to the workspace folder, `baseUri`.
    const Watcher = struct { globPattern: struct { baseUri: []const u8, pattern: []const u8 } };
};

/// `client/unregisterCapability`, as it is sent (`unregisterations` is the protocol's spelling).
const WatchUnregistrations = struct {
    unregisterations: []const struct { id: []const u8, method: []const u8 },
};

/// `path` as a glob pattern matching only it: a glob's own characters are put in brackets
/// (`[*]`). A `]` on its own is no glob character. Caller owns the result.
pub fn globEscaped(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (path) |c| switch (c) {
        '*', '?', '[', '{', '}' => try out.print(allocator, "[{c}]", .{c}),
        else => try out.append(allocator, c),
    };
    return out.toOwnedSlice(allocator);
}

/// A diagnostic as `textDocument/publishDiagnostics` sends it.
const PublishedDiagnostic = struct {
    const Position = lsp.types.Position;

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

    /// Where scripts run: the preview and the run hovers read (lsp_preview.zig), in a worker
    /// process when the server runs (lsp_worker.zig), in this one in tests.
    preview: Preview,
    /// Null when the viewport server failed to start; language features keep working.
    ws_server: ?*ViewportWsServer,
    /// The workspace folder the editor opened (absolute, owned): documents are known by
    /// their path relative to it, so their relative imports find each other.
    root: ?[]u8 = null,
    /// The workspace folder as the editor named it (owned): the base the data-file watchers
    /// are relative to.
    root_uri: ?[]u8 = null,
    /// The editor can be asked to watch files, by paths relative to a folder
    /// (`workspace.didChangeWatchedFiles` with dynamic registration and relative patterns).
    can_watch_files: bool = false,
    /// The data files the editor watches for the preview (owned, sorted; watchFilesRead).
    watched_files: [][]u8 = &.{},
    /// The number of the last request the server sent the editor.
    last_request: u32 = 0,
    /// The module path of the document last edited, whose mesh the viewport shows (owned).
    preview_module: ?[]u8 = null,
    /// An edit hasn't been evaluated yet.
    preview_pending: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport: *lsp.Transport,
        preview: Preview,
        ws_server: ?*ViewportWsServer,
    ) Handler {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .offset_encoding = .@"utf-16",
            .files = .empty,
            .preview = preview,
            .ws_server = ws_server,
        };
    }

    /// Gives the preview the module's source; it is evaluated once the editor goes quiet
    /// (`evaluatePreview`, run by the inbox), not on every keystroke. The module is named
    /// by its path in the project (modulePath), and its unsaved text is what imports of it
    /// read; the modules importing it are evaluated again with it.
    fn syncSession(self: *Handler, module_path: []const u8, source: []const u8) !void {
        defer self.tellOfCrash();
        try self.preview.update(module_path, source);
        const previewed = try self.allocator.dupe(u8, module_path);
        if (self.preview_module) |old| self.allocator.free(old);
        self.preview_module = previewed;
        self.preview_pending = true;
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
        self.root_uri = try self.allocator.dupe(u8, root_uri);
        try self.preview.setRoot(trimmed);
    }

    /// Evaluates the preview and streams the edited document's mesh to the viewport. An edit
    /// that arrives meanwhile cancels it (the inbox sets the preview's cancel token).
    pub fn evaluatePreview(self: *Handler) void {
        defer self.tellOfCrash();
        self.preview_pending = false;
        const module_path = self.preview_module orelse return;
        const viewer = if (self.ws_server) |ws| (if (ws.clientCount() > 0) ws else null) else null;
        switch (self.preview.evaluate(self.allocator, module_path, viewer != null)) {
            .mesh => |glb| {
                defer self.allocator.free(glb);
                viewer.?.broadcastBinary(glb) catch |err| logger.warn("Viewport broadcast failed: {}", .{err});
            },
            .nothing, .failed => {},
            // Stopped by a message: run again once the editor is quiet. The modules it
            // finished stay evaluated, so the next run picks up where it stopped (and
            // tells which files they all read).
            .cancelled => {
                self.preview_pending = true;
                return;
            },
            // The worker running it ended (tellOfCrash says so); the next edit starts another.
            .crashed => return,
        }
        self.watchFilesRead();
    }

    /// Asks the editor to watch the files the preview's runs read as data (`import_json`,
    /// `import_stl`), when they differ from those it watches: saving one then runs the
    /// modules that read it again (`workspace/didChangeWatchedFiles`). The preview read them
    /// once, and showed the old data until the document was edited.
    fn watchFilesRead(self: *Handler) void {
        if (!self.can_watch_files) return;
        const root_uri = self.root_uri orelse return;
        const files = self.preview.filesRead(self.allocator) catch |err| {
            logger.warn("Could not learn which files the preview read: {}", .{err});
            return;
        };
        if (sameFiles(files, self.watched_files)) return freeFiles(self.allocator, files);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        self.sendWatchers(arena.allocator(), root_uri, files) catch |err| {
            logger.warn("Could not ask the editor to watch the files the preview read: {}", .{err});
            return freeFiles(self.allocator, files);
        };
        freeFiles(self.allocator, self.watched_files);
        self.watched_files = files;
    }

    /// Replaces the watchers registered for the data files with ones for `files`.
    fn sendWatchers(self: *Handler, arena: std.mem.Allocator, root_uri: []const u8, files: []const []u8) !void {
        if (self.watched_files.len > 0) {
            try self.sendRequest(arena, "client/unregisterCapability", WatchUnregistrations, .{
                .unregisterations = &.{.{ .id = WATCH_REGISTRATION_ID, .method = WATCHED_FILES_METHOD }},
            });
        }
        if (files.len == 0) return;
        const watchers = try arena.alloc(WatchRegistrations.Watcher, files.len);
        for (files, watchers) |path, *watcher| {
            watcher.* = .{ .globPattern = .{ .baseUri = root_uri, .pattern = try globEscaped(arena, path) } };
        }
        try self.sendRequest(arena, "client/registerCapability", WatchRegistrations, .{ .registrations = &.{.{
            .id = WATCH_REGISTRATION_ID,
            .method = WATCHED_FILES_METHOD,
            .registerOptions = .{ .watchers = watchers },
        }} });
    }

    fn sendRequest(self: *Handler, arena: std.mem.Allocator, method: []const u8, comptime Params: type, params: Params) !void {
        self.last_request += 1;
        const id = try arena.print(REQUEST_ID_PREFIX ++ "{d}", .{self.last_request});
        try self.transport.writeRequest(self.io, arena, .{ .string = id }, method, Params, params, .{});
    }

    fn sameFiles(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    /// Tells the user the process running scripts ended, whichever call noticed: they would
    /// otherwise see only a viewport that stopped updating, or hovers without values.
    fn tellOfCrash(self: *Handler) void {
        const subject = self.preview.takeCrash() orelse return;
        var buf: [512]u8 = undefined;
        const text = std.mem.print(&buf, "KupCAD: the worker process running scripts for the preview and hovers crashed (with {s}). The editor keeps working; the next edit starts a new one (the output panel says more).", .{subject}) catch "KupCAD: the worker process running scripts for the preview crashed; the next edit starts a new one.";
        self.transport.writeNotification(self.io, self.allocator, "window/showMessage", lsp.types.window.ShowMessageParams, .{ .type = .Warning, .message = text }, .{}) catch |err| {
            logger.warn("Could not tell the editor the preview crashed: {}", .{err});
        };
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
        return .{ .context = self, .pending = Hooks.pending, .run = Hooks.run, .cancel = self.preview.cancelToken() };
    }

    pub fn deinit(self: *Handler) void {
        if (self.preview_module) |m| self.allocator.free(m);
        if (self.root) |r| self.allocator.free(r);
        if (self.root_uri) |r| self.allocator.free(r);
        freeFiles(self.allocator, self.watched_files);
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

        // The client's preferred encoding among the two columns are computed in: UTF-8 or
        // UTF-16 (the default every client supports). UTF-32 was announced when offered
        // first, while every column was still counted in UTF-16.
        if (request.capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |encoding| {
                self.offset_encoding = switch (encoding) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32", .custom_value => continue,
                };
                break;
            }
        }

        if (request.capabilities.workspace) |workspace| if (workspace.didChangeWatchedFiles) |watched| {
            self.can_watch_files = (watched.dynamicRegistration orelse false) and (watched.relativePatternSupport orelse false);
        };

        const server_capabilities = serverCapabilities(self.offset_encoding);
        if (builtin.mode == .debug) {
            lsp.basic_server.validateServerCapabilities(Handler, server_capabilities);
        }

        return .{
            .serverInfo = .{
                .name = "kupcad-lsp",
                .version = build_info.version,
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

    /// `offset` as the editor counts it (lsp_actions.position, in the negotiated encoding).
    fn lspPosition(self: *const Handler, line_index: *const api.LineIndex, offset: u32) lsp.types.Position {
        const at = lsp_actions.position(line_index, offset, if (self.useUtf8()) .utf8 else .utf16);
        return .{ .line = at.line, .character = at.character };
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

        try self.runDiagnostics(arena, self.files.getPtr(uri_dup).?);
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
                        try self.runDiagnostics(arena, buf);
                    }
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
        var closed = (self.files.fetchRemove(uri) orelse return).value;
        defer closed.deinit(self.allocator);
        defer self.tellOfCrash();
        try self.preview.remove(closed.module_path);
        // A document another one imports is read from disk now, which may differ from the
        // text the editor had
        if (self.preview_module != null) self.preview_pending = true;
    }

    /// A file was saved, created or deleted on disk: one the editor watches for the preview
    /// (watchFilesRead), or a `.kup` file, which the extension reports. The modules that
    /// read it, as data or as an import of a module that isn't open, run again once the
    /// editor is quiet. An open document's own text is what the preview reads, not the disk.
    pub fn @"workspace/didChangeWatchedFiles"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.workspace.did_change_watched_files.Params,
    ) !void {
        defer self.tellOfCrash();
        var changed = false;
        for (params.changes) |change| {
            if (self.files.contains(change.uri)) continue;
            const path = try self.modulePath(arena, change.uri);
            if (!try self.preview.fileChanged(path)) continue;
            logger.debug("{s} changed on disk", .{path});
            changed = true;
        }
        if (changed and self.preview_module != null) self.preview_pending = true;
    }

    pub fn @"textDocument/formatting"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.document_formatting.Params,
    ) !?[]const lsp.types.TextEdit {
        logger.debug("Formatting requested for {s}", .{params.textDocument.uri});
        const doc_buf = self.files.get(params.textDocument.uri) orelse return null;
        const source = doc_buf.source;

        const doc = doc_buf.doc orelse return null;

        const config = self.projectConfig(arena, params.textDocument.uri);
        const formatted = api.formatCode(arena, source, config.fmt) catch |err| {
            logger.debug("Not formatted: {}", .{err});
            return null;
        };

        const line_index = &doc.line_index;
        var edits = std.ArrayList(lsp.types.TextEdit).empty;
        try edits.append(arena, .{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = self.lspPosition(line_index, @intCast(source.len)),
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
        const tok_idx = tokenAt(&doc, target_offset) orelse return null;

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

        // What running the document says about it (bounds, volume, ...). A variable's value
        // is in the run's globals only for a script-level variable: one outside any def
        // (the resolver leaves the script's own unresolved or local), or a top-level one
        // read inside a def (resolved as a global there). A def's parameter or local of
        // the same name used to show the global's facts.
        const sym_kind = doc.symbols[@backingInt(found_node_idx)].kind;
        const is_variable = target_node.tag == .identifier or target_node.tag == .assignment;
        const script_variable = sym_kind == .global or (scope.def_name == null and (sym_kind == .local or sym_kind == .unresolved));
        if (!is_variable or script_variable) {
            defer self.tellOfCrash();
            if (self.preview.hoverFacts(arena, buf.module_path, found_node_idx)) |facts| {
                if (facts) |text| out.writer.writeAll(text) catch return null;
            } else |err| logger.warn("Hover: could not run the document: {}", .{err});
        }

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

    /// The token `offset` is in, found by binary search (token starts are in order;
    /// a scan from the first token made a hover near the end of a long file cost its length).
    fn tokenAt(doc: *const api.Document, offset: usize) ?u24 {
        const starts = doc.tokens.starts;
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (starts[mid] <= offset) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const i = lo - 1;
        return if (offset < starts[i] + doc.tokens.lengths[i]) @intCast(i) else null;
    }

    pub fn @"textDocument/inlayHint"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.InlayHint.Params,
    ) !?[]const lsp.types.InlayHint {
        logger.debug("Inlay hints requested for {s}", .{params.textDocument.uri});
        const buf = self.files.get(params.textDocument.uri) orelse return null;
        const doc = buf.doc orelse return null;

        var hints = std.ArrayList(lsp.types.InlayHint).empty;
        const line_index = &doc.line_index;

        for (try lsp_hints.hints(arena, &doc)) |hint| {
            const label = switch (hint.kind) {
                .parameter => try arena.print("{s}:", .{hint.name}),
                .type => try arena.print(": {s}", .{hint.name}),
            };
            try hints.append(arena, .{
                .position = self.lspPosition(line_index, hint.offset),
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

        var items = std.ArrayList(lsp.types.completion.Item).empty;

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
            // An assembly's own (its exports are a solid's too, already listed).
            for (manifest.assembly_methods) |am| {
                for (manifest.mesh_methods) |mm| {
                    if (std.mem.eql(u8, mm.name, am.name)) break;
                } else try items.append(arena, .{ .label = am.name, .kind = .Method });
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

        var symbols = std.ArrayList(lsp.types.DocumentSymbol).empty;
        const line_index = &doc.line_index;

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
                    // The script's own variables: its block's statements (the check for no
                    // parent at all listed none, since the block is every statement's parent).
                    if (doc.parents[i] == doc.tree.root) {
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

                const range = lsp.types.Range{ .start = self.lspPosition(line_index, start_offset), .end = self.lspPosition(line_index, end_offset) };

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
        const doc = doc_buf.doc orelse return null;
        const found = try lsp_actions.actionsFor(arena, self.io, &doc, config.lint, params.range.start.line, params.range.end.line, encoding);

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

    /// Publishes the diagnostics of `buf`, from the document parsed when it arrived (every
    /// request reads that one; the linter used to parse the text again, and each request
    /// built its own line index).
    fn runDiagnostics(self: *Handler, arena: std.mem.Allocator, buf: *const DocumentBuffer) !void {
        const doc = &(buf.doc orelse return);
        const config = self.projectConfig(arena, buf.uri);
        const diags = api.checkDocument(self.allocator, self.io, doc, config.lint) catch |err| {
            logger.err("Linter failed: {}", .{err});
            return;
        };
        defer api.freeDiagnostics(self.allocator, diags);

        const line_index = &doc.line_index;
        var lsp_diags: std.ArrayList(PublishedDiagnostic) = .empty;

        for (diags) |d| {
            const start = self.lspPosition(line_index, d.loc.offset);
            // A zero-length finding (end of file, a missing token) gets a one-character
            // squiggle on its line.
            const end = if (d.loc.length > 0)
                self.lspPosition(line_index, d.loc.offset + d.loc.length)
            else
                lsp.types.Position{ .line = start.line, .character = start.character + 1 };

            try lsp_diags.append(arena, .{
                .range = .{ .start = start, .end = end },
                .severity = switch (d.severity) {
                    .@"error" => 1,
                    .warning => 2,
                    .info => 3,
                },
                .message = d.message,
                .source = "kupcad",
                .code = d.code(),
            });
        }
        try self.publishDiagnostics(arena, buf.uri, lsp_diags.items);
    }

    /// Replaces the diagnostics the editor shows for `uri` (none clears them).
    fn publishDiagnostics(self: *Handler, arena: std.mem.Allocator, uri: []const u8, diagnostics: []const PublishedDiagnostic) !void {
        const Params = struct { uri: []const u8, diagnostics: []const PublishedDiagnostic };
        try self.transport.writeNotification(self.io, arena, "textDocument/publishDiagnostics", Params, .{
            .uri = uri,
            .diagnostics = diagnostics,
        }, .{});
    }

    /// The editor's answer to a request: the server's own (sendRequest) need saying only
    /// when refused.
    pub fn onResponse(
        _: *Handler,
        _: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        if (response.id) |id| if (id == .string and std.mem.startsWith(u8, id.string, REQUEST_ID_PREFIX)) {
            switch (response.result_or_error) {
                .result => {},
                .@"error" => |refusal| logger.warn("The editor refused request {s}: {s}", .{ id.string, refusal.message }),
            }
            return;
        };
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
    if (builtin.target.os.tag == .windows and path.len >= 3 and path[0] == '/' and path[2] == ':') return path[1..];
    return path;
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args: *Args) !Outcome {
    if (args.next()) |arg| {
        if (!std.mem.eql(u8, arg, lsp_worker.WORKER_FLAG)) return error.UnknownArgument;
        try lsp_worker.runWorker(init.io, allocator);
        return .success;
    }

    // 1. Where scripts run: in a worker process (this executable, lsp_worker.zig), so one
    // that crashes leaves the server running. Without a path to the executable, here.
    const exe = std.process.executablePathAlloc(init.io, allocator) catch |err| blk: {
        logger.warn("Running previews in the server itself: its executable wasn't found ({})", .{err});
        break :blk null;
    };
    defer if (exe) |e| allocator.free(e);
    const worker_argv = [_][]const u8{ exe orelse "", "lsp", lsp_worker.WORKER_FLAG };
    var worker_preview = lsp_worker.WorkerPreview.init(allocator, init.io, &worker_argv);
    defer worker_preview.deinit();
    var session_preview: SessionPreview = undefined;
    if (exe == null) try session_preview.init(allocator, init.io, true);
    defer if (exe == null) session_preview.deinit();
    const preview = if (exe != null) worker_preview.preview() else session_preview.preview();

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

    var handler = Handler.init(allocator, init.io, transport, preview, ws_server);
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
