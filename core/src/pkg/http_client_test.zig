const std = @import("std");
const testing = std.testing;
const http_client = @import("http_client.zig");
const SlowServer = @import("test_helpers.zig").SlowServer;

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

/// The body of a GET of `url`, read through a `Counted`: what `watched` runs.
fn readBody(client: *std.http.Client, url: []const u8, received: *http_client.Received) ![]u8 {
    const get = try testing.allocator.create(http_client.Get);
    defer testing.allocator.destroy(get);
    var response = try get.send(client, url);
    defer get.deinit();
    var body: http_client.Counted = .init(response.reader(&.{}), received);
    return body.interface.allocRemaining(testing.allocator, .limited(1024));
}

/// `readBody` of `path` on `server`, watched for `stall`.
fn watchedBody(server: *const SlowServer, stall: std.Io.Duration) ![]u8 {
    var client = std.http.Client{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    return http_client.watched(testing.io, stall, readBody, .{ &client, try server.url(&url_buf, "/p.tar.gz") });
}

test "HTTP client: a request whose host never answers is abandoned" {
    // It waited for the head for good: std.http.Client reads without a timeout
    var server: SlowServer = undefined;
    try server.start(.{ .head = false });
    defer server.stop();
    try testing.expectError(error.DownloadStalled, watchedBody(&server, .fromMilliseconds(100)));
}

test "HTTP client: a request whose body stops coming is abandoned" {
    var server: SlowServer = undefined;
    try server.start(.{ .pieces = 3, .gap = .fromMilliseconds(10) });
    defer server.stop();
    try testing.expectError(error.DownloadStalled, watchedBody(&server, .fromMilliseconds(100)));
}

test "HTTP client: a request that keeps receiving isn't abandoned, however long it takes" {
    // Its 120 pieces take 1.2 s, past twice the stall: only a pause that long ends it. They
    // come 10 ms apart, so a busy machine may hold either end for most of the stall (50 ms
    // gaps under a 200 ms stall once failed on CI's macOS runner)
    const pieces = 120;
    var server: SlowServer = undefined;
    try server.start(.{ .pieces = pieces, .gap = .fromMilliseconds(10), .length = pieces });
    defer server.stop();
    const body = try watchedBody(&server, .fromMilliseconds(500));
    defer testing.allocator.free(body);
    const expected: [pieces]u8 = @splat('x');
    try testing.expectEqualStrings(&expected, body);
}

test "HTTP client: canceling a watched request's caller cancels the request" {
    var server: SlowServer = undefined;
    try server.start(.{ .head = false });
    defer server.stop();
    const started = std.Io.Clock.Timestamp.now(testing.io, .awake);
    var caller = try testing.io.concurrent(watchedBody, .{ &server, .fromSeconds(60) });
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    if (caller.cancel(testing.io)) |body| {
        testing.allocator.free(body);
        return error.TestUnexpectedResult;
    } else |_| {}
    const waited = started.durationTo(std.Io.Clock.Timestamp.now(testing.io, .awake));
    try testing.expect(waited.raw.nanoseconds < std.time.ns_per_s * 10);
}

test "HTTP client: Counted counts what it reads and what it skips" {
    var in: std.Io.Reader = .fixed("hello, world");
    var received: http_client.Received = .init(0);
    var counted: http_client.Counted = .init(&in, &received);
    var buf: [5]u8 = undefined;
    try counted.interface.readSliceAll(&buf);
    try testing.expectEqualStrings("hello", &buf);
    try counted.interface.discardAll(2);
    try testing.expectEqual(7, received.load(.monotonic));
    const rest = try counted.interface.allocRemaining(testing.allocator, .limited(64));
    defer testing.allocator.free(rest);
    try testing.expectEqualStrings("world", rest);
    try testing.expectEqual(12, received.load(.monotonic));
}
