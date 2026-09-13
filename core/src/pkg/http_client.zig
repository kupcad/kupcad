const std = @import("std");

pub const CONNECTION_TIMEOUT_NS: u64 = 10 * std.time.ns_per_s;
pub const DEFAULT_USER_AGENT = "KupCAD/1.0";

/// Helper to establish a network connection with strict timeouts and default headers.
pub fn request(
    client: *std.http.Client,
    method: std.http.Method,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
) !std.http.Client.Request {
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    const port = uri.port orelse protocol.port();

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = try uri.getHost(&host_buf);

    const conn = try client.connectTcpOptions(.{
        .host = host_name,
        .port = port,
        .protocol = protocol,
        .timeout = .{ .ns = CONNECTION_TIMEOUT_NS },
    });
    errdefer {
        conn.closing = true;
        client.connection_pool.release(conn, client.io);
    }

    var final_opts = options;
    final_opts.connection = conn;

    // Safely inject the default User-Agent only if it hasn't been explicitly overridden or omitted
    if (final_opts.headers.user_agent == .default) {
        final_opts.headers.user_agent = .{ .override = DEFAULT_USER_AGENT };
    }

    return client.request(method, uri, final_opts);
}
