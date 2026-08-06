const std = @import("std");
const lsp = @import("lsp");
const api = @import("../api.zig");

pub const Handler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: *lsp.Transport,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Handler {
        return .{ .allocator = allocator, .io = io, .transport = transport };
    }

    pub fn deinit(self: *Handler) void {
        _ = self;
    }

    /// Uses std.log to safely bypass ReleaseFast optimizations and the 0.16 IO changes
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
        _ = request;
        self.log("Initializing Server...", .{});

        return .{
            .serverInfo = .{
                .name = "kupcad-lsp",
                .version = "0.1.0",
            },
            .capabilities = .{
                .textDocumentSync = .{
                    .text_document_sync_options = .{
                        .openClose = true,
                        .change = .Full, // We want the full text string on every keystroke
                    },
                },
            },
        };
    }

    pub fn @"textDocument/didOpen"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidOpenParams,
    ) !void {
        self.log("Opened {s}", .{params.textDocument.uri});
        try self.runDiagnostics(arena, params.textDocument.uri, params.textDocument.text);
    }

    pub fn @"textDocument/didChange"(
        self: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TextDocument.DidChangeParams,
    ) !void {
        self.log("Changed {s}", .{params.textDocument.uri});
        if (params.contentChanges.len > 0) {
            // Because we requested .Full sync, the change event contains the entire file text
            switch (params.contentChanges[0]) {
                .text_document_content_change_whole_document => |doc| {
                    try self.runDiagnostics(arena, params.textDocument.uri, doc.text);
                },
                else => {},
            }
        }
    }

    /// Evaluates the code using KupCAD's core and sends squiggly lines to VS Code
    fn runDiagnostics(self: *Handler, arena: std.mem.Allocator, uri: []const u8, source: []const u8) !void {
        // Run the KupCAD linter
        const diags = api.checkCode(self.allocator, source, .{}) catch |err| {
            self.log("Linter crashed: {}", .{err});
            return;
        };
        defer {
            for (diags) |d| self.allocator.free(d.message);
            self.allocator.free(diags);
        }

        // 2. Define our own lightweight, spec-compliant LSP structs
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

        // Initialize the LineIndex to accurately map flat byte offsets to UTF-16 LSP coordinates
        var line_index = try api.LineIndex.init(arena, source);

        // Map KupCAD Diagnostics to LSP Diagnostics
        var lsp_diags: std.ArrayListUnmanaged(Diagnostic) = .empty;

        for (diags) |d| {
            // Use the LineIndex to get exact 0-indexed line numbers and UTF-16 character columns
            const start_line = line_index.getLine(d.loc.offset);
            const start_char = line_index.getUtf16Column(d.loc.offset);

            // Calculate the end offset, defaulting to 1 character wide if length is 0
            const end_offset = d.loc.offset + if (d.loc.length > 0) d.loc.length else 1;

            const end_line = line_index.getLine(end_offset);
            const end_char = line_index.getUtf16Column(end_offset);

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

        self.log("Publishing {d} diagnostics", .{lsp_diags.items.len});

        // Send the notification to VS Code
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

    // Pass the transport and io objects into the handler
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
