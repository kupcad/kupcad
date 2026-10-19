const std = @import("std");
const testing = std.testing;
const http_client = @import("http_client.zig");

fn allowed(from: []const u8, to: []const u8) !bool {
    return http_client.redirectAllowed(try std.Uri.parse(from), try std.Uri.parse(to));
}

test "HTTP client: a redirect never moves to a less trusted place" {
    try testing.expect(try allowed("https://github.com/u/r/archive/x.tar.gz", "https://codeload.github.com/u/r/tar.gz/x"));
    try testing.expect(try allowed("http://example.org/p.tar.gz", "https://example.org/p.tar.gz"));
    // An intranet archive may move within the intranet.
    try testing.expect(try allowed("http://10.0.0.5/p.tar.gz", "http://10.0.0.6/p.tar.gz"));

    try testing.expect(!try allowed("https://github.com/x", "http://github.com/x")); // downgrade
    try testing.expect(!try allowed("https://github.com/x", "https://127.0.0.1/x")); // public to loopback
    try testing.expect(!try allowed("https://github.com/x", "https://localhost/x"));
    try testing.expect(!try allowed("https://github.com/x", "https://intranet/x"));
    try testing.expect(!try allowed("https://github.com/x", "file:///etc/passwd"));
    try testing.expect(!try allowed("https://github.com/x", "https://user:pw@github.com/x"));
}

/// Serves `/start` -> `/hop` (relative) -> `http://127.0.0.1:<port>/done` (absolute) ->
/// 200 "ok", and `/loop` -> `/loop` forever, one connection at a time.
const Server = struct {
    server: std.Io.net.Server,
    port: u16,
    served: usize = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(self: *Server, connections: usize) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        const server = try address.listen(testing.io, .{});
        self.* = .{ .server = server, .port = server.socket.address.getPort() };
        self.thread = try std.Thread.spawn(.{}, serve, .{ self, connections });
    }

    /// Also when the client gave up early: a throwaway connection wakes a pending accept.
    fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        const address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch unreachable;
        if (address.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
        if (self.thread) |t| t.join();
        self.server.deinit(testing.io);
    }

    fn serve(self: *Server, connections: usize) void {
        for (0..connections) |_| self.serveOne() catch return;
    }

    fn serveOne(self: *Server) !void {
        const stream = try self.server.accept(testing.io);
        defer stream.close(testing.io);
        if (self.stopping.load(.acquire)) return error.Stopped;
        var r_buf: [4096]u8 = undefined;
        var reader = stream.reader(testing.io, &r_buf);
        const head = try reader.interface.takeDelimiterInclusive('\n'); // GET /path HTTP/1.1
        var parts = std.mem.splitScalar(u8, head, ' ');
        _ = parts.next();
        const path = parts.next() orelse return error.BadRequest;
        var location_buf: [64]u8 = undefined;
        const response: []const u8, const location: []const u8 = if (std.mem.eql(u8, path, "/start"))
            .{ "302 Found", "hop" }
        else if (std.mem.eql(u8, path, "/hop"))
            .{ "301 Moved Permanently", try std.mem.print(&location_buf, "http://127.0.0.1:{d}/done", .{self.port}) }
        else if (std.mem.eql(u8, path, "/loop"))
            .{ "302 Found", "/loop" }
        else
            .{ "200 OK", "" };
        // Bodies are read uncompressed, so nothing else is accepted.
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
            if (std.ascii.startsWithIgnoreCase(line, "accept-encoding:") and std.mem.find(u8, line, "identity") == null) return error.CompressionRequested;
        }
        var w_buf: [512]u8 = undefined;
        var writer = stream.writer(testing.io, &w_buf);
        const body = if (location.len == 0) "ok" else "";
        try writer.interface.print("HTTP/1.1 {s}\r\nConnection: close\r\nContent-Length: {d}\r\n", .{ response, body.len });
        if (location.len > 0) try writer.interface.print("Location: {s}\r\n", .{location});
        try writer.interface.print("\r\n{s}", .{body});
        try writer.interface.flush();
        self.served += 1;
    }
};

test "HTTP client: Get follows relative and absolute redirects itself" {
    var server: Server = undefined;
    try server.start(3);
    defer server.stop();

    var client = std.http.Client{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    const get = try testing.allocator.create(http_client.Get);
    defer testing.allocator.destroy(get);

    var url_buf: [64]u8 = undefined;
    var response = try get.send(&client, try std.mem.print(&url_buf, "http://127.0.0.1:{d}/start", .{server.port}));
    defer get.deinit();
    try testing.expectEqual(std.http.Status.ok, response.head.status);
    const body = try response.reader(&.{}).allocRemaining(testing.allocator, .limited(64));
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("ok", body);
}

test "HTTP client: Get stops after MAX_REDIRECTS" {
    var server: Server = undefined;
    try server.start(http_client.MAX_REDIRECTS + 1);
    errdefer server.stop();

    var client = std.http.Client{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    const get = try testing.allocator.create(http_client.Get);
    defer testing.allocator.destroy(get);

    var url_buf: [64]u8 = undefined;
    try testing.expectError(error.TooManyHttpRedirects, get.send(&client, try std.mem.print(&url_buf, "http://127.0.0.1:{d}/loop", .{server.port})));
    server.stop(); // joins the server, so `served` is final
    try testing.expectEqual(http_client.MAX_REDIRECTS + 1, server.served);
}

test "HTTP client: root certificates are installed once, with the time to check them at" {
    // Opening the connection ourselves (for the timeout) skipped std's own loading, so
    // every HTTPS download panicked on the missing certificate time. An empty bundle stands
    // in for the system's store, which the test used to read, so it passed or failed with
    // the machine it ran on.
    var client = std.http.Client{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    try testing.expect(client.now == null);
    var first: std.crypto.Certificate.Bundle = .empty;
    defer first.deinit(testing.allocator);
    const when: std.Io.Timestamp = .{ .nanoseconds = 1_700_000_000 * std.time.ns_per_s };
    try http_client.installRootCertificates(&client, &first, when);
    try testing.expectEqual(when.nanoseconds, client.now.?.nanoseconds);

    // A second load keeps the first: the client is already set up.
    var second: std.crypto.Certificate.Bundle = .empty;
    defer second.deinit(testing.allocator);
    try http_client.installRootCertificates(&client, &second, .{ .nanoseconds = 0 });
    try testing.expectEqual(when.nanoseconds, client.now.?.nanoseconds);
    try http_client.loadRootCertificates(&client); // returns at once, reading nothing
}
