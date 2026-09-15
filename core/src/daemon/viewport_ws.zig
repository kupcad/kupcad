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
    server: std.Io.net.Server,
    clients: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    mutex: std.Io.Mutex = .init,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) !ViewportWsServer {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        const server = try address.listen(io, .{ .reuse_address = true });

        return .{
            .allocator = allocator,
            .io = io,
            .port = port,
            .server = server,
        };
    }

    pub fn deinit(self: *ViewportWsServer) void {
        self.running.store(false, .release);
        self.server.deinit(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.clients.items) |stream| stream.close(self.io);
        self.clients.deinit(self.allocator);
    }

    pub fn listenLoop(self: *ViewportWsServer) !void {
        self.running.store(true, .release);
        log.info("WebSocket Viewport Server listening on ws://127.0.0.1:{d}", .{self.port});

        while (self.running.load(.acquire)) {
            const stream = self.server.accept(self.io) catch |err| {
                if (!self.running.load(.acquire)) break;
                log.err("WebSocket accept error: {}", .{err});
                continue;
            };
            self.handleHandshake(stream) catch |err| {
                log.err("Handshake failed: {}", .{err});
                stream.close(self.io);
            };
        }
    }

    fn handleHandshake(self: *ViewportWsServer, stream: std.Io.net.Stream) !void {
        // Use Zig 0.16.0 Stream Reader interface wrapper
        var r_buf: [4096]u8 = undefined;
        var reader_wrapper = stream.reader(self.io, &r_buf);
        const reader = &reader_wrapper.interface;

        var req_buf: [4096]u8 = undefined;
        const bytes_read = try reader.readSliceShort(&req_buf);
        const req = req_buf[0..bytes_read];

        const key_header = "Sec-WebSocket-Key: ";
        if (std.mem.indexOf(u8, req, key_header)) |idx| {
            const start = idx + key_header.len;
            const end = std.mem.indexOfScalarPos(u8, req, start, '\r') orelse return;
            const client_key = req[start..end];

            const accept_key = try self.generateAcceptKey(client_key);

            const response = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept_key});
            defer self.allocator.free(response);

            // Use Zig 0.16.0 Stream Writer interface wrapper
            var w_buf: [1024]u8 = undefined;
            var writer_wrapper = stream.writer(self.io, &w_buf);
            const writer = &writer_wrapper.interface;

            try writer.writeAll(response);
            try writer.flush();

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            try self.clients.append(self.allocator, stream);
            log.info("Viewport connected. Total active: {d}", .{self.clients.items.len});
        } else {
            stream.close(self.io);
        }
    }

    pub fn broadcastSessionMesh(self: *ViewportWsServer, session: *ScriptSession, root_mod_path: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.clients.items.len == 0) return;

        const root_id = session.workspace.path_to_id.get(root_mod_path) orelse return;
        const node = &session.nodes.items[@intFromEnum(root_id)];
        const handle = node.cached_handle orelse return;

        const handles = [_]geom.GeometryHandle{handle};
        const glb_bytes = gltf.buildGltfBuffer(self.allocator, &session.vm, &handles, false) catch |err| {
            log.err("Failed to build GLB: {}", .{err});
            return;
        };
        defer self.allocator.free(glb_bytes);

        var frame = std.ArrayListUnmanaged(u8).empty;
        defer frame.deinit(self.allocator);

        try frame.append(self.allocator, 0x82); // FIN + Binary Frame

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

        var active_i: usize = 0;
        while (active_i < self.clients.items.len) {
            const stream = self.clients.items[active_i];

            var w_buf: [4096]u8 = undefined;
            var writer_wrapper = stream.writer(self.io, &w_buf);
            const writer = &writer_wrapper.interface;

            if (writer.writeAll(frame.items)) |_| {
                writer.flush() catch {};
                active_i += 1;
            } else |_| {
                stream.close(self.io);
                _ = self.clients.orderedRemove(active_i);
            }
        }
    }

    fn generateAcceptKey(self: *ViewportWsServer, client_key: []const u8) ![28]u8 {
        const concatenated = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ client_key, WS_GUID });
        defer self.allocator.free(concatenated);

        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(concatenated);
        const digest = sha1.finalResult();

        var out_buf: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&out_buf, &digest);
        return out_buf;
    }
};
