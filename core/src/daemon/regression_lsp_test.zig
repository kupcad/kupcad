//! Regression tests for issues found in the Oct 2026 audit.
//! Area: LSP, viewport WebSocket, workspace, watcher, session manager, wasm.

const std = @import("std");
const testing = std.testing;

const ws = @import("viewport_ws.zig");
const ViewportWsServer = ws.ViewportWsServer;
const Workspace = @import("../core/workspace.zig").Workspace;
const ScriptSession = @import("session.zig").ScriptSession;
const SessionManager = @import("session_manager.zig").SessionManager;
const Watcher = @import("watcher.zig").Watcher;
const ReadOnlyVfs = @import("../vfs/readonly.zig").ReadOnlyVfs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const api = @import("../api.zig");
const wasm = @import("../wasm.zig");

/// A realistic (~550 byte) upgrade request as sent by VS Code's Electron webview.
const browser_upgrade_request =
    "GET / HTTP/1.1\r\n" ++
    "Host: 127.0.0.1:9001\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Pragma: no-cache\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Code/1.95.0 Chrome/128.0.6613.186 Electron/32.2.1 Safari/537.36\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Origin: vscode-webview://1q2w3e4r5t6y7u8i9o0p\r\n" ++
    "Sec-WebSocket-Version: 13\r\n" ++
    "Accept-Encoding: gzip, deflate, br, zstd\r\n" ++
    "Accept-Language: en-US,en;q=0.9\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
    "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n" ++
    "\r\n";

fn requestWithOrigin(comptime origin: []const u8) []const u8 {
    return comptime blk: {
        const needle = "Origin: vscode-webview://1q2w3e4r5t6y7u8i9o0p\r\n";
        const idx = std.mem.indexOf(u8, browser_upgrade_request, needle).?;
        break :blk browser_upgrade_request[0..idx] ++ "Origin: " ++ origin ++ "\r\n" ++ browser_upgrade_request[idx + needle.len ..];
    };
}

// ---------------------------------------------------------------------------
// Finding 2: WebSocket handshake / origin / limits
// ---------------------------------------------------------------------------

test "LSP audit: handshake reader stops at end of headers instead of waiting for EOF" {
    // Trailing bytes model data the peer sends after the upgrade; the old readSliceShort
    // swallowed them (and on a live socket blocked forever waiting for 4096 bytes / EOF).
    const trailing = "\x88\x80\x00\x00\x00\x00";
    var reader = std.Io.Reader.fixed(browser_upgrade_request ++ trailing);

    const headers = try ws.readHttpHeaders(&reader);
    try testing.expect(browser_upgrade_request.len > 450);
    try testing.expectEqual(browser_upgrade_request.len, headers.len);
    try testing.expectEqualStrings(trailing, reader.buffered());

    const hs = try ws.parseHandshake(headers);
    try testing.expectEqualStrings("dGhlIHNhbXBsZSBub25jZQ==", hs.key);
    try testing.expectEqualStrings("vscode-webview://1q2w3e4r5t6y7u8i9o0p", hs.origin.?);
    // RFC 6455 section 1.3 example.
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &ws.computeAcceptKey(hs.key));
}

test "LSP audit: handshake rejects oversized headers and non-upgrade requests" {
    const filler: [ws.MAX_HANDSHAKE_BYTES]u8 = @splat('a');
    const big = "GET / HTTP/1.1\r\nX: " ++ filler ++ "\r\n\r\n";
    var src = std.Io.Reader.fixed(big);
    try testing.expectError(error.HeaderTooLarge, ws.readHttpHeaders(&src));

    try testing.expectError(error.NotWebSocketUpgrade, ws.parseHandshake("GET / HTTP/1.1\r\nHost: x\r\n\r\n"));
    try testing.expectError(error.MissingWebSocketKey, ws.parseHandshake("GET / HTTP/1.1\r\nupgrade: WebSocket\r\n\r\n"));
}

test "LSP audit: Origin allowlist only admits VS Code webviews and the local dev server" {
    try testing.expect(ws.isOriginAllowed("vscode-webview://abc123"));
    try testing.expect(ws.isOriginAllowed("http://localhost:5173"));
    try testing.expect(ws.isOriginAllowed("http://127.0.0.1:5173"));
    try testing.expect(ws.isOriginAllowed(null)); // non-browser local client

    try testing.expect(!ws.isOriginAllowed("https://evil.example"));
    try testing.expect(!ws.isOriginAllowed("http://localhost:5173.evil.example"));
    try testing.expect(!ws.isOriginAllowed("http://localhost:8080"));
    try testing.expect(!ws.isOriginAllowed("vscode-webview://"));
    try testing.expect(!ws.isOriginAllowed("null"));
}

test "LSP audit: incoming frames are bounded and must be masked" {
    // 127 => 64-bit length of 1 TiB
    var huge = std.Io.Reader.fixed("\x82\xff\x00\x00\x01\x00\x00\x00\x00\x00\x01\x02\x03\x04");
    try testing.expectError(error.FrameTooLarge, ws.readFrameHeader(&huge));

    var unmasked = std.Io.Reader.fixed("\x81\x05hello");
    try testing.expectError(error.UnmaskedClientFrame, ws.readFrameHeader(&unmasked));

    var ok = std.Io.Reader.fixed("\x81\x85\x01\x02\x03\x04abcde");
    const h = try ws.readFrameHeader(&ok);
    try testing.expectEqual(@as(u8, 1), h.opcode);
    try testing.expectEqual(@as(u64, 5), h.payload_len);
}

fn connect(io: std.Io, port: u16) !std.Io.net.Stream {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    return addr.connect(io, .{ .mode = .stream });
}

fn sendAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn waitForClients(server: *ViewportWsServer, n: usize) !void {
    var i: usize = 0;
    while (server.clientCount() != n) : (i += 1) {
        if (i > 2000) return error.Timeout;
        testing.io.sleep(std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}

test "LSP audit: live socket upgrade completes for a browser-sized request without EOF" {
    const io = testing.io;
    var server = try ViewportWsServer.init(testing.allocator, io, 0);
    defer server.deinit();
    try server.start();
    try testing.expect(server.port != 0); // ephemeral port is resolved and reportable

    const stream = try connect(io, server.port);
    defer stream.close(io);
    try sendAll(io, stream, browser_upgrade_request); // NOTE: socket stays open

    var r_buf: [ws.MAX_HANDSHAKE_BYTES]u8 = undefined;
    var r = stream.reader(io, &r_buf);
    const resp = try ws.readHttpHeaders(&r.interface);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 101"));
    try testing.expect(std.mem.indexOf(u8, resp, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "LSP audit: foreign Origin is refused with 403" {
    const io = testing.io;
    var server = try ViewportWsServer.init(testing.allocator, io, 0);
    defer server.deinit();
    try server.start();

    const stream = try connect(io, server.port);
    defer stream.close(io);
    try sendAll(io, stream, requestWithOrigin("https://evil.example"));

    var r_buf: [ws.MAX_HANDSHAKE_BYTES]u8 = undefined;
    var r = stream.reader(io, &r_buf);
    const resp = try ws.readHttpHeaders(&r.interface);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403"));
}

test "LSP audit: concurrent connections are capped and deinit wakes stalled handshakes" {
    const io = testing.io;
    var server = try ViewportWsServer.init(testing.allocator, io, 0);
    try server.start();

    var streams: [ws.MAX_CLIENTS]std.Io.net.Stream = undefined;
    for (&streams) |*s| s.* = try connect(io, server.port);
    defer for (&streams) |*s| s.close(io);
    try waitForClients(&server, ws.MAX_CLIENTS);

    // One over the cap: the server must close it instead of spawning another thread.
    const extra = try connect(io, server.port);
    defer extra.close(io);
    var r_buf: [64]u8 = undefined;
    var r = extra.reader(io, &r_buf);
    try testing.expectError(error.EndOfStream, r.interface.takeByte());
    try testing.expectEqual(ws.MAX_CLIENTS, server.clientCount());

    // All MAX_CLIENTS threads are blocked reading headers; deinit must still return.
    server.deinit();
}

test "LSP audit: broadcast never blocks on a client that stopped reading" {
    const io = testing.io;
    var server = try ViewportWsServer.init(testing.allocator, io, 0);
    defer server.deinit();
    try server.start();

    const stream = try connect(io, server.port);
    defer stream.close(io);
    try sendAll(io, stream, browser_upgrade_request);
    var r_buf: [ws.MAX_HANDSHAKE_BYTES]u8 = undefined;
    var r = stream.reader(io, &r_buf);
    _ = try ws.readHttpHeaders(&r.interface);
    // From here on the client never reads: kernel socket buffers fill after a few hundred KiB.

    const payload = try testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 0x5a);

    const start = std.Io.Clock.now(.awake, io);
    for (0..8) |_| try server.broadcastBinary(payload);
    const elapsed_ms = @divTrunc(start.durationTo(std.Io.Clock.now(.awake, io)).toNanoseconds(), std.time.ns_per_ms);
    // Old implementation wrote synchronously on the caller (LSP) thread and hung here.
    try testing.expect(elapsed_ms < 2000);
}

test "LSP audit: viewport server falls back to an ephemeral port when the preferred one is taken" {
    const io = testing.io;
    var first = try ViewportWsServer.init(testing.allocator, io, 0);
    defer first.deinit();
    // Without reuse_address on the second bind macOS/Linux may still allow it; only assert
    // that initWithFallback always yields a usable, non-zero port.
    var second = try ViewportWsServer.initWithFallback(testing.allocator, io, first.port);
    defer second.deinit();
    try testing.expect(second.port != 0);
}

// ---------------------------------------------------------------------------
// Finding 4: workspace updates / watcher re-reads the file
// ---------------------------------------------------------------------------

test "LSP audit: upsertModule replaces source and AST of an existing module" {
    var wsp = Workspace.init(testing.allocator);
    defer wsp.deinit();

    const id = try wsp.addModule("main.kup", "x = 1");
    try testing.expectError(error.DuplicateModule, wsp.addModule("main.kup", "x = 2"));

    const id2 = try wsp.upsertModule("main.kup", "import \"lib.kup\"\nx = 2");
    try testing.expectEqual(id, id2);
    try testing.expectEqualStrings("import \"lib.kup\"\nx = 2", wsp.modules.items[@backingInt(id)].source);

    // The AST must be re-parsed too, so dependency linking sees the new import.
    _ = try wsp.addModule("lib.kup", "y = 1");
    try wsp.linkDependencies();
    try testing.expectEqual(@as(usize, 1), wsp.modules.items[@backingInt(id)].deps.items.len);
}

test "LSP audit: watcher re-reads the file so re-evaluation is not stale" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const file_path = try testing.allocator.print("{s}/watched.kup", .{dir});
    defer testing.allocator.free(file_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = file_path, .data = "x = cube(10)\n" });

    var session = try ScriptSession.init(testing.allocator, testing.io);
    defer session.deinit();
    _ = try session.workspace.addModule(file_path, "x = cube(10)\n");
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    var watcher = try Watcher.init(&session, file_path, testing.io);
    defer watcher.deinit();
    watcher.is_one_shot = true;

    testing.io.sleep(std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    try cwd.writeFile(testing.io, .{ .sub_path = file_path, .data = "x = cube(20)\n" });
    try watcher.start();

    const id = session.workspace.path_to_id.get(file_path).?;
    try testing.expectEqualStrings("x = cube(20)\n", session.workspace.modules.items[@backingInt(id)].source);
}

// ---------------------------------------------------------------------------
// Finding 1: LSP VMs run on a read-only VFS
// ---------------------------------------------------------------------------

fn runScript(vm: *VM, source: []const u8) !void {
    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    if (vm.interpret(&out_chunk) != .ok) return error.RuntimeError;
}

test "LSP audit: sandboxed VM cannot write files via export_stl but can read workspace imports" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "victim.stl", .data = "original" });

    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    var disk_ro = NativeVfs.init(testing.io, tmp.dir);
    var sandbox = ReadOnlyVfs.init(mem.vfs(), disk_ro.vfs());

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = sandbox.vfs();
    try registry.registerStandardLibrary(&vm);

    try runScript(&vm, "cube(1).export_stl(\"victim.stl\")\ncube(1).export_stl(\"new.stl\")");

    // Nothing touched on disk.
    const victim = try tmp.dir.readFileAlloc(testing.io, "victim.stl", testing.allocator, .limited(1024));
    defer testing.allocator.free(victim);
    try testing.expectEqualStrings("original", victim);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "new.stl", .{}));
    try testing.expectEqual(@as(usize, 2), sandbox.discarded_writes);

    // Reads still fall through to the jailed workspace view (read-only imports).
    const read_back = try sandbox.vfs().readFile(testing.allocator, "victim.stl");
    defer testing.allocator.free(read_back);
    try testing.expectEqualStrings("original", read_back);
}

// ---------------------------------------------------------------------------
// Finding 6: SessionManager eviction vs. in-use sessions
// ---------------------------------------------------------------------------

test "LSP audit: evictLRU never frees a session that is still leased" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const p1 = try testing.allocator.print("{s}/a.kup", .{dir});
    defer testing.allocator.free(p1);
    const p2 = try testing.allocator.print("{s}/b.kup", .{dir});
    defer testing.allocator.free(p2);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(testing.io, .{ .sub_path = p1, .data = "" });
    try cwd.writeFile(testing.io, .{ .sub_path = p2, .data = "" });

    var manager = SessionManager.init(testing.allocator, testing.io, 1);
    defer manager.deinit();

    const lease = try manager.acquireSession(p1);
    // Capacity 1: before the fix this evicted (destroyed) the leased session.
    _ = try manager.getOrInitializeSession(p2);
    try testing.expect(manager.sessions.get(lease.id) == lease.session);
    lease.session.global_revision += 1; // would be a UAF under the old behaviour
    manager.release(lease);

    // Once released it is evictable again.
    const p3_session = try manager.acquireSession(p2);
    manager.release(p3_session);
}

// ---------------------------------------------------------------------------
// Finding 5: wasm build_model must have a valid Io
// ---------------------------------------------------------------------------

test "LSP audit: build_model_wasm runs scripts using benchmark without trapping" {
    const src =
        \\b = benchmark("t") do
        \\  1 + 1
        \\end
        \\cube(1)
    ;
    const fmt = "stl";
    var out_len: usize = 0;
    const res = wasm.build_model_wasm(src.ptr, src.len, fmt.ptr, fmt.len, false, &out_len);
    try testing.expect(res != null);
    try testing.expect(out_len > 84); // STL header + triangle count + at least one facet
    wasm.wasm_free(@constCast(res.?), out_len);
}
