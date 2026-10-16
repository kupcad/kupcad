//! The package manager's HTTP: `request` connects with a timeout and default headers, and
//! `Get` follows redirects itself, only those `redirectAllowed` permits. Used by
//! providers/fetcher.zig.

const std = @import("std");
const validate = @import("validate.zig");

pub const CONNECTION_TIMEOUT_NS: u64 = 10 * std.time.ns_per_s;
pub const DEFAULT_USER_AGENT = "KupCAD/" ++ @import("build_info").version;
/// Most redirects one request follows (a GitHub archive link takes one).
pub const MAX_REDIRECTS: usize = 5;
/// Room for a request's URL, a redirect's target included.
pub const MAX_URL_BYTES: usize = 8 * 1024;

/// What a GET accepts: bodies are read as they come (JSON, or an archive that is already
/// gzipped), so a compressed one reached the JSON parser still compressed. A server that
/// compresses anyway is then error.HttpContentEncodingUnsupported, not garbage.
const IDENTITY_ONLY = blk: {
    var accepted: [@typeInfo(std.http.ContentEncoding).@"enum".field_names.len]bool = @splat(false);
    accepted[@backingInt(std.http.ContentEncoding.identity)] = true;
    break :blk accepted;
};

/// A GET that follows redirects itself, so each hop connects through `request` (with its
/// timeout) and must pass `redirectAllowed`. std.http.Client's own following connected to
/// wherever a Location pointed, with neither.
pub const Get = struct {
    request: std.http.Client.Request,
    /// The current URL and the next one, by turns, each written out whole: a resolved
    /// redirect target still points into the URL it was resolved against.
    urls: [2][MAX_URL_BYTES]u8,
    /// Where a redirect's Location is resolved before it is written out.
    scratch: [MAX_URL_BYTES]u8,

    /// Sends the GET and returns the head of the final response. `self` must not move
    /// until `deinit` (the response refers to its request).
    pub fn send(self: *Get, client: *std.http.Client, url: []const u8) !std.http.Client.Response {
        if (url.len > MAX_URL_BYTES) return error.UrlTooLong;
        @memcpy(self.urls[0][0..url.len], url);
        var uri = std.Uri.parse(self.urls[0][0..url.len]) catch return error.InvalidUrl;
        var current: usize = 0;
        var redirects: usize = 0;
        while (true) {
            self.request = try request(client, .GET, uri, .{
                .redirect_behavior = .unhandled,
                .headers = .{ .accept_encoding = .{ .override = "identity" } },
            });
            self.request.accept_encoding = IDENTITY_ONLY;
            const response = receive(&self.request) catch |err| {
                self.deinit();
                return err;
            };
            if (response.head.status.class() != .redirect) return response;

            const next = 1 - current;
            const target = resolveRedirect(uri, response.head.location, &self.scratch, &self.urls[next]);
            // The redirect's body is never read, so its connection can't be reused.
            self.request.connection.?.closing = true;
            self.deinit();
            const target_uri = try target;
            if (redirects == MAX_REDIRECTS) return error.TooManyHttpRedirects;
            if (!redirectAllowed(uri, target_uri)) return error.ForbiddenRedirect;
            redirects += 1;
            uri = target_uri;
            current = next;
        }
    }

    pub fn deinit(self: *Get) void {
        self.request.deinit();
    }

    fn receive(req: *std.http.Client.Request) !std.http.Client.Response {
        try req.sendBodiless();
        return req.receiveHead(&.{});
    }
};

/// Loads the system's root certificates into `client` (and the time TLS checks expiry
/// against), once. std.http.Client does this in its own `request` only when it opens the
/// connection itself; `request` above opens it first, for the timeout, so every HTTPS
/// download panicked on the missing time instead.
pub fn loadRootCertificates(client: *std.http.Client) !void {
    const io = client.io;
    {
        try client.ca_bundle_lock.lockShared(io);
        defer client.ca_bundle_lock.unlockShared(io);
        if (client.now != null) return;
    }
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CertificateBundleLoadFailure,
    };
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    if (client.now != null) return; // another thread loaded them meanwhile
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

/// `location` resolved against `base` (in `scratch`), written out whole in `out`.
fn resolveRedirect(base: std.Uri, location: ?[]const u8, scratch: *[MAX_URL_BYTES]u8, out: *[MAX_URL_BYTES]u8) !std.Uri {
    const target = location orelse return error.HttpRedirectLocationMissing;
    if (target.len > scratch.len) return error.UrlTooLong;
    @memcpy(scratch[0..target.len], target);
    var aux: []u8 = scratch;
    const resolved = base.resolveInPlace(target.len, &aux) catch return error.HttpRedirectLocationInvalid;
    const text = std.fmt.bufPrint(out, "{f}", .{resolved.fmt(.{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true })}) catch return error.UrlTooLong;
    return std.Uri.parse(text) catch error.HttpRedirectLocationInvalid;
}

/// Whether a redirect from `from` may be followed to `to`: never to a less trusted place.
/// It stays http(s), never drops from https to http, names a plain host (no credentials),
/// and from a public host never reaches a private one (loopback, an IP address, an
/// intranet name): a hostile registry could otherwise point the installer at local services.
pub fn redirectAllowed(from: std.Uri, to: std.Uri) bool {
    const to_https = std.ascii.eqlIgnoreCase(to.scheme, "https");
    if (!to_https and !std.ascii.eqlIgnoreCase(to.scheme, "http")) return false;
    if (std.ascii.eqlIgnoreCase(from.scheme, "https") and !to_https) return false;
    if (to.user != null or to.password != null) return false;

    var from_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    var to_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const from_host = std.Io.net.HostName.fromUri(from, &from_buf) catch return false;
    const to_host = std.Io.net.HostName.fromUri(to, &to_buf) catch return false;
    if (validate.isPublicRegistryHost(from_host.bytes) and !validate.isPublicRegistryHost(to_host.bytes)) return false;
    return true;
}

/// Helper to establish a network connection with strict timeouts and default headers.
pub fn request(
    client: *std.http.Client,
    method: std.http.Method,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
) !std.http.Client.Request {
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;

    // Explicitly define the fallback port mapping since `protocol.port()` is private
    const default_port: u16 = switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
    const port = uri.port orelse default_port;

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = try std.Io.net.HostName.fromUri(uri, &host_buf);

    if (protocol == .tls) try loadRootCertificates(client);
    const conn = try client.connectTcpOptions(.{
        .host = host_name,
        .port = port,
        .protocol = protocol,
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(CONNECTION_TIMEOUT_NS), .clock = .awake } },
    });
    errdefer {
        conn.closing = true;
        client.connection_pool.release(conn, client.io);
    }

    var final_opts = options;
    final_opts.connection = conn;

    if (final_opts.headers.user_agent == .default) {
        final_opts.headers.user_agent = .{ .override = DEFAULT_USER_AGENT };
    }

    return client.request(method, uri, final_opts);
}
