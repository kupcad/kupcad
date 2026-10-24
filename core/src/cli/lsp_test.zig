//! Drives the LSP `Handler` the way an editor does, through a transport that keeps every
//! message the server sends.

const std = @import("std");
const testing = std.testing;
const lsp = @import("lsp");
const Handler = @import("lsp.zig").Handler;
const documentPath = @import("lsp.zig").documentPath;
const SET_PARAMS_COMMAND = @import("lsp.zig").SET_PARAMS_COMMAND;
const PREVIEW_COMMAND = @import("lsp.zig").PREVIEW_COMMAND;
const Viewport = @import("lsp.zig").Viewport;
const FILE_NAME = @import("config.zig").FILE_NAME;
const limits = @import("../core/limits.zig");
const kernel = @import("../kernel/kernel.zig");
const SessionPreview = @import("lsp_preview.zig").SessionPreview;
const test_support = @import("../test_support.zig");

const URI = "file:///work/part.kup";

/// An editor that watches files for the server by paths relative to a folder.
const WATCHING_EDITOR: lsp.types.ClientCapabilities = .{ .workspace = .{
    .didChangeWatchedFiles = .{ .dynamicRegistration = true, .relativePatternSupport = true },
} };
const READS_SIZE = "import size from \"./size.json\"\ncube(size[:side])\n";

/// Collects what the server writes; reading ends the stream (the handler is called directly).
const Outbox = struct {
    transport: lsp.Transport = .{ .vtable = &.{ .readJsonMessage = read, .writeJsonMessage = write } },
    messages: std.ArrayList([]u8) = .empty,

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
        try self.initReading(false);
    }

    /// `read_workspace`: imports read the files in the workspace folder `initialize` names.
    fn initReading(self: *Server, read_workspace: bool) !void {
        try self.preview.init(testing.allocator, testing.io, read_workspace);
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

    /// The editor saw the watched file at `uri` change on disk.
    fn changeWatched(self: *Server, uri: []const u8) !void {
        const changes = [_]lsp.types.workspace.FileSystemWatcher.Event{.{ .uri = uri, .type = .Changed }};
        try self.handler.@"workspace/didChangeWatchedFiles"(self.arena.allocator(), .{ .changes = &changes });
    }

    /// How many of the messages the server sent hold `text`.
    fn sent(self: *const Server, text: []const u8) usize {
        var count: usize = 0;
        for (self.outbox.messages.items) |m| count += @intFromBool(std.mem.find(u8, m, text) != null);
        return count;
    }

    /// The editor runs `kupcad.setParams` with `arguments` (JSON text of the arguments' array).
    fn setParams(self: *Server, arguments: []const u8) !void {
        return self.command(SET_PARAMS_COMMAND, arguments);
    }

    /// The editor runs the server's `name` with `arguments` (JSON text of the arguments' array).
    fn command(self: *Server, name: []const u8, arguments: []const u8) !void {
        const arena = self.arena.allocator();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{});
        _ = try self.handler.@"workspace/executeCommand"(arena, .{ .command = name, .arguments = parsed.array.items });
    }

    fn volumeOf(self: *Server, module_path: []const u8) !f64 {
        const id = self.preview.session.workspace.path_to_id.get(module_path) orelse return error.TestExpectedModule;
        return kernel.volume(self.preview.session.nodes.items[@backingInt(id)].cached_handle orelse return error.TestExpectedModel);
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
    try testing.expect(std.mem.find(u8, server.outbox.last(), "publishDiagnostics") != null);
    try testing.expect(std.mem.find(u8, server.outbox.last(), "\"severity\":1") != null);
    try server.change(URI, "undefined_thing(1)\n"); // doesn't run
    server.preview.session.vm.mute_errors = true; // its runtime error would print to the test log
    server.settle();
    // A runtime error is the preview's to report, not a diagnostic: the document is clean.
    try testing.expect(std.mem.find(u8, server.outbox.last(), "\"diagnostics\":[]") != null);
    try server.change(URI, "cube(20)\n");
    server.settle();
    try testing.expect(std.mem.find(u8, server.outbox.last(), "\"diagnostics\":[]") != null);
    try server.close(URI);
}

test "LSP: closing a document clears its diagnostics and forgets its module" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();

    try server.open(URI, "cube(-1)\n"); // nonpositive-size
    try testing.expect(std.mem.find(u8, server.outbox.last(), "nonpositive-size") != null);
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
    const uri = try testing.allocator.print("file://{s}/parts/part.kup", .{root});
    defer testing.allocator.free(uri);

    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(uri, "def f\n  spare = 1\n  2\nend\nf\n");
    // LSP severity 1 is an error: the project's level, where the default is a warning.
    try testing.expect(std.mem.find(u8, server.outbox.last(), "\"severity\":1,") != null);
    try testing.expect(std.mem.find(u8, server.outbox.last(), "unused-variable") != null);
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
    try testing.expect(std.mem.find(u8, answer.?.contents.markup_content.value, "(variable) x") != null);
    try testing.expect(std.mem.find(u8, answer.?.contents.markup_content.value, "Volume") == null);
    try testing.expect(server.preview.hover.?.run == null);
}

test "LSP: open documents import each other, and one previewed again runs with its import's edit" {
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

    // The edited document is the one previewed, and runs with what it imports; its importer
    // runs with the edit once it is previewed again
    try server.change("file:///work/parts/hw.kup", "def bolt\n  cube(3)\nend\nexport bolt\n");
    server.settle();
    try testing.expect(server.preview.session.nodes.items[@backingInt(main_id)].is_stale);
    try server.change("file:///work/parts/main.kup", "import { bolt } from \"./hw.kup\"\nbolt()\n");
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 27), kernel.volume(server.preview.session.nodes.items[@backingInt(main_id)].cached_handle.?), 1e-9);
}

test "LSP: a document that doesn't parse doesn't stop the preview of another" {
    // The preview ran every open document, and stopped at the first that failed
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = "file:///work" });
    try server.open("file:///work/part.kup", "cube(1)\n");
    try server.open("file:///work/broken.kup", "cube(\n");
    try server.change("file:///work/part.kup", "cube(2)\n");
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 8), try server.volumeOf("part.kup"), 1e-9);
}

test "LSP: hovers are answered from one run of the document, until something changes" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "a = cube(2)\nb = a.translate(1, 0, 0)\n");

    try testing.expect(std.mem.find(u8, server.hover(URI, 0, 0).?, "**Volume:** `8.00`") != null);
    const run = server.preview.hover.?.run.?;
    // It used to run the whole document again for each hover.
    try testing.expect(std.mem.find(u8, server.hover(URI, 1, 0).?, "**Volume:** `8.00`") != null);
    try testing.expectEqual(run, server.preview.hover.?.run.?);

    // An edit (here, or in a file it imports) makes the next hover run it again.
    try server.change(URI, "a = cube(3)\n");
    try testing.expect(server.preview.hover == null);
    try testing.expect(std.mem.find(u8, server.hover(URI, 0, 0).?, "**Volume:** `27.00`") != null);
}

test "LSP: a hover counts a solid's vertices and faces without building its mesh" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "a = cube(2)\n");
    try testing.expect(std.mem.find(u8, server.hover(URI, 0, 0).?, "**Topology:** `8` Vertices, `12` Faces") != null);
}

test "LSP: hovering the last token of a document, and past it, finds the right token" {
    // Tokens are found by binary search; its edges are the first token, the last, and a
    // position after the last.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "first = 1\nsecond = 2\nlast = 3");
    try testing.expect(std.mem.find(u8, server.hover(URI, 0, 0).?, "(variable) first") != null);
    try testing.expect(std.mem.find(u8, server.hover(URI, 2, 0).?, "(variable) last") != null);
    try testing.expect(std.mem.find(u8, server.hover(URI, 2, 7).?, "(number) 3") != null);
    try testing.expect(server.hover(URI, 2, 9) == null);
}

test "LSP: a model that takes long to run still gets its hovers" {
    // The hover's run stopped at 500k instructions, before `a` existed, and showed nothing.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "n = 0\nwhile n < 200000\n  n += 1\nend\na = cube(2)\n");
    try testing.expect(std.mem.find(u8, server.hover(URI, 4, 0).?, "**Volume:** `8.00`") != null);
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
    try testing.expect(std.mem.find(u8, global, "3D Solid") != null);
    const param = server.hover(URI, 2, 2) orelse return error.NoHover;
    try testing.expect(std.mem.find(u8, param, "3D Solid") == null);
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
    var names: std.ArrayList(u8) = .empty;
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
        if (std.mem.find(u8, action.title, "_unused") != null) {
            renames += 1;
            try testing.expectEqualStrings("_unused", edits[0].newText);
        }
    }
    try testing.expectEqual(@as(usize, 1), renames);
}

test "LSP: saving a data file the document read updates the preview" {
    // The preview read it once, and showed the old data until the document was edited.
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = WATCHING_EDITOR, .rootUri = "file:///work" });
    // As the file on disk would be
    try server.preview.documents.vfs().writeFile("size.json", "{\"side\": 10}");
    try server.open("file:///work/part.kup", READS_SIZE);
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 1000), try server.volumeOf("part.kup"), 1e-9);
    // The editor is asked to watch the file, by its path in the workspace folder
    try testing.expectEqual(@as(usize, 1), server.sent("\"method\":\"client/registerCapability\""));
    try testing.expect(std.mem.find(u8, server.outbox.last(), "\"globPattern\":{\"baseUri\":\"file:///work\",\"pattern\":\"size.json\"}") != null);
    // A run that reads the same files asks nothing more
    try server.change("file:///work/part.kup", READS_SIZE ++ "# the same files\n");
    server.settle();
    try testing.expectEqual(@as(usize, 1), server.sent("\"method\":\"client/registerCapability\""));

    // A change to a file no run read (the extension reports every .kup file) runs nothing
    try server.changeWatched("file:///work/other.kup");
    try testing.expect(!server.handler.preview_pending);
    try server.preview.documents.vfs().writeFile("size.json", "{\"side\": 20}");
    try server.changeWatched("file:///work/size.json");
    try testing.expect(server.handler.preview_pending);
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 8000), try server.volumeOf("part.kup"), 1e-9);

    // Once nothing reads it, the editor stops watching it
    try server.change("file:///work/part.kup", "cube(1)\n");
    server.settle();
    try testing.expectEqual(@as(usize, 1), server.sent("\"method\":\"client/unregisterCapability\""));
    try testing.expectEqual(@as(usize, 1), server.sent("\"method\":\"client/registerCapability\""));
    try testing.expectEqual(@as(usize, 0), server.handler.watched_files.len);
}

test "LSP: an editor that can't watch files by relative path isn't asked to" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = "file:///work" });
    try server.preview.documents.vfs().writeFile("size.json", "{\"side\": 10}");
    try server.open("file:///work/part.kup", READS_SIZE);
    server.settle();
    try testing.expectEqual(@as(usize, 0), server.sent("registerCapability"));
}

test "LSP: the preview's run is a preview (CAD.preview?), where a script can lighten its model" {
    var server: Server = undefined;
    try server.initReading(false);
    defer server.deinit();
    try server.open("file:///p/main.kup", "CAD.preview? ? cube(1) : cube(2)\n");
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 1), try server.volumeOf("/p/main.kup"), 1e-9);
}

test "LSP: go to definition finds a name in the document, and an import's file under the workspace" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    const root_uri = "file:///work/my%20project";
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = root_uri });
    const uri = root_uri ++ "/parts/main.kup";
    try server.open(uri, "import { bolt } from \"../lib/hw parts.kup\"\nwidth = 4\ncube(width)\n");
    const arena = server.arena.allocator();

    const local = (try server.handler.@"textDocument/definition"(arena, .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 2, .character = 6 } })) orelse return error.NoDefinition;
    try testing.expectEqualStrings(uri, local.definition.location.uri);
    try testing.expectEqual(lsp.types.Range{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 5 } }, local.definition.location.range);

    // The path, resolved from the document's folder and percent-encoded
    const module = (try server.handler.@"textDocument/definition"(arena, .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 0, .character = 25 } })) orelse return error.NoDefinition;
    try testing.expectEqualStrings(root_uri ++ "/lib/hw%20parts.kup", module.definition.location.uri);

    // A built-in is nothing the document defines
    try testing.expect(try server.handler.@"textDocument/definition"(arena, .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 2, .character = 1 } }) == null);
}

test "LSP: a watched file's glob pattern matches only its path" {
    const pattern = try @import("lsp.zig").globEscaped(testing.allocator, "data/[a]*{b}?.json");
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("data/[[]a][*][{]b[}][?].json", pattern);
}

test "LSP: a module a document imports, changed on disk while not open, updates the preview" {
    // It ran from the VM's import cache, which kept the first version it read.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hw.kup", .data = "def bolt\n  cube(2)\nend\nexport bolt\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const root_uri = try std.mem.concat(testing.allocator, u8, &.{ "file://", root });
    defer testing.allocator.free(root_uri);
    const main_uri = try std.mem.concat(testing.allocator, u8, &.{ root_uri, "/main.kup" });
    defer testing.allocator.free(main_uri);
    const hw_uri = try std.mem.concat(testing.allocator, u8, &.{ root_uri, "/hw.kup" });
    defer testing.allocator.free(hw_uri);

    var server: Server = undefined;
    try server.initReading(true);
    defer server.deinit();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = root_uri });
    try server.open(main_uri, "import { bolt } from \"./hw.kup\"\nbolt()\n");
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 8), try server.volumeOf("main.kup"), 1e-9);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "hw.kup", .data = "def bolt\n  cube(3)\nend\nexport bolt\n" });
    try server.changeWatched(hw_uri);
    try testing.expect(server.handler.preview_pending);
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 27), try server.volumeOf("main.kup"), 1e-9);

    // A .kup file nothing imports runs nothing
    try server.changeWatched(try std.mem.concat(server.arena.allocator(), u8, &.{ root_uri, "/other.kup" }));
    try testing.expect(!server.handler.preview_pending);

    // Open, its text is what the preview reads, not the disk; closed, the disk again
    try server.open(hw_uri, "def bolt\n  cube(4)\nend\nexport bolt\n");
    try server.change(main_uri, "import { bolt } from \"./hw.kup\"\nbolt()\n");
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 64), try server.volumeOf("main.kup"), 1e-9);
    try server.changeWatched(hw_uri);
    try testing.expect(!server.handler.preview_pending);
    try server.close(hw_uri);
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 27), try server.volumeOf("main.kup"), 1e-9);

    // Deleted, it is forgotten, and the import says it is missing
    try tmp.dir.deleteFile(testing.io, "hw.kup");
    try server.changeWatched(hw_uri);
    try testing.expect(server.handler.preview_pending);
    try testing.expect(server.preview.session.workspace.path_to_id.get("hw.kup") == null);
}

test "LSP: viewportReady gives the socket's port and the protocol version of its frames" {
    var ws = try @import("viewport_ws.zig").ViewportWsServer.init(testing.allocator, testing.io, 0);
    defer ws.deinit();
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    server.handler.viewport = Viewport.ofSocket(&ws);
    server.handler.initialized(server.arena.allocator(), .{});
    const Notification = struct { method: []const u8, params: @import("lsp.zig").ViewportReady };
    const parsed = try std.json.parseFromSlice(Notification, testing.allocator, server.outbox.last(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings(@import("lsp.zig").VIEWPORT_READY_NOTIFICATION, parsed.value.method);
    try testing.expectEqual(ws.port, parsed.value.params.port);
    try testing.expectEqual(@import("../preview/frame.zig").PROTOCOL_VERSION, parsed.value.params.protocolVersion);
}

test "LSP: kupcad.setParams gives a document values, and the preview of it runs again with them" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = "file:///work" });
    try testing.expectEqualStrings(SET_PARAMS_COMMAND, Handler.serverCapabilities(.@"utf-16").executeCommandProvider.?.commands[0]);
    try server.open("file:///work/other.kup", "cube(1)\n");
    try server.open(URI, "a = cube(param(:w, default: 2))\n");
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 8), try server.volumeOf("part.kup"), 1e-9);

    try server.setParams("[{\"uri\": \"" ++ URI ++ "\", \"values\": {\"w\": 3}}]");
    try testing.expect(server.handler.preview_pending);
    server.settle();
    try testing.expectApproxEqAbs(@as(f64, 27), try server.volumeOf("part.kup"), 1e-9);
    // A hover reads a run with them too
    try testing.expect(std.mem.find(u8, server.hover(URI, 0, 0).?, "**Volume:** `27.00`") != null);

    // Values for a document the preview doesn't show wait for it
    try server.setParams("[{\"uri\": \"file:///work/other.kup\", \"values\": {\"w\": 4}}]");
    try testing.expect(!server.handler.preview_pending);
}

test "LSP: kupcad.setParams and kupcad.preview refuse arguments of another shape, and an unknown command is refused" {
    const warnings = @import("../test_support.zig").expectWarnings(); // each refusal is logged with why
    defer warnings.restore();
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.open(URI, "cube(param(:w, default: 2))\n");
    server.settle();
    const refused = [_][]const u8{
        "[]",
        "[{\"uri\": \"" ++ URI ++ "\"}]",
        "[{\"uri\": \"" ++ URI ++ "\", \"values\": [3]}]",
        "[{\"uri\": \"" ++ URI ++ "\", \"values\": {\"w\": [3]}}]",
    };
    for (refused) |arguments| try testing.expectError(error.InvalidParams, server.setParams(arguments));
    for ([_][]const u8{ "[]", "[{\"url\": \"" ++ URI ++ "\"}]", "[\"" ++ URI ++ "\"]" }) |arguments| {
        try testing.expectError(error.InvalidParams, server.command(PREVIEW_COMMAND, arguments));
    }
    try testing.expect(!server.handler.preview_pending);
    try testing.expectError(error.InvalidParams, server.handler.@"workspace/executeCommand"(server.arena.allocator(), .{ .command = "kupcad.unknown" }));
}

/// A viewport whose one viewer is the test: the frames sent, kept.
const Viewers = struct {
    frames: std.ArrayList([]u8) = .empty,

    const VTABLE: Viewport.VTable = .{ .viewers = viewers, .send = send };

    fn viewport(self: *Viewers) Viewport {
        return .{ .ptr = self, .vtable = &VTABLE, .port = 9001 };
    }

    fn viewers(_: *anyopaque) usize {
        return 1;
    }

    fn send(ptr: *anyopaque, frame: []const u8) anyerror!void {
        const self: *Viewers = @ptrCast(@alignCast(ptr));
        try self.frames.append(testing.allocator, try testing.allocator.dupe(u8, frame));
    }

    fn deinit(self: *Viewers) void {
        for (self.frames.items) |frame| testing.allocator.free(frame);
        self.frames.deinit(testing.allocator);
    }

    /// The header of the last frame sent, read into `arena`.
    fn last(self: *const Viewers, arena: std.mem.Allocator) !test_support.FrameHeader {
        return (try test_support.readFrame(arena, self.frames.items[self.frames.items.len - 1])).header;
    }
};

const LIB_URI = "file:///work/lib.kup";
const MAIN_URI = "file:///work/main.kup";

test "LSP: kupcad.preview shows the document chosen, again when a module it imports is edited" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    var viewers: Viewers = .{};
    defer viewers.deinit();
    server.handler.viewport = viewers.viewport();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = "file:///work" });
    try testing.expectEqualStrings(PREVIEW_COMMAND, Handler.serverCapabilities(.@"utf-16").executeCommandProvider.?.commands[1]);

    try server.open(LIB_URI, "side = param(:side, default: 2)\nexport side\n");
    try server.open(MAIN_URI, "import { side } from \"./lib.kup\"\ncube(param(:w, default: side))\n");
    try server.command(PREVIEW_COMMAND, "[{\"uri\": \"" ++ MAIN_URI ++ "\"}]");
    server.settle();
    const arena = server.arena.allocator();
    try testing.expectEqualStrings(MAIN_URI, (try viewers.last(arena)).document.?);

    // Editing the module it imports shows it again, not the module: it ran with the edit
    try server.change(LIB_URI, "side = param(:side, default: 3)\nexport side\n");
    server.settle();
    const shown = try viewers.last(arena);
    try testing.expectEqualStrings(MAIN_URI, shown.document.?);
    try testing.expectEqual(@as(i64, 3), shown.params.values.object.get("w").?.integer);
}

test "LSP: a frame the viewers have isn't sent again, unless one asks for it" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    var viewers: Viewers = .{};
    defer viewers.deinit();
    server.handler.viewport = viewers.viewport();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = "file:///work" });
    try server.open(MAIN_URI, "cube(2)\n");
    try server.open(LIB_URI, "x = 1\n");
    try server.command(PREVIEW_COMMAND, "[{\"uri\": \"" ++ MAIN_URI ++ "\"}]");
    server.settle();
    try testing.expectEqual(@as(usize, 1), viewers.frames.items.len);

    // An edit of a document it doesn't read runs nothing it shows
    try server.change(LIB_URI, "x = 2\n");
    server.settle();
    try testing.expectEqual(@as(usize, 1), viewers.frames.items.len);
    // A viewer just opened asks, and is sent it
    try server.command(PREVIEW_COMMAND, "[{\"uri\": \"" ++ MAIN_URI ++ "\"}]");
    server.settle();
    try testing.expectEqual(@as(usize, 2), viewers.frames.items.len);
    try testing.expectEqualSlices(u8, viewers.frames.items[0], viewers.frames.items[1]);
}

test "LSP: without kupcad.preview, the document last edited is shown" {
    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    var viewers: Viewers = .{};
    defer viewers.deinit();
    server.handler.viewport = viewers.viewport();
    _ = server.handler.initialize(server.arena.allocator(), .{ .capabilities = .{}, .rootUri = "file:///work" });
    try server.open(MAIN_URI, "cube(2)\n");
    try server.open(LIB_URI, "square(1)\n");
    server.settle();
    try testing.expectEqualStrings(LIB_URI, (try viewers.last(server.arena.allocator())).document.?);
}
