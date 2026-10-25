//! The WebSocket server the editor's viewport connects to on 127.0.0.1: the HTTP upgrade
//! handshake with its origin check, frame encoding, and `ViewportWsServer`, which sends every
//! client the preview's frames (preview/frame.zig: a JSON header, then the model as GLB or
//! SVG) as binary messages (`broadcastBinary`). Started by cli/lsp.zig.

const std = @import("std");

const log = std.log.scoped(.viewport_ws);
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Port tried first. If it is taken we fall back to an OS-assigned ephemeral port and the LSP
/// reports the real one to the editor (see `kupcad/viewportReady` in cli/lsp.zig).
pub const DEFAULT_PORT: u16 = 9001;
/// Upper bound for the HTTP upgrade request. Browsers send ~500 bytes; anything past this is abuse.
pub const MAX_HANDSHAKE_BYTES: usize = 8 * 1024;
/// Hard cap on simultaneous connections (handshaking + upgraded). Each costs two OS threads.
pub const MAX_CLIENTS: usize = 8;
/// How long a connection may take to finish its upgrade request before it is closed, so a
/// socket that connects and sends nothing can't hold one of the MAX_CLIENTS slots for good.
pub const HANDSHAKE_TIMEOUT_MS: i64 = 5000;
/// Largest client->server frame we accept. The viewport only sends tiny control messages.
pub const MAX_INCOMING_FRAME_BYTES: u64 = 64 * 1024;
/// Browser origins allowed to open the viewport socket. Any web page can open a WebSocket to
/// 127.0.0.1, so without this check a malicious site could read the user's models.
/// `vscode-webview://` is a prefix (the host part is a per-webview random id). The webview is
/// built into the extension, never served by a dev server, so no http origin is allowed.
pub const ALLOWED_ORIGIN_PREFIXES = [_][]const u8{"vscode-webview://"};

const WS_OPCODE_CLOSE: u8 = 0x8;
const WS_OPCODE_BINARY: u8 = 0x2;
const WS_FIN: u8 = 0x80;
const WS_MASK_BIT: u8 = 0x80;
const SOCKET_BUF_BYTES: usize = 4096;
const SHUTDOWN_POLL_MS: i64 = 5;

pub const Handshake = struct {
    key: []const u8,
    origin: ?[]const u8,
};

/// Reads from `reader` until the end of the HTTP header block ("\r\n\r\n").
/// Returns the header bytes (a slice into the reader's buffer, valid until the next read).
/// At most min(MAX_HANDSHAKE_BYTES, buffer size) bytes are accepted.
/// Unlike `readSliceShort`, this returns as soon as the request is complete instead of waiting
/// for the buffer to fill or the peer to hang up.
pub fn readHttpHeaders(reader: *std.Io.Reader) ![]const u8 {
    const limit = @min(MAX_HANDSHAKE_BYTES, reader.buffer.len);
    while (true) {
        const buffered = reader.buffered();
        if (std.mem.find(u8, buffered[0..@min(buffered.len, limit)], "\r\n\r\n")) |end| {
            const total = end + 4;
            reader.toss(total);
            return buffered[0..total];
        }
        if (buffered.len >= limit) return error.HeaderTooLarge;
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => return error.IncompleteHandshake,
            else => |e| return e,
        };
    }
}

fn headerValue(req: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, req, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        // Header names are case-insensitive (RFC 9110); browsers differ in casing.
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Parses an HTTP/1.1 WebSocket upgrade request. Pure function so it can be unit tested.
pub fn parseHandshake(req: []const u8) !Handshake {
    if (!std.mem.startsWith(u8, req, "GET ")) return error.NotWebSocketUpgrade;
    const upgrade = headerValue(req, "Upgrade") orelse return error.NotWebSocketUpgrade;
    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return error.NotWebSocketUpgrade;
    const key = headerValue(req, "Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;
    // A valid key is 16 random bytes, base64 encoded.
    if (key.len != 24) return error.MissingWebSocketKey;
    return .{ .key = key, .origin = headerValue(req, "Origin") };
}

/// Returns true if a connection with this Origin may upgrade. A missing Origin means a
/// non-browser client (browsers always send it on WebSocket upgrades); such a process already
/// runs locally with the user's privileges, so it is allowed.
pub fn isOriginAllowed(origin: ?[]const u8) bool {
    const o = origin orelse return true;
    for (ALLOWED_ORIGIN_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, o, prefix) and o.len > prefix.len) return true;
    }
    return false;
}

pub fn computeAcceptKey(client_key: []const u8) [28]u8 {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(client_key);
    sha1.update(WS_GUID);
    const digest = sha1.finalResult();

    var out_buf: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out_buf, &digest);
    return out_buf;
}

pub const FrameHeader = struct {
    opcode: u8,
    payload_len: u64,
    mask: [4]u8,
};

/// Reads a client->server frame header, enforcing masking (RFC 6455 5.1) and
/// MAX_INCOMING_FRAME_BYTES before any payload is read.
pub fn readFrameHeader(reader: *std.Io.Reader) !FrameHeader {
    const b = try reader.takeArray(2);
    const opcode = b[0] & 0x0F;
    if (b[1] & WS_MASK_BIT == 0) return error.UnmaskedClientFrame;

    var len: u64 = b[1] & 0x7F;
    if (len == 126) {
        len = std.mem.readInt(u16, try reader.takeArray(2), .big);
    } else if (len == 127) {
        len = std.mem.readInt(u64, try reader.takeArray(8), .big);
    }
    if (len > MAX_INCOMING_FRAME_BYTES) return error.FrameTooLarge;

    return .{ .opcode = opcode, .payload_len = len, .mask = (try reader.takeArray(4)).* };
}

/// Encodes a server->client (unmasked) binary frame.
pub fn encodeBinaryFrame(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var frame = std.ArrayList(u8).empty;
    errdefer frame.deinit(allocator);
    try frame.ensureTotalCapacity(allocator, payload.len + 10);

    frame.appendAssumeCapacity(WS_FIN | WS_OPCODE_BINARY);
    if (payload.len <= 125) {
        frame.appendAssumeCapacity(@intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        frame.appendAssumeCapacity(126);
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(payload.len), .big);
        frame.appendSliceAssumeCapacity(&len_bytes);
    } else {
        frame.appendAssumeCapacity(127);
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, @intCast(payload.len), .big);
        frame.appendSliceAssumeCapacity(&len_bytes);
    }
    frame.appendSliceAssumeCapacity(payload);
    return frame.toOwnedSlice(allocator);
}

/// Immutable, refcounted encoded frame shared by all client mailboxes.
const SharedFrame = struct {
    bytes: []u8,
    refs: std.atomic.Value(u32) = .init(1),

    fn retain(self: *SharedFrame) *SharedFrame {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    fn release(self: *SharedFrame, allocator: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            allocator.free(self.bytes);
            allocator.destroy(self);
        }
    }
};

/// One connection. Owned jointly by its reader thread and (after upgrade) its writer thread;
/// the last one to drop its reference unregisters it and closes the stream under the server lock.
const Client = struct {
    server: *ViewportWsServer,
    stream: std.Io.net.Stream,
    refs: std.atomic.Value(u32) = .init(1),

    // --- Guarded by `mutex` ---
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    upgraded: bool = false,
    closed: bool = false,
    /// Single-slot mailbox: the viewport only needs the newest preview, so a slow client drops
    /// stale frames instead of building an unbounded queue or blocking the broadcaster.
    pending: ?*SharedFrame = null,

    fn retain(self: *Client) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *Client) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const server = self.server;
        const io = server.io;

        if (self.pending) |f| f.release(server.allocator);
        self.pending = null;

        // Everything is torn down under the server lock: `deinit` waits for the list to drain,
        // so the client must be fully freed by the time it disappears from the list.
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        // Remove by identity: fds are reused by the OS, so comparing handles can drop the wrong client.
        for (server.clients.items, 0..) |c, i| {
            if (c == self) {
                _ = server.clients.swapRemove(i);
                break;
            }
        }
        self.stream.close(io);
        server.allocator.destroy(self);
    }

    /// Marks the client closed and wakes both of its threads. Safe to call repeatedly.
    fn markClosed(self: *Client) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        const was_closed = self.closed;
        self.closed = true;
        self.cond.broadcast(io);
        self.mutex.unlock(io);
        // Unblocks a reader stuck in recv / a writer stuck in send without closing the fd
        // (closing is deferred to `release` so no thread ever touches a recycled fd).
        if (!was_closed) self.stream.shutdown(io, .both) catch {};
    }

    /// Waits for the upgrade to complete. False if the connection closed first or the peer
    /// took longer than the server's `handshake_timeout`, in which case it is closed here.
    fn awaitUpgrade(self: *Client) bool {
        const io = self.server.io;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = self.server.handshake_timeout, .clock = .awake } };
        const deadline = timeout.toDeadline(io);
        self.mutex.lockUncancelable(io);
        while (!self.upgraded and !self.closed) {
            self.cond.waitTimeout(io, &self.mutex, deadline) catch break;
        }
        const upgraded = self.upgraded and !self.closed;
        self.mutex.unlock(io);
        if (!upgraded and !self.closed) {
            log.warn("Viewport connection closed: no upgrade request within {d} ms", .{self.server.handshake_timeout.toMilliseconds()});
            self.markClosed();
        }
        return upgraded;
    }

    fn post(self: *Client, frame: *SharedFrame) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed or !self.upgraded) return;
        if (self.pending) |old| old.release(self.server.allocator);
        self.pending = frame.retain();
        self.cond.signal(io);
    }
};

pub const ViewportWsServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The port actually bound (resolved when an ephemeral port was requested).
    port: u16,
    server: std.Io.net.Server,
    clients: std.ArrayList(*Client) = .empty,
    mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    listen_thread: ?std.Thread = null,
    /// See HANDSHAKE_TIMEOUT_MS; tests shorten it.
    handshake_timeout: std.Io.Duration = .fromMilliseconds(HANDSHAKE_TIMEOUT_MS),

    /// Binds 127.0.0.1:`port`. Pass 0 for an OS-assigned port; read `.port` for the result.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) !ViewportWsServer {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        // No `reuse_address`: std sets SO_REUSEPORT with it on every POSIX target, which lets a
        // second LSP bind a port another window still listens on (so its viewer could reach the
        // wrong LSP) and makes initWithFallback dead code. std has no SO_REUSEADDR-only option;
        // a port held in TIME_WAIT after a restart just falls back, and the real port is
        // advertised to the client via kupcad/viewportReady.
        const server = try address.listen(io, .{});

        return .{
            .allocator = allocator,
            .io = io,
            .port = server.socket.address.getPort(),
            .server = server,
        };
    }

    /// Tries `preferred_port`, then falls back to an ephemeral port if it is unavailable.
    pub fn initWithFallback(allocator: std.mem.Allocator, io: std.Io, preferred_port: u16) !ViewportWsServer {
        return init(allocator, io, preferred_port) catch |err| {
            if (preferred_port == 0) return err;
            log.warn("Viewport port {d} unavailable ({}); using an ephemeral port", .{ preferred_port, err });
            return init(allocator, io, 0);
        };
    }

    /// Spawns the accept loop. `self` must not move afterwards (threads keep a pointer to it).
    pub fn start(self: *ViewportWsServer) !void {
        self.running.store(true, .release);
        self.listen_thread = try std.Thread.spawn(.{}, listenLoopThread, .{self});
    }

    pub fn deinit(self: *ViewportWsServer) void {
        const was_running = self.running.swap(false, .acq_rel);

        if (self.listen_thread) |t| {
            // accept() is not reliably interrupted by closing the socket on every OS, so poke it
            // with a throwaway connection; the loop then sees running == false and exits.
            if (was_running) {
                const addr = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch unreachable;
                if (addr.connect(self.io, .{ .mode = .stream })) |s| s.close(self.io) else |_| {}
            }
            t.join();
        }
        self.server.deinit(self.io);

        // Wake every connection thread, then wait for them to unregister themselves.
        // Holding the server lock keeps every client alive (release() needs it to unregister).
        self.mutex.lockUncancelable(self.io);
        for (self.clients.items) |c| c.markClosed();
        self.mutex.unlock(self.io);

        while (true) {
            self.mutex.lockUncancelable(self.io);
            const remaining = self.clients.items.len;
            self.mutex.unlock(self.io);
            if (remaining == 0) break;
            self.io.sleep(std.Io.Duration.fromMilliseconds(SHUTDOWN_POLL_MS), .awake) catch {};
        }
        self.clients.deinit(self.allocator);
    }

    /// Number of currently registered connections (handshaking or upgraded).
    pub fn clientCount(self: *ViewportWsServer) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.clients.items.len;
    }

    fn listenLoopThread(self: *ViewportWsServer) void {
        self.listenLoop() catch |err| log.err("Viewport listen loop exited: {}", .{err});
    }

    /// Accept loop; run via `start()` (which sets `running` before the thread exists, so a racing
    /// `deinit` can never be undone by the loop re-arming itself).
    fn listenLoop(self: *ViewportWsServer) !void {
        log.info("WebSocket Viewport Server listening on ws://127.0.0.1:{d}", .{self.port});

        while (self.running.load(.acquire)) {
            const stream = self.server.accept(self.io) catch |err| {
                if (!self.running.load(.acquire)) break;
                log.err("WebSocket accept error: {}", .{err});
                continue;
            };

            self.mutex.lockUncancelable(self.io);
            if (!self.running.load(.acquire) or self.clients.items.len >= MAX_CLIENTS) {
                // Bounded resources: refuse instead of spawning an unbounded number of threads.
                if (self.running.load(.acquire)) log.warn("Viewport connection refused: {d} clients connected", .{MAX_CLIENTS});
                stream.close(self.io);
                self.mutex.unlock(self.io);
                continue;
            }
            const client = self.allocator.create(Client) catch {
                stream.close(self.io);
                self.mutex.unlock(self.io);
                continue;
            };
            client.* = .{ .server = self, .stream = stream };
            self.clients.append(self.allocator, client) catch {
                stream.close(self.io);
                self.mutex.unlock(self.io);
                self.allocator.destroy(client);
                continue;
            };
            self.mutex.unlock(self.io);

            const thread = std.Thread.spawn(.{}, connectionThread, .{client}) catch |err| {
                log.err("Failed to spawn connection thread: {}", .{err});
                client.release();
                continue;
            };
            thread.detach();
        }
    }

    fn connectionThread(client: *Client) void {
        defer client.release();
        defer client.markClosed();
        client.server.serveConnection(client) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => {},
            else => log.warn("Viewport connection closed: {}", .{err}),
        };
    }

    fn serveConnection(self: *ViewportWsServer, client: *Client) !void {
        // The writer thread starts now and first waits for the upgrade, which also times out a
        // handshake that never comes (this thread is blocked reading it).
        client.retain();
        const writer_thread = std.Thread.spawn(.{}, writerThread, .{client}) catch |err| {
            client.release();
            return err;
        };
        writer_thread.detach();

        var r_buf: [MAX_HANDSHAKE_BYTES]u8 = undefined;
        var reader_wrapper = client.stream.reader(self.io, &r_buf);
        const reader = &reader_wrapper.interface;

        const req = try readHttpHeaders(reader);
        const hs = try parseHandshake(req);

        var w_buf: [SOCKET_BUF_BYTES]u8 = undefined;
        var writer_wrapper = client.stream.writer(self.io, &w_buf);
        const writer = &writer_wrapper.interface;

        if (!isOriginAllowed(hs.origin)) {
            log.warn("Rejected viewport connection from origin '{s}'", .{hs.origin.?});
            writer.writeAll("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
            writer.flush() catch {};
            return error.OriginNotAllowed;
        }

        const accept_key = computeAcceptKey(hs.key);
        try writer.print("HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n", .{&accept_key});
        try writer.flush();

        // The writer thread drains the mailbox; this thread keeps reading so we notice closes.
        client.mutex.lockUncancelable(self.io);
        client.upgraded = true;
        client.cond.broadcast(self.io);
        client.mutex.unlock(self.io);
        log.info("Viewport connected. Total active: {d}", .{self.clientCount()});

        while (true) {
            const header = try readFrameHeader(reader);
            if (header.opcode == WS_OPCODE_CLOSE) return;
            // Viewport -> server messages are not used yet; discard the (bounded) payload.
            try reader.discardAll64(header.payload_len);
        }
    }

    fn writerThread(client: *Client) void {
        defer client.release();
        defer client.markClosed();
        const io = client.server.io;
        if (!client.awaitUpgrade()) return;

        var w_buf: [SOCKET_BUF_BYTES]u8 = undefined;
        var writer_wrapper = client.stream.writer(io, &w_buf);
        const writer = &writer_wrapper.interface;

        while (true) {
            client.mutex.lockUncancelable(io);
            while (client.pending == null and !client.closed) client.cond.waitUncancelable(io, &client.mutex);
            if (client.closed) {
                client.mutex.unlock(io);
                return;
            }
            const frame = client.pending.?;
            client.pending = null;
            client.mutex.unlock(io);

            defer frame.release(client.server.allocator);
            // This may block on a slow client, but only this client's thread waits.
            writer.writeAll(frame.bytes) catch return;
            writer.flush() catch return;
        }
    }

    /// Queues `payload` as a binary frame for every upgraded client. Never blocks on the network.
    pub fn broadcastBinary(self: *ViewportWsServer, payload: []const u8) !void {
        const frame = try self.allocator.create(SharedFrame);
        frame.* = .{ .bytes = encodeBinaryFrame(self.allocator, payload) catch |err| {
            self.allocator.destroy(frame);
            return err;
        } };
        defer frame.release(self.allocator);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.clients.items) |c| c.post(frame);
    }
};
