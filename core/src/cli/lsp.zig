const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const api = @import("../api.zig");
const ast = @import("../core/ast.zig");
const manifest = @import("../stdlib/manifest.zig");

pub const DocumentBuffer = struct {
    uri: []const u8,
    source: []const u8,
    doc: ?api.Document = null,

    pub fn deinit(self: *DocumentBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.source);
        if (self.doc) |*d| d.deinit();
    }
};

const ScopeContext = struct {
    def_name: ?[]const u8 = null,
    class_name: ?[]const u8 = null,
};

fn getReturnTypeHint(method_name: []const u8) ?[]const u8 {
    // Check Global Functions
    for (manifest.global_functions) |g| {
        if (std.mem.eql(u8, g.name, method_name)) {
            return switch (g.category) {
                .primitive_3d, .csg_operator, .brep_op => "Geometry",
                .primitive_2d => "CrossSection",
                .transform => if (std.mem.eql(u8, method_name, "ghost") or std.mem.eql(u8, method_name, "highlight")) "Geometry" else "CrossSection",
                .file_io => "Geometry",
                else => null,
            };
        }
    }

    // Check Mesh Methods
    for (manifest.mesh_methods) |m| {
        if (std.mem.eql(u8, m.name, method_name)) {
            return switch (m.category) {
                .csg_operator, .transform => "Geometry",
                .workplane_method => "Workplane",
                .inspection_method => "Number",
                else => null,
            };
        }
    }

    return null;
}

fn getParamNames(method_name: []const u8, pos_count: usize) []const []const u8 {
    if (std.mem.eql(u8, method_name, "cube")) {
        if (pos_count <= 1) return &[_][]const u8{ "size", "y", "z", "center" };
        return &[_][]const u8{ "x", "y", "z", "center" };
    }
    if (std.mem.eql(u8, method_name, "square")) {
        if (pos_count <= 1) return &[_][]const u8{ "size", "y", "center" };
        return &[_][]const u8{ "x", "y", "center" };
    }

    if (std.mem.eql(u8, method_name, "sphere")) return &[_][]const u8{"radius"};
    if (std.mem.eql(u8, method_name, "cylinder")) return &[_][]const u8{ "r1", "r2", "h", "center", "segments" };
    if (std.mem.eql(u8, method_name, "circle")) return &[_][]const u8{ "radius", "segments" };

    if (std.mem.eql(u8, method_name, "translate") or
        std.mem.eql(u8, method_name, "rotate") or
        std.mem.eql(u8, method_name, "scale") or
        std.mem.eql(u8, method_name, "resize")) return &[_][]const u8{ "x", "y", "z" };

    if (std.mem.eql(u8, method_name, "mirror")) return &[_][]const u8{ "nx", "ny", "nz" };
    if (std.mem.eql(u8, method_name, "extrude")) return &[_][]const u8{ "height", "slices", "twist", "scale_x", "scale_y" };
    if (std.mem.eql(u8, method_name, "revolve")) return &[_][]const u8{ "segments", "degrees" };
    if (std.mem.eql(u8, method_name, "regular_polygon")) return &[_][]const u8{ "sides", "r" };
    if (std.mem.eql(u8, method_name, "offset")) return &[_][]const u8{ "delta", "join" };

    return &[_][]const u8{};
}

inline fn findEnclosingScope(doc: *const api.Document, start_node: ast.NodeIndex) ScopeContext {
    var current = start_node;
    var ctx = ScopeContext{};

    while (current != .none) {
        const p_idx = doc.parents[@intFromEnum(current)];
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
                            ctx.class_name = doc.tree.getString(@as(ast.StringId, @enumFromInt(nn.data)));
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

pub const Handler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    offset_encoding: lsp.offsets.Encoding = .@"utf-16",

    // Tracks open files with their full AST and side-tables retained in memory
    files: std.StringHashMapUnmanaged(DocumentBuffer) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Handler {
        return .{
            .allocator = allocator,
            .io = io,
            .transport = transport,
            .offset_encoding = .@"utf-16",
            .files = .empty,
        };
    }

    pub fn deinit(self: *Handler) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
    }

    fn log(self: *Handler, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.log.err("LSP: " ++ fmt, args);
    }

    pub fn initialize(
        self: *Handler,
        _: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        self.log("Initializing Server...", .{});

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

        const server_capabilities: lsp.types.ServerCapabilities = .{
            .positionEncoding = switch (self.offset_encoding) {
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
            .inlayHintProvider = .{ .bool = true },
        };

        if (builtin.mode == .Debug) {
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

    pub fn initialized(_: *Handler, _: std.mem.Allocator, _: lsp.types.InitializedParams) void {}

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
        self.log("Opened {s}", .{params.textDocument.uri});
        if (self.files.fetchRemove(params.textDocument.uri)) |kv| {
            var old_doc = kv.value;
            old_doc.deinit(self.allocator);
        }

        const uri_dup = try self.allocator.dupe(u8, params.textDocument.uri);
        const source_dup = try self.allocator.dupe(u8, params.textDocument.text);

        // Parse into full Document state
        const parsed_doc = api.Document.parse(self.allocator, source_dup) catch null;

        const doc_buf = DocumentBuffer{
            .uri = uri_dup,
            .source = source_dup,
            .doc = parsed_doc,
        };
        try self.files.put(self.allocator, uri_dup, doc_buf);

        try self.runDiagnostics(arena, params.textDocument.uri, params.textDocument.text);
    }

    pub fn @"textDocument/didChange"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidChangeParams,
    ) !void {
        self.log("Changed {s}", .{params.textDocument.uri});
        if (params.contentChanges.len > 0) {
            switch (params.contentChanges[0]) {
                .text_document_content_change_whole_document => |doc_change| {
                    if (self.files.getPtr(params.textDocument.uri)) |buf| {
                        self.allocator.free(buf.source);
                        if (buf.doc) |*d| d.deinit();

                        buf.source = try self.allocator.dupe(u8, doc_change.text);
                        buf.doc = api.Document.parse(self.allocator, buf.source) catch null;
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
        _ = arena;
        self.log("Closed {s}", .{params.textDocument.uri});
        if (self.files.fetchRemove(params.textDocument.uri)) |kv| {
            var old_doc = kv.value;
            old_doc.deinit(self.allocator);
        }
    }

    pub fn @"textDocument/formatting"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.document_formatting.Params,
    ) !?[]const lsp.types.TextEdit {
        self.log("Formatting requested for {s}", .{params.textDocument.uri});
        const doc_buf = self.files.get(params.textDocument.uri) orelse return null;
        const source = doc_buf.source;

        const formatted = api.formatCode(arena, source, .{}) catch |err| {
            self.log("Formatter failed: {}", .{err});
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
        self.log("Hover requested for {s}", .{params.textDocument.uri});
        const buf = self.files.get(params.textDocument.uri) orelse return null;
        const doc = buf.doc orelse return null;

        // Use lsp_kit's native positionToIndex offset resolver
        const target_offset = lsp.offsets.positionToIndex(buf.source, params.position, self.offset_encoding);

        // Find the token under the cursor offset
        var found_token_idx: ?u24 = null;
        for (doc.tokens.starts, 0..) |start, i| {
            const len = doc.tokens.lengths[i];
            if (target_offset >= start and target_offset < start + len) {
                found_token_idx = @intCast(i);
                break;
            }
        }

        const tok_idx = found_token_idx orelse return null;

        // Find the AST node associated with this token
        var found_node_idx: ast.NodeIndex = .none;
        for (doc.tree.nodes.items, 0..) |node, i| {
            if (node.main_token == tok_idx) {
                found_node_idx = @enumFromInt(i);
                break;
            }
        }

        if (found_node_idx == .none) return null;
        const target_node = doc.tree.getNode(found_node_idx).?;

        // Walk parents using `doc.parents` side-table to gather enclosing context
        const scope = findEnclosingScope(&doc, found_node_idx);
        const def_name = scope.def_name;
        const class_name = scope.class_name;

        // Build Markdown response string using std.Io.Writer.Allocating
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();

        if (target_node.tag == .identifier) {
            const name = doc.tree.getString(@as(ast.StringId, @enumFromInt(target_node.data)));
            const sym = doc.symbols[@intFromEnum(found_node_idx)];

            out.writer.print("```kupcad\n(variable) {s}\n```\n", .{name}) catch return null;
            out.writer.print("**Scope:** `{s}` (slot `{d}`)\n\n", .{ @tagName(sym.kind), sym.index }) catch return null;
        } else if (target_node.tag == .method_call) {
            const mc = doc.tree.methodCall(target_node);
            const m_name = doc.tree.getString(mc.method_name);
            out.writer.print("```kupcad\n(method) {s}(...)\n```\n", .{m_name}) catch return null;
        } else if (target_node.tag == .number) {
            const num_val = doc.tree.number(target_node);
            out.writer.print("```kupcad\n(number) {d}\n```\n", .{num_val}) catch return null;
        } else {
            out.writer.print("```kupcad\n({s})\n```\n", .{@tagName(target_node.tag)}) catch return null;
        }

        if (def_name) |dn| {
            out.writer.print("*Enclosing Method:* `{s}`\n", .{dn}) catch return null;
        }
        if (class_name) |cn| {
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
        params: lsp.types.InlayHint.Params, // ⚡ Updated from InlayHintParams
    ) !?[]const lsp.types.InlayHint {
        self.log("Inlay hints requested for {s}", .{params.textDocument.uri});
        const buf = self.files.get(params.textDocument.uri) orelse return null;
        const doc = buf.doc orelse return null;

        var hints = std.ArrayListUnmanaged(lsp.types.InlayHint).empty;
        var line_index = try api.LineIndex.init(arena, buf.source);

        for (doc.tree.nodes.items) |*node| {
            if (node.tag == .assignment) {
                const assign = doc.tree.assignment(node);
                const rhs_node = doc.tree.getNode(assign.value) orelse continue;

                if (rhs_node.tag == .method_call) {
                    const mc = doc.tree.methodCall(rhs_node);
                    const m_name = doc.tree.getString(mc.method_name);

                    if (getReturnTypeHint(m_name)) |type_hint| {
                        const lhs_tok = node.main_token;
                        const end_offset = doc.tokens.starts[lhs_tok] + doc.tokens.lengths[lhs_tok];

                        const line = line_index.getLine(end_offset);
                        const char = self.getColumn(&line_index, end_offset);

                        try hints.append(arena, .{
                            .position = .{ .line = line, .character = char },
                            .label = .{ .string = try std.fmt.allocPrint(arena, ": {s}", .{type_hint}) },
                            .kind = .Type,
                            .paddingLeft = false,
                            .paddingRight = false,
                        });
                    }
                }
            } else if (node.tag == .method_call) {
                const mc = doc.tree.methodCall(node);
                const m_name = doc.tree.getString(mc.method_name);
                const args = doc.tree.getNamedArgs(mc.args);

                // Count positional arguments
                var pos_count: usize = 0;
                for (args) |arg| {
                    if (arg.name == .none) pos_count += 1;
                }

                // Pass the count to get dynamic parameter names
                const param_names = getParamNames(m_name, pos_count);

                if (param_names.len > 0) {
                    for (args, 0..) |arg, arg_idx| {
                        if (arg_idx >= param_names.len) break;
                        // Skip if the user already provided an explicit keyword argument label
                        if (arg.name != .none) continue;

                        const arg_val_node = doc.tree.getNode(arg.value) orelse continue;
                        const arg_tok = arg_val_node.main_token;
                        const start_offset = doc.tokens.starts[arg_tok];

                        const line = line_index.getLine(start_offset);
                        const char = self.getColumn(&line_index, start_offset);

                        try hints.append(arena, .{
                            .position = .{ .line = line, .character = char },
                            .label = .{ .string = try std.fmt.allocPrint(arena, "{s}:", .{param_names[arg_idx]}) },
                            .kind = .Parameter,
                            .paddingLeft = false,
                            .paddingRight = true,
                        });
                    }
                }
            }
        }

        return hints.items;
    }

    fn runDiagnostics(self: *Handler, arena: std.mem.Allocator, uri: []const u8, source: []const u8) !void {
        const diags = api.checkCode(self.allocator, source, .{}) catch |err| {
            self.log("Linter crashed: {}", .{err});
            return;
        };
        defer api.freeDiagnostics(self.allocator, diags);

        const Position = struct { line: u32, character: u32 };
        const Range = struct { start: Position, end: Position };
        const Diagnostic = struct {
            range: Range,
            severity: u32,
            source: []const u8,
            message: []const u8,
        };
        const PublishDiagnosticsParams = struct {
            uri: []const u8,
            diagnostics: []const Diagnostic,
        };

        var line_index = try api.LineIndex.init(arena, source);
        var lsp_diags: std.ArrayListUnmanaged(Diagnostic) = .empty;

        for (diags) |d| {
            const start_line = line_index.getLine(d.loc.offset);
            const end_offset = d.loc.offset + if (d.loc.length > 0) d.loc.length else 1;
            const end_line = line_index.getLine(end_offset);
            const start_char = self.getColumn(&line_index, d.loc.offset);
            const end_char = self.getColumn(&line_index, end_offset);

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
            });
        }

        try self.transport.writeNotification(
            self.io,
            arena,
            "textDocument/publishDiagnostics",
            PublishDiagnosticsParams,
            .{
                .uri = uri,
                .diagnostics = lsp_diags.items,
            },
            .{},
        );
    }

    pub fn onResponse(
        self: *Handler,
        arena: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        _ = arena;
        self.log("Received unexpected response: {?}", .{response.id});
    }
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    var handler = Handler.init(allocator, init.io, transport);
    defer handler.deinit();

    try lsp.basic_server.run(
        init.io,
        allocator,
        transport,
        &handler,
        std.log.err,
    );
}
