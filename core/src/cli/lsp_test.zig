//! Drives the LSP `Handler` the way an editor does, through a transport that keeps every
//! message the server sends.

const std = @import("std");
const testing = std.testing;
const lsp = @import("lsp");
const Handler = @import("lsp.zig").Handler;
const documentPath = @import("lsp.zig").documentPath;
const FILE_NAME = @import("config.zig").FILE_NAME;
const limits = @import("../core/limits.zig");
const kernel = @import("../kernel/kernel.zig");
const SessionPreview = @import("lsp_preview.zig").SessionPreview;

const URI = "file:///work/part.kup";

/// Collects what the server writes; reading ends the stream (the handler is called directly).
const Outbox = struct {
    transport: lsp.Transport = .{ .vtable = &.{ .readJsonMessage = read, .writeJsonMessage = write } },
    messages: std.ArrayListUnmanaged([]u8) = .empty,

    fn read(_: *lsp.Transport, _: std.Io, _: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        return error.EndOfStream;
    }

    fn write(transport: *lsp.Transport, _: std.Io, json: []const u8) lsp.Transport.WriteError!void {
        const self: *Outbox = @alignCast(@fieldParentPtr("transport", transport));
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

/// A server with no viewport, running its scripts in this process, its documents only in
/// memory. Lives in place: the handler keeps pointers to the rest.
const Server = struct {
    preview: SessionPreview,
    outbox: Outbox,
    handler: Handler,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Server) !void {
        try self.preview.init(testing.allocator, testing.io, false);
        self.outbox = .{};
        self.handler = Handler.init(testing.allocator, testing.io, &self.outbox.transport, self.preview.preview(), null);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(self: *Server) void {
        self.arena.deinit();
        self.handler.deinit();
        self.outbox.deinit();
        self.preview.deinit();
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

    /// What the inbox does once the editor goes quiet.
    fn settle(self: *Server) void {
        if (self.handler.preview_pending) self.handler.evaluatePreview();
    }

    /// The markdown the server answers a hover at `line`, `character` with.
    fn hover(self: *Server, uri: []const u8, line: u32, character: u32) ?[]const u8 {
        const answer = self.handler.@"textDocument/hover"(self.arena.allocator(), .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = line, .character = character },
        }) orelse return null;
        return answer.contents.markup_content.value;
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
    server.settle();
    try server.change(URI, "cube(\n"); // doesn't parse
    server.settle();
    // The failure reaches the editor as a diagnostic, not the log.
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "publishDiagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "\"severity\":1") != null);
    try server.change(URI, "undefined_thing(1)\n"); // doesn't run
    server.preview.session.vm.mute_errors = true; // its runtime error would print to the test log
    server.settle();
    // A runtime error is the preview's to report, not a diagnostic: the document is clean.
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "\"diagnostics\":[]") != null);
    try server.change(URI, "cube(20)\n");
    server.settle();
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "\"diagnostics\":[]") != null);
    try server.close(URI);
}

test "LSP: closing a document clears its diagnostics and forgets its module" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    try server.open(URI, "cube(-1)\n"); // nonpositive-size
    try testing.expect(std.mem.indexOf(u8, server.outbox.last(), "nonpositive-size") != null);
    try testing.expectEqual(@as(usize, 1), server.preview.session.workspace.modules.items.len);

    try server.close(URI);
    // An editor keeps showing what it was last sent for a closed file.
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"" ++ URI ++ "\",\"diagnostics\":[]}}",
        server.outbox.last(),
    );
    try testing.expectEqual(@as(usize, 0), server.preview.session.workspace.modules.items.len);
    try testing.expectEqual(@as(usize, 0), server.preview.session.nodes.items.len);
    try testing.expectError(error.FileNotFound, server.preview.documents.vfs().readFile(testing.allocator, "/work/part.kup"));

    // Opening it again starts over.
    try server.open(URI, "cube(1)\n");
    try testing.expectEqual(@as(usize, 1), server.preview.session.workspace.modules.items.len);
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

test "LSP: a script that never ends doesn't hang the server" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try testing.expectEqual(limits.INTERACTIVE_INSTRUCTION_LIMIT, server.preview.session.vm.hooks.limit);

    // The same stop, sooner, so the test is quick.
    server.preview.session.vm.hooks.setLimit(10_000);
    server.preview.session.vm.mute_errors = true;
    try server.open(URI, "n = 0\nwhile true\n  n += 1\nend\n");
    server.settle(); // returns: the evaluation gave up
    try testing.expect(server.preview.session.nodes.items[0].is_stale);
}

test "LSP: edits are evaluated once, when the editor goes quiet" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    try server.open(URI, "cube(1)\n");
    try server.change(URI, "cube(2)\n");
    try server.change(URI, "cube(3)\n");
    // Each keystroke used to evaluate the whole model before the next one was read.
    try testing.expect(server.handler.preview_pending);
    try testing.expect(server.preview.session.nodes.items[0].cached_handle == null);

    server.settle();
    try testing.expect(!server.handler.preview_pending);
    try testing.expectApproxEqAbs(@as(f64, 27.0), kernel.volume(server.preview.session.nodes.items[0].cached_handle.?), 1e-9);
}

test "LSP: hovering a document that doesn't compile neither runs it nor logs an error" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    // Assigning to a built-in is a compile error. The hover logged it as an error, then ran
    // the half-compiled chunk, which crashed the VM (an assertion; undefined in release).
    try server.open(URI, "cube = 5\nx = 1\n");
    const answer = server.handler.@"textDocument/hover"(server.arena.allocator(), .{
        .textDocument = .{ .uri = URI },
        .position = .{ .line = 1, .character = 0 },
    });
    // The variable is described from the syntax alone; no run happened.
    try testing.expect(std.mem.indexOf(u8, answer.?.contents.markup_content.value, "(variable) x") != null);
    try testing.expect(std.mem.indexOf(u8, answer.?.contents.markup_content.value, "Volume") == null);
    try testing.expect(server.preview.hover.?.run == null);
}

test "LSP: open documents import each other, and editing one re-evaluates its importers" {
    // Documents were known by their URIs, which no import names: an import read the file
    // from wherever the server started, never the open (unsaved) one, and editing it
    // left the files importing it stale.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = "file:///work" });

    try server.open("file:///work/parts/hw.kup", "def bolt\n  cube(2)\nend\nexport bolt\n");
    try server.open("file:///work/parts/main.kup", "import { bolt } from \"./hw.kup\"\nbolt()\n");
    server.settle();
    const main_id = server.preview.session.workspace.path_to_id.get("parts/main.kup") orelse return error.TestExpectedModule;
    const hw_id = server.preview.session.workspace.path_to_id.get("parts/hw.kup") orelse return error.TestExpectedModule;
    try testing.expectEqualSlices(@TypeOf(hw_id), &.{hw_id}, server.preview.session.workspace.modules.items[@backingInt(main_id)].deps.items);
    try testing.expectApproxEqAbs(@as(f64, 8), kernel.volume(server.preview.session.nodes.items[@backingInt(main_id)].cached_handle.?), 1e-9);

    try server.change("file:///work/parts/hw.kup", "def bolt\n  cube(3)\nend\nexport bolt\n");
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 27), kernel.volume(server.preview.session.nodes.items[@backingInt(main_id)].cached_handle.?), 1e-9);
}

test "LSP: hovers are answered from one run of the document, until something changes" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "a = cube(2)\nb = a.translate(1, 0, 0)\n");

    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 0, 0).?, "**Volume:** `8.00`") != null);
    const run = server.preview.hover.?.run.?;
    // It used to run the whole document again for each hover.
    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 1, 0).?, "**Volume:** `8.00`") != null);
    try testing.expectEqual(run, server.preview.hover.?.run.?);

    // An edit (here, or in a file it imports) makes the next hover run it again.
    try server.change(URI, "a = cube(3)\n");
    try testing.expect(server.preview.hover == null);
    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 0, 0).?, "**Volume:** `27.00`") != null);
}

test "LSP: a hover counts a solid's vertices and faces without building its mesh" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "a = cube(2)\n");
    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 0, 0).?, "**Topology:** `8` Vertices, `12` Faces") != null);
}

test "LSP: hovering the last token of a document, and past it, finds the right token" {
    // Tokens are found by binary search; its edges are the first token, the last, and a
    // position after the last.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "first = 1\nsecond = 2\nlast = 3");
    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 0, 0).?, "(variable) first") != null);
    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 2, 0).?, "(variable) last") != null);
    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 2, 7).?, "(number) 3") != null);
    try testing.expect(server.hover(URI, 2, 9) == null);
}

test "LSP: a model that takes long to run still gets its hovers" {
    // The hover's run stopped at 500k instructions, before `a` existed, and showed nothing.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "n = 0\nwhile n < 200000\n  n += 1\nend\na = cube(2)\n");
    try testing.expect(std.mem.indexOf(u8, server.hover(URI, 4, 0).?, "**Volume:** `8.00`") != null);
}

test "LSP: a preview a message stopped runs again once the editor is quiet" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "cube(2)\n");

    // As the inbox does when a request arrives during the run.
    server.preview.session.vm.cancel_token.store(true, .release);
    server.handler.evaluatePreview();
    try testing.expect(server.handler.preview_pending);
    try testing.expect(server.preview.session.nodes.items[0].cached_handle == null);

    server.preview.session.vm.cancel_token.store(false, .release);
    server.settle();
    try testing.expect(!server.handler.preview_pending);
    try testing.expectApproxEqAbs(@as(f64, 8), kernel.volume(server.preview.session.nodes.items[0].cached_handle.?), 1e-9);
}

test "LSP: hovering a parameter or local doesn't show a same-named global's facts" {
    // Facts were looked up by name in the run's globals, so `x` inside a def showed the
    // script's `x`.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "x = cube(10)\ndef f(x)\n  x\nend\n");
    server.settle();
    const global = server.hover(URI, 0, 0) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, global, "3D Solid") != null);
    const param = server.hover(URI, 2, 2) orelse return error.NoHover;
    try testing.expect(std.mem.indexOf(u8, param, "3D Solid") == null);
}

test "LSP: positions are UTF-8 or UTF-16, never UTF-32, whatever the client offers first" {
    // UTF-32 was announced when offered first, while every column was counted in UTF-16.
    const General = std.meta.Child(@FieldType(@FieldType(lsp.types.InitializeParams, "capabilities"), "general"));
    const PositionEncoding = std.meta.Child(std.meta.Child(@FieldType(General, "positionEncodings")));
    const Offer = struct { offered: []const PositionEncoding, chosen: lsp.offsets.Encoding };
    for ([_]Offer{
        .{ .offered = &.{ .@"utf-32", .@"utf-16" }, .chosen = .@"utf-16" },
        .{ .offered = &.{ .@"utf-32", .@"utf-8" }, .chosen = .@"utf-8" },
        .{ .offered = &.{.@"utf-32"}, .chosen = .@"utf-16" },
    }) |offer| {
        var server: Server = undefined;
        try server.init();
        defer server.deinit();
        _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{ .general = .{ .positionEncodings = offer.offered } }, .rootUri = "file:///work" });
        try testing.expectEqual(offer.chosen, server.handler.offset_encoding);
    }
}

test "LSP: formatting answers the whole document formatted, and nothing for one that doesn't parse" {
    var s: Server = undefined;
    try s.init();
    defer s.deinit();
    try s.open(URI, "x=1+2\ncube( x )\n");
    const options: lsp.types.FormattingOptions = .{ .tabSize = 2, .insertSpaces = true };
    const edits = (try s.handler.@"textDocument/formatting"(s.arena.allocator(), .{ .textDocument = .{ .uri = URI }, .options = options })) orelse return error.NoEdits;
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqualStrings("x = 1 + 2\ncube(x)\n", edits[0].newText);
    try testing.expectEqual(@as(u32, 0), edits[0].range.start.line);
    try testing.expectEqual(@as(u32, 0), edits[0].range.start.character);

    try s.change(URI, "x = )\n");
    const none = try s.handler.@"textDocument/formatting"(s.arena.allocator(), .{ .textDocument = .{ .uri = URI }, .options = options });
    try testing.expect(none == null or none.?.len == 0);
}

test "LSP: inlay hints name a built-in's positional arguments" {
    var s: Server = undefined;
    try s.init();
    defer s.deinit();
    try s.open(URI, "cylinder(2, 5)\n");
    const hints = (try s.handler.@"textDocument/inlayHint"(s.arena.allocator(), .{
        .textDocument = .{ .uri = URI },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 1, .character = 0 } },
    })) orelse return error.NoHints;
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expectEqualStrings("r:", hints[0].label.string);
    try testing.expectEqual(@as(u32, 9), hints[0].position.character);
    try testing.expectEqualStrings("h:", hints[1].label.string);
}

test "LSP: completion offers methods after a dot and globals elsewhere" {
    var s: Server = undefined;
    try s.init();
    defer s.deinit();
    try s.open(URI, "part = cube(1)\npart.tra\ncu");
    const Labels = struct {
        fn of(items: []const lsp.types.completion.Item, label: []const u8) ?lsp.types.completion.Item {
            for (items) |item| if (std.mem.eql(u8, item.label, label)) return item;
            return null;
        }
    };
    const after_dot = (try s.handler.@"textDocument/completion"(s.arena.allocator(), .{ .textDocument = .{ .uri = URI }, .position = .{ .line = 1, .character = 8 } })).?.completion_items;
    try testing.expectEqual(lsp.types.completion.Item.Kind.Method, Labels.of(after_dot, "translate").?.kind.?);
    try testing.expect(Labels.of(after_dot, "cube") == null);
    const global = (try s.handler.@"textDocument/completion"(s.arena.allocator(), .{ .textDocument = .{ .uri = URI }, .position = .{ .line = 2, .character = 2 } })).?.completion_items;
    try testing.expectEqual(lsp.types.completion.Item.Kind.Function, Labels.of(global, "cube").?.kind.?);
    try testing.expect(Labels.of(global, "translate") == null);
}

test "LSP: document symbols list the defs, classes, modules and top-level variables" {
    var s: Server = undefined;
    try s.init();
    defer s.deinit();
    try s.open(URI, "def plate(w)\n  inner = w\n  cube(inner)\nend\nclass Box\nend\nmodule Parts\nend\nwidth = 3\nplate(width)");
    const result = (try s.handler.@"textDocument/documentSymbol"(s.arena.allocator(), .{ .textDocument = .{ .uri = URI } })) orelse return error.NoSymbols;
    const symbols = result.document_symbols;
    var names: std.ArrayListUnmanaged(u8) = .empty;
    defer names.deinit(testing.allocator);
    for (symbols) |sym| try names.print(testing.allocator, "{s}:{t} ", .{ sym.name, sym.kind });
    try testing.expectEqualStrings("plate:Function Box:Class Parts:Module width:Variable ", names.items);
}

test "LSP: a code action fixes the finding on the requested lines" {
    var s: Server = undefined;
    try s.init();
    defer s.deinit();
    try s.open(URI, "unused = 5\ncube(1)\n");
    const result = (try s.handler.@"textDocument/codeAction"(s.arena.allocator(), .{
        .textDocument = .{ .uri = URI },
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .context = .{ .diagnostics = &.{} },
    })) orelse return error.NoActions;
    var renames: usize = 0;
    for (result) |r| {
        const action = r.code_action;
        const edits = action.edit.?.changes.?.map.get(URI).?;
        if (std.mem.indexOf(u8, action.title, "_unused") != null) {
            renames += 1;
            try testing.expectEqualStrings("_unused", edits[0].newText);
        }
    }
    try testing.expectEqual(@as(usize, 1), renames);
}
