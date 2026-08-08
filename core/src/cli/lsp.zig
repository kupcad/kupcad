const std = @import("std");
const lsp = @import("lsp");
const api = @import("../api.zig");

pub const DocumentBuffer = struct {
    uri: []const u8,
    text: std.ArrayListUnmanaged(u8),

    pub fn deinit(self: *DocumentBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        self.text.deinit(allocator);
    }
};

pub const Handler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,
    use_utf8: bool = false,

    // We need to store the open files in memory so the formatter can access their text
    files: std.StringHashMapUnmanaged(DocumentBuffer) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Handler {
        return .{ .allocator = allocator, .io = io, .transport = transport };
    }

    pub fn deinit(self: *Handler) void {
        // Clean up our file memory when the server shuts down
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
        arena: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        _ = arena;
        self.log("Initializing Server...", .{});

        if (request.capabilities.general) |general| {
            if (general.positionEncodings) |encodings| {
                for (encodings) |enc| {
                    if (enc == .@"utf-8") {
                        self.use_utf8 = true;
                        break;
                    }
                }
            }
        }

        return .{
            .serverInfo = .{
                .name = "kupcad-lsp",
                .version = "0.1.0",
            },
            .capabilities = .{
                .positionEncoding = if (self.use_utf8) .@"utf-8" else .@"utf-16",
                .textDocumentSync = .{
                    .text_document_sync_options = .{
                        .openClose = true,
                        .change = .Full,
                    },
                },
                // NEW: Tell VS Code we are ready to format documents!
                .documentFormattingProvider = .{ .bool = true },
            },
        };
    }

    pub fn @"textDocument/didOpen"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidOpenParams,
    ) !void {
        self.log("Opened {s}", .{params.textDocument.uri});

        // Prevent leaking if the client sends didOpen for an already tracked file
        if (self.files.fetchRemove(params.textDocument.uri)) |kv| {
            var old_doc = kv.value;
            old_doc.deinit(self.allocator);
        }

        const uri_dup = try self.allocator.dupe(u8, params.textDocument.uri);
        var text_buf = std.ArrayListUnmanaged(u8).empty;
        try text_buf.appendSlice(self.allocator, params.textDocument.text);

        const doc = DocumentBuffer{
            .uri = uri_dup,
            .text = text_buf,
        };

        try self.files.put(self.allocator, uri_dup, doc);
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
                    // Update our stored file text by reusing capacity to prevent fragmentation
                    if (self.files.getPtr(params.textDocument.uri)) |doc| {
                        doc.text.clearRetainingCapacity();
                        try doc.text.appendSlice(self.allocator, doc_change.text);
                    }
                    try self.runDiagnostics(arena, params.textDocument.uri, doc_change.text);
                },
                else => {},
            }
        }
    }

    // Clean up memory when the user closes the tab in VS Code
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

    // Handle the format request
    pub fn @"textDocument/formatting"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.document_formatting.Params,
    ) !?[]const lsp.types.TextEdit {
        self.log("Formatting requested for {s}", .{params.textDocument.uri});

        // Fetch the code from our internal state
        const doc = self.files.get(params.textDocument.uri) orelse return null;
        const source = doc.text.items;

        // Run the KupCAD formatter
        const formatted = api.formatCode(arena, source, .{}) catch |err| {
            self.log("Formatter failed: {}", .{err});
            return null; // Return null to indicate no changes on error
        };

        // Calculate the end position to replace the entire document
        var line_index = try api.LineIndex.init(arena, source);
        const end_offset: u32 = @intCast(source.len);
        const end_line = line_index.getLine(end_offset);
        const end_char = if (self.use_utf8)
            line_index.getUtf8Column(end_offset)
        else
            line_index.getUtf16Column(end_offset);

        // Create the TextEdit payload
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

            const start_char = if (self.use_utf8) line_index.getUtf8Column(d.loc.offset) else line_index.getUtf16Column(d.loc.offset);
            const end_char = if (self.use_utf8) line_index.getUtf8Column(end_offset) else line_index.getUtf16Column(end_offset);

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
