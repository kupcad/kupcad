const std = @import("std");
const test_support = @import("../test_support.zig");
const testing = std.testing;
const ws = @import("viewport_ws.zig");
const ViewportWsServer = ws.ViewportWsServer;

/// Upper bound for any condition wait / blocking socket read in these tests.
const WAIT_TIMEOUT_MS: i64 = 5000;
const POLL_MS: i64 = 1;
/// Broadcasting to a stalled client must return well within this (it used to hang forever).
const BROADCAST_BUDGET_MS: i64 = 2000;

const SEC_WEBSOCKET_KEY = "dGhlIHNhbXBsZSBub25jZQ==";
/// RFC 6455 section 1.3: accept key for SEC_WEBSOCKET_KEY.
const SEC_WEBSOCKET_ACCEPT = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
const WEBVIEW_ORIGIN = "vscode-webview://1q2w3e4r5t6y7u8i9o0p";

/// A realistic (~550 byte) upgrade request as sent by VS Code's Electron webview.
fn upgradeRequest(comptime origin_line: []const u8) []const u8 {
    return "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:9001\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Pragma: no-cache\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Code/1.95.0 Chrome/128.0.6613.186 Electron/32.2.1 Safari/537.36\r\n" ++
        "Upgrade: websocket\r\n" ++
        origin_line ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Accept-Encoding: gzip, deflate, br, zstd\r\n" ++
        "Accept-Language: en-US,en;q=0.9\r\n" ++
        "Sec-WebSocket-Key: " ++ SEC_WEBSOCKET_KEY ++ "\r\n" ++
        "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n" ++
        "\r\n";
}
const browser_upgrade_request = upgradeRequest("Origin: " ++ WEBVIEW_ORIGIN ++ "\r\n");

// ---------------------------------------------------------------------------
// Handshake / Origin / frame limits (pure parsing)
// ---------------------------------------------------------------------------

test "ViewportWs: handshake reader stops at end of headers instead of waiting for EOF" {
    // Bytes after the headers model data the peer sends after the upgrade; the old
    // readSliceShort swallowed them (and on a live socket blocked waiting for EOF).
    const trailing = "\x88\x80\x00\x00\x00\x00";
    var reader = std.Io.Reader.fixed(browser_upgrade_request ++ trailing);

    const headers = try ws.readHttpHeaders(&reader);
    try testing.expect(browser_upgrade_request.len > 450);
    try testing.expectEqual(browser_upgrade_request.len, headers.len);
    try testing.expectEqualStrings(trailing, reader.buffered());

    const hs = try ws.parseHandshake(headers);
    try testing.expectEqualStrings(SEC_WEBSOCKET_KEY, hs.key);
    try testing.expectEqualStrings(WEBVIEW_ORIGIN, hs.origin.?);
    try testing.expectEqualStrings(SEC_WEBSOCKET_ACCEPT, &ws.computeAcceptKey(hs.key));
}

test "ViewportWs: readHttpHeaders rejects oversized requests" {
    // Guards the MAX_HANDSHAKE_BYTES cap on upgrade requests.
    const filler: [ws.MAX_HANDSHAKE_BYTES]u8 = @splat('a');
    var big = std.Io.Reader.fixed("GET / HTTP/1.1\r\nX: " ++ filler ++ "\r\n\r\n");
    try testing.expectError(error.HeaderTooLarge, ws.readHttpHeaders(&big));
}

test "ViewportWs: parseHandshake validates method, Upgrade and key" {
    const key_line = "Sec-WebSocket-Key: " ++ SEC_WEBSOCKET_KEY ++ "\r\n";
    const cases = [_]struct { req: []const u8, err: anyerror }{
        .{ .req = "GET / HTTP/1.1\r\nHost: x\r\n" ++ key_line ++ "\r\n", .err = error.NotWebSocketUpgrade },
        .{ .req = "POST / HTTP/1.1\r\nUpgrade: websocket\r\n" ++ key_line ++ "\r\n", .err = error.NotWebSocketUpgrade },
        .{ .req = "GET / HTTP/1.1\r\nUpgrade: h2c\r\n" ++ key_line ++ "\r\n", .err = error.NotWebSocketUpgrade },
        .{ .req = "GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n", .err = error.MissingWebSocketKey },
        .{ .req = "GET / HTTP/1.1\r\nUpgrade: websocket\r\nSec-WebSocket-Key: short\r\n\r\n", .err = error.MissingWebSocketKey },
        // Headers after the blank line are body, not headers.
        .{ .req = "GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n" ++ key_line, .err = error.MissingWebSocketKey },
    };
    for (cases) |case| try testing.expectError(case.err, ws.parseHandshake(case.req));

    // Header names are case-insensitive and values are trimmed.
    const hs = try ws.parseHandshake("GET / HTTP/1.1\r\nupgrade:  WebSocket \r\nsec-websocket-key: " ++ SEC_WEBSOCKET_KEY ++ "\r\n\r\n");
    try testing.expectEqualStrings(SEC_WEBSOCKET_KEY, hs.key);
    try testing.expect(hs.origin == null);
}

test "ViewportWs: Origin allowlist only admits VS Code webviews and the local dev server" {
    // Guards against foreign web pages opening the viewport socket.
    const cases = [_]struct { origin: ?[]const u8, allowed: bool }{
        .{ .origin = "vscode-webview://abc123", .allowed = true },
        .{ .origin = "http://localhost:5173", .allowed = true },
        .{ .origin = "http://127.0.0.1:5173", .allowed = true },
        .{ .origin = null, .allowed = true }, // non-browser local client
        .{ .origin = "https://evil.example", .allowed = false },
        .{ .origin = "http://localhost:5173.evil.example", .allowed = false },
        .{ .origin = "http://localhost:8080", .allowed = false },
        .{ .origin = "https://localhost:5173", .allowed = false },
        .{ .origin = "vscode-webview://", .allowed = false },
        .{ .origin = "null", .allowed = false },
        .{ .origin = "", .allowed = false },
    };
    for (cases) |case| {
        errdefer std.debug.print("origin: {?s}\n", .{case.origin});
        try testing.expectEqual(case.allowed, ws.isOriginAllowed(case.origin));
    }
}

test "ViewportWs: incoming frames are bounded and must be masked" {
    // Guards the incoming frame size cap and RFC 6455 client masking.
    const rejected = [_]struct { bytes: []const u8, err: anyerror }{
        // 127 => 64-bit length of 1 TiB.
        .{ .bytes = "\x82\xff\x00\x00\x01\x00\x00\x00\x00\x00\x01\x02\x03\x04", .err = error.FrameTooLarge },
        // One byte over MAX_INCOMING_FRAME_BYTES (64 KiB + 1).
        .{ .bytes = "\x82\xff\x00\x00\x00\x00\x00\x01\x00\x01\x01\x02\x03\x04", .err = error.FrameTooLarge },
        .{ .bytes = "\x81\x05hello", .err = error.UnmaskedClientFrame },
    };
    for (rejected) |case| {
        var r = std.Io.Reader.fixed(case.bytes);
        try testing.expectError(case.err, ws.readFrameHeader(&r));
    }

    const accepted = [_]struct { bytes: []const u8, opcode: u8, len: u64 }{
        .{ .bytes = "\x81\x85\x01\x02\x03\x04abcde", .opcode = 0x1, .len = 5 },
        .{ .bytes = "\x82\xfe\x00\xc8\x01\x02\x03\x04", .opcode = 0x2, .len = 200 },
    };
    for (accepted) |case| {
        var r = std.Io.Reader.fixed(case.bytes);
        const h = try ws.readFrameHeader(&r);
        try testing.expectEqual(case.opcode, h.opcode);
        try testing.expectEqual(case.len, h.payload_len);
        try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, h.mask);
    }
}

// ---------------------------------------------------------------------------
// Live viewport socket (ephemeral ports, bounded waits)
// ---------------------------------------------------------------------------

fn connect(port: u16) !std.Io.net.Stream {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    return addr.connect(testing.io, .{ .mode = .stream });
}

fn sendAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = stream.writer(testing.io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn sleepMs(ms: i64) void {
    testing.io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

fn waitForClients(server: *ViewportWsServer, n: usize) !void {
    var waited: i64 = 0;
    while (server.clientCount() != n) : (waited += POLL_MS) {
        if (waited > WAIT_TIMEOUT_MS) return error.Timeout;
        sleepMs(POLL_MS);
    }
}

/// Bounds a blocking read: unless disarmed within WAIT_TIMEOUT_MS, shuts the stream down so
/// the read fails (EndOfStream) instead of hanging the test run.
const Watchdog = struct {
    stream: std.Io.net.Stream,
    disarmed: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn arm(self: *Watchdog) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *Watchdog) void {
        var waited: i64 = 0;
        while (!self.disarmed.load(.acquire)) : (waited += POLL_MS) {
            if (waited > WAIT_TIMEOUT_MS) {
                self.fired.store(true, .release);
                self.stream.shutdown(testing.io, .both) catch {};
                return;
            }
            sleepMs(POLL_MS);
        }
    }

    /// Stops the watchdog; fails if it had to fire.
    fn disarm(self: *Watchdog) !void {
        self.disarmed.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fired.load(.acquire)) return error.Timeout;
    }
};

/// Client side of one connection with a buffered reader.
const TestClient = struct {
    stream: std.Io.net.Stream,
    r_buf: [ws.MAX_HANDSHAKE_BYTES]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,

    fn open(self: *TestClient, port: u16) !void {
        self.* = .{ .stream = try connect(port) };
        self.reader = self.stream.reader(testing.io, &self.r_buf);
    }

    fn close(self: *TestClient) void {
        self.stream.close(testing.io);
    }

    /// Sends `request` and returns the response header block (bounded wait).
    fn handshake(self: *TestClient, request: []const u8) ![]const u8 {
        try sendAll(self.stream, request);
        var dog = Watchdog{ .stream = self.stream };
        try dog.arm();
        const resp = ws.readHttpHeaders(&self.reader.interface);
        try dog.disarm();
        return resp;
    }
};

/// Re-broadcasts `payload` until `client` receives a frame: `broadcastBinary` skips clients
/// whose upgrade is still being registered, so a single broadcast right after the 101 can race.
fn receiveBroadcast(server: *ViewportWsServer, client: *TestClient, payload: []const u8, out: []u8) !void {
    const Pump = struct {
        fn run(srv: *ViewportWsServer, bytes: []const u8, stop: *std.atomic.Value(bool)) void {
            var waited: i64 = 0;
            while (!stop.load(.acquire) and waited < WAIT_TIMEOUT_MS) : (waited += POLL_MS) {
                srv.broadcastBinary(bytes) catch {};
                sleepMs(POLL_MS);
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const pump = try std.Thread.spawn(.{}, Pump.run, .{ server, payload, &stop });
    defer pump.join();
    defer stop.store(true, .release);

    var dog = Watchdog{ .stream = client.stream };
    try dog.arm();
    defer dog.disarm() catch {};

    const r = &client.reader.interface;
    const head = try r.takeArray(2);
    try testing.expectEqual(@as(u8, 0x82), head[0]); // FIN | binary
    try testing.expectEqual(payload.len, head[1]); // unmasked, 7-bit length
    try r.readSliceAll(out[0..payload.len]);
    try dog.disarm();
}

test "ViewportWs: live upgrade completes for a browser-sized request and frames are delivered" {
    var server = try ViewportWsServer.init(testing.allocator, testing.io, 0);
    defer server.deinit();
    try server.start();
    try testing.expect(server.port != 0); // ephemeral port is resolved and reportable

    var client: TestClient = undefined;
    try client.open(server.port);
    defer client.close();
    // The socket stays open: the old handshake waited for EOF / 4096 bytes and never answered.
    const resp = try client.handshake(browser_upgrade_request);
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 101"));
    try testing.expect(std.mem.indexOf(u8, resp, "Sec-WebSocket-Accept: " ++ SEC_WEBSOCKET_ACCEPT ++ "\r\n") != null);

    const payload = "mesh-bytes";
    var got: [payload.len]u8 = undefined;
    try receiveBroadcast(&server, &client, payload, &got);
    try testing.expectEqualStrings(payload, &got);
}

test "ViewportWs: foreign Origin is refused with 403 and the connection is dropped" {
    test_support.expectWarnings();
    var server = try ViewportWsServer.init(testing.allocator, testing.io, 0);
    defer server.deinit();
    try server.start();

    var client: TestClient = undefined;
    try client.open(server.port);
    defer client.close();
    const resp = try client.handshake(upgradeRequest("Origin: https://evil.example\r\n"));
    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403"));
    try waitForClients(&server, 0);
}

test "ViewportWs: connections are capped, slots are freed on close, deinit wakes stalled handshakes" {
    test_support.expectWarnings();
    var server = try ViewportWsServer.init(testing.allocator, testing.io, 0);
    var server_live = true;
    defer if (server_live) server.deinit();
    try server.start();

    var streams: [ws.MAX_CLIENTS]std.Io.net.Stream = undefined;
    var open_count: usize = 0;
    defer for (streams[0..open_count]) |s| s.close(testing.io);
    for (&streams) |*s| {
        s.* = try connect(server.port);
        open_count += 1;
    }
    try waitForClients(&server, ws.MAX_CLIENTS);

    // One over the cap: the server must close it instead of spawning another thread.
    {
        var extra: TestClient = undefined;
        try extra.open(server.port);
        defer extra.close();
        var dog = Watchdog{ .stream = extra.stream };
        try dog.arm();
        try testing.expectError(error.EndOfStream, extra.reader.interface.takeByte());
        try dog.disarm();
        try testing.expectEqual(ws.MAX_CLIENTS, server.clientCount());
    }

    // Closing half of them unregisters exactly those clients (removal by identity).
    const keep = ws.MAX_CLIENTS / 2;
    for (streams[keep..]) |s| s.close(testing.io);
    open_count = keep;
    try waitForClients(&server, keep);

    // The remaining threads are blocked reading headers; deinit must still return.
    server_live = false;
    server.deinit();
}

test "ViewportWs: a connection that never sends its upgrade request is closed" {
    test_support.expectWarnings();
    var server = try ViewportWsServer.init(testing.allocator, testing.io, 0);
    defer server.deinit();
    server.handshake_timeout = .fromMilliseconds(50);
    try server.start();

    // It used to hold its slot (one of MAX_CLIENTS, two threads) until it hung up.
    var silent: TestClient = undefined;
    try silent.open(server.port);
    defer silent.close();
    var dog = Watchdog{ .stream = silent.stream };
    try dog.arm();
    try testing.expectError(error.EndOfStream, silent.reader.interface.takeByte());
    try dog.disarm();
    try waitForClients(&server, 0);

    // One that does upgrade in time stays open past the timeout.
    var client: TestClient = undefined;
    try client.open(server.port);
    defer client.close();
    _ = try client.handshake(browser_upgrade_request);
    sleepMs(100);
    var got: [1]u8 = undefined;
    try receiveBroadcast(&server, &client, "!", &got);
}

test "ViewportWs: broadcast never blocks on a client that stopped reading" {
    const payload_bytes = 4 * 1024 * 1024; // far beyond kernel socket buffers
    const broadcasts = 8;

    var server = try ViewportWsServer.init(testing.allocator, testing.io, 0);
    defer server.deinit();
    try server.start();

    var client: TestClient = undefined;
    try client.open(server.port);
    defer client.close();
    _ = try client.handshake(browser_upgrade_request);
    // Prove the client is registered as upgraded, so the big broadcasts below are really queued.
    var ack: [1]u8 = undefined;
    try receiveBroadcast(&server, &client, "!", &ack);
    // From here on the client never reads.

    const payload = try testing.allocator.alloc(u8, payload_bytes);
    defer testing.allocator.free(payload);
    @memset(payload, 0x5a);

    const start = std.Io.Clock.now(.awake, testing.io);
    for (0..broadcasts) |_| try server.broadcastBinary(payload);
    const elapsed_ms = @divTrunc(start.durationTo(std.Io.Clock.now(.awake, testing.io)).toNanoseconds(), std.time.ns_per_ms);
    // The old implementation wrote synchronously on the caller (LSP) thread and hung here.
    try testing.expect(elapsed_ms < BROADCAST_BUDGET_MS);
}

test "ViewportWs: a second viewport server falls back instead of sharing the port" {
    test_support.expectWarnings();
    // Two LSPs (e.g. two VS Code windows) both prefer the same port. The second used to bind
    // it too (SO_REUSEPORT via `reuse_address`), so a viewer could reach the wrong window.
    var first = try ViewportWsServer.init(testing.allocator, testing.io, 0);
    defer first.deinit();
    const taken = first.port;
    try testing.expectError(error.AddressInUse, ViewportWsServer.init(testing.allocator, testing.io, taken));

    var second = try ViewportWsServer.initWithFallback(testing.allocator, testing.io, taken);
    defer second.deinit();
    try testing.expect(second.port != 0);
    try testing.expect(second.port != taken);
}
