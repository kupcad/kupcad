const std = @import("std");
const gltf = @import("../exporters/3d/gltf.zig");
const ScriptSession = @import("session.zig").ScriptSession;
const geom = @import("../kernel/geometry_handle.zig");

const log = std.log.scoped(.viewport_ws);
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const ViewportWsServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    server: std.net.Server,
    clients: std.ArrayListUnmanaged(std.net.Server.Connection) = .empty,
    mutex: std.Thread.Mutex = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) !ViewportWsServer {
        const address = try std.net.Address.parseIp("127.0.0.1", port);
        const server = try address.listen(.{ .reuse_address = true });

        return .{
            .allocator = allocator,
            .io = io,
            .port = port,
            .server = server,
        };
    }

    pub fn deinit(self: *ViewportWsServer) void {
        self.running.store(false, .release);
        self.server.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items) |conn| {
            conn.stream.close();
        }
        self.clients.deinit(self.allocator);
    }

    /// Background listener loop
    pub fn listenLoop(self: *ViewportWsServer) !void {
        self.running.store(true, .release);
        log.info("WebSocket Viewport Server listening on ws://127.0.0.1:{d}", .{self.port});

        while (self.running.load(.acquire)) {
            const conn = self.server.accept() catch |err| {
                if (!self.running.load(.acquire)) break;
                log.err("WebSocket accept error: {}", .{err});
                continue;
            };

            try self.handleHandshake(conn);
        }
    }

    fn handleHandshake(self: *ViewportWsServer, conn: std.net.Server.Connection) !void {
        var buf: [4096]u8 = undefined;
        const bytes_read = try conn.stream.read(&buf);
        const req = buf[0..bytes_read];

        // Extremely simple RFC6455 handshake extraction
        const key_header = "Sec-WebSocket-Key: ";
        if (std.mem.indexOf(u8, req, key_header)) |idx| {
            const start = idx + key_header.len;
            const end = std.mem.indexOfScalarPos(u8, req, start, '\r') orelse return;
            const client_key = req[start..end];

            const accept_key = try generateAcceptKey(self.allocator, client_key);

            const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key});
            defer self.allocator.free(response);

            try conn.stream.writeAll(response);

            self.mutex.lock();
            defer self.mutex.unlock();
            try self.clients.append(self.allocator, conn);
            log.info("Viewport client connected. Total viewports: {d}", .{self.clients.items.len});
        } else {
            conn.stream.close();
        }
    }

    pub fn broadcastSessionMesh(self: *ViewportWsServer, session: *ScriptSession, root_mod_path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.clients.items.len == 0) return; // No need to build GLB if nobody is watching

        const root_id = session.workspace.path_to_id.get(root_mod_path) orelse return;
        const node = &session.nodes.items[@intFromEnum(root_id)];
        const handle = node.cached_handle orelse return;

        // 1. Generate GLB binary buffer using the native exporter
        const handles = [_]geom.GeometryHandle{handle};
        const glb_bytes = gltf.buildGltfBuffer(self.allocator, &session.vm, &handles, false) catch |err| {
            log.err("Failed to build GLB for broadcast: {}", .{err});
            return;
        };
        defer self.allocator.free(glb_bytes);

        // 2. Wrap GLB bytes in a WebSocket Binary Frame (Opcode 0x02)
        var frame = std.ArrayListUnmanaged(u8).empty;
        defer frame.deinit(self.allocator);

        try frame.append(self.allocator, 0x82); // FIN + Binary

        const payload_len = glb_bytes.len;
        if (payload_len <= 125) {
            try frame.append(self.allocator, @intCast(payload_len));
        } else if (payload_len <= 65535) {
            try frame.append(self.allocator, 126);
            var len_bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_bytes, @intCast(payload_len), .big);
            try frame.appendSlice(self.allocator, &len_bytes);
        } else {
            try frame.append(self.allocator, 127);
            var len_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_bytes, @intCast(payload_len), .big);
            try frame.appendSlice(self.allocator, &len_bytes);
        }

        try frame.appendSlice(self.allocator, glb_bytes);

        // 3. Blast to all connected clients
        var active_i: usize = 0;
        while (active_i < self.clients.items.len) {
            const conn = self.clients.items[active_i];
            if (conn.stream.writeAll(frame.items)) |_| {
                active_i += 1;
            } else |_| {
                // Remove disconnected clients safely
                conn.stream.close();
                _ = self.clients.orderedRemove(active_i);
            }
        }
    }

    fn generateAcceptKey(allocator: std.mem.Allocator, client_key: []const u8) ![28]u8 {
        const concatenated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ client_key, WS_GUID });
        defer allocator.free(concatenated);

        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(concatenated);
        const digest = sha1.finalResult();

        var out_buf: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&out_buf, &digest);
        return out_buf;
    }
};
