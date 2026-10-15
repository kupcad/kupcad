//! Drives the LSP `Handler` the way an editor does, through a transport that keeps every
//! message the server sends.

const std = @import("std");
const testing = std.testing;
const lsp = @import("lsp");
const Handler = @import("lsp.zig").Handler;
const documentPath = @import("lsp.zig").documentPath;
const FILE_NAME = @import("config.zig").FILE_NAME;
const ScriptSession = @import("../daemon/session.zig").ScriptSession;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const ReadOnlyVfs = @import("../vfs/readonly.zig").ReadOnlyVfs;

const URI = "file:///work/part.kup";

/// Collects what the server writes; reading ends the stream (the handler is called directly).
const Outbox = struct {
    transport: lsp.Transport = .{ .vtable = &.{ .readJsonMessage = read, .writeJsonMessage = write } },
    messages: std.ArrayListUnmanaged([]u8) = .empty,

    fn read(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn write(transport: *lsp.Transport, _: std.Io, json: []const u8) lsp.Transport.WriteError!void {
        const self: *Outbox = @fieldParentPtr("transport", transport);
        const copy = testing.allocator.dupe(u8, json) catch @panic("OOM");
        self.messages.append(testing.allocator, copy) catch @panic("OOM");
    }

    fn deinit(self: *Outbox) void {
        for (self.messages.items) |m| testing.allocator.free(m);
        self.messages.deinit(testing.allocator);
    }

    fn last(self: *const Outbox) []const u8 {
        return self.messages.items[self.messages.items.len - 1];
    }
};

/// A server with no viewport, its documents only in memory. Lives in place: the handler
/// keeps pointers to the rest.
const Server = struct {
    mem_vfs: MemoryVfs,
    sandbox: ReadOnlyVfs,
    session: ScriptSession,
    outbox: Outbox,
    handler: Handler,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Server) !void {
        self.mem_vfs = MemoryVfs.init(testing.allocator);
        self.sandbox = ReadOnlyVfs.init(self.mem_vfs.vfs(), null);
        self.session = try ScriptSession.init(testing.allocator, testing.io);
        self.session.vm.vfs = self.sandbox.vfs();
        self.outbox = .{};
        self.handler = Handler.init(testing.allocator, testing.io, &self.outbox.transport, &self.session, null, &self.mem_vfs, &self.sandbox);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Server) void {
        self.arena.deinit();
        self.handler.deinit();
        self.outbox.deinit();
        self.session.deinit();
        self.mem_vfs.deinit();
    }

    fn open(self: *Server, uri: []const u8, text: []const u8) !void {
        try self.handler.@"textDocument/didOpen"(self.arena.allocator(), .{
            .textDocument = .{ .uri = uri, .languageId = .{ .custom_value = "kupcad" }, .version = 1, .text = text },
        });
    }

    fn change(self: *Server, uri: []const u8, text: []const u8) !void {
        const changes = [_]lsp.types.TextDocument.ContentChangeEvent{
            .{ .text_document_content_change_whole_document = .{ .text = text } },
        };
        try self.handler.@"textDocument/didChange"(self.arena.allocator(), .{
            .textDocument = .{ .uri = uri, .version = 2 },
            .contentChanges = &changes,
        });
    }

    fn close(self: *Server, uri: []const u8) !void {
        try self.handler.@"textDocument/didClose"(self.arena.allocator(), .{ .textDocument = .{ .uri = uri } });
    }
};

test "LSP: editing a document logs nothing above debug" {
    // The runner fails a test that logs an error and prints its warnings: the handler used
    // to log every message it handled, and a script's own errors, at error level.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    try server.open(URI, "cube(10)\n");
    try server.change(URI, "cube(\n"); // doesn't parse
    try server.change(URI, "undefined_thing(1)\n"); // doesn't run
    try server.change(URI, "cube(20)\n");
    try server.close(URI);
}

test "LSP: closing a document clears its diagnostics and forgets its module" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    try server.open(URI, "cube(-1)\n"); // nonpositive-size
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "nonpositive-size") != null);
    try testing.expectEqual(@as(usize, 1), server.session.workspace.modules.items.len);

    try server.close(URI);
    // An editor keeps showing what it was last sent for a closed file.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"" ++ URI ++ "\",\"diagnostics\":[]}}",
        server.outbox.last(),
    );
    try testing.expectEqual(@as(usize, 0), server.session.workspace.modules.items.len);
    try testing.expectEqual(@as(usize, 0), server.session.nodes.items.len);
    try testing.expectError(error.FileNotFound, server.mem_vfs.vfs().readFile(testing.allocator, URI));

    // Opening it again starts over.
    try server.open(URI, "cube(1)\n");
    try testing.expectEqual(@as(usize, 1), server.session.workspace.modules.items.len);
}

test "LSP: documentPath reads file URIs and nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/work/part.kup", (try documentPath(a, URI)).?);
    try testing.expectEqualStrings("/work/my part.kup", (try documentPath(a, "file:///work/my%20part.kup")).?);
    try testing.expect(try documentPath(a, "untitled:Untitled-1") == null);
}

test "LSP: diagnostics follow the .kupcad.json nearest the document, not the cwd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "parts");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = FILE_NAME, .data = "{ \"lint\": { \"unused-variable\": \"error\" } }" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const uri = try std.fmt.allocPrint(testing.allocator, "file://{s}/parts/part.kup", .{root});
    defer testing.allocator.free(uri);

    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(uri, "def f\n  spare = 1\n  2\nend\nf\n");
    // LSP severity 1 is an error: the project's level, where the default is a warning.
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "\"severity\":1,") != null);
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "unused-variable") != null);
}
