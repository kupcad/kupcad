//! The package manager's HTTP: `Get` follows redirects itself, only those `redirectAllowed`
//! permits, and `watched` abandons a request that receives nothing for a while. Used by
//! providers/fetcher.zig.

const std = @import("std");
const validate = @import("validate.zig");

pub const DEFAULT_USER_AGENT = "KupCAD/" ++ @import("build_info").version;
/// Most redirects one request follows (a GitHub archive link takes one).
pub const MAX_REDIRECTS: usize = 5;
/// Room for a request's URL, a redirect's target included.
pub const MAX_URL_BYTES: usize = 8 * 1024;
/// How long a request may receive nothing before it is abandoned: from its start until its
/// body begins, then between any two parts of its body. std.http.Client reads without a
/// timeout, and drops the one its connect is given, so a host that stopped sending held
/// `kupcad pkg install` for good.
pub const STALL_TIMEOUT: std.Io.Duration = .fromSeconds(30);
/// The most a request may take in all, however steadily it receives: a host that trickles
/// bytes held `pkg install` for good.
pub const TOTAL_TIMEOUT: std.Io.Duration = .fromSeconds(10 * 60);

/// What a GET accepts: bodies are read as they come (JSON, or an archive that is already
/// gzipped), so a compressed one reached the JSON parser still compressed. A server that
/// compresses anyway is then error.HttpContentEncodingUnsupported, not garbage.
const IDENTITY_ONLY = blk: {
    var accepted: [@typeInfo(std.http.ContentEncoding).@"enum".field_names.len]bool = @splat(false);
    accepted[@backingInt(std.http.ContentEncoding.identity)] = true;
    break :blk accepted;
};

/// A GET that follows redirects itself, so each hop must pass `redirectAllowed`.
/// std.http.Client's own following connected to wherever a Location pointed.
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
            self.request = try client.request(.GET, uri, .{
                .redirect_behavior = .unhandled,
                .headers = .{
                    .accept_encoding = .{ .override = "identity" },
                    .user_agent = .{ .override = DEFAULT_USER_AGENT },
                },
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

/// `location` resolved against `base` (in `scratch`), written out whole in `out`.
fn resolveRedirect(base: std.Uri, location: ?[]const u8, scratch: *[MAX_URL_BYTES]u8, out: *[MAX_URL_BYTES]u8) !std.Uri {
    const target = location orelse return error.HttpRedirectLocationMissing;
    if (target.len > scratch.len) return error.UrlTooLong;
    @memcpy(scratch[0..target.len], target);
    var aux: []u8 = scratch;
    const resolved = base.resolveInPlace(target.len, &aux) catch return error.HttpRedirectLocationInvalid;
    const text = std.mem.print(out, "{f}", .{resolved.fmt(.{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true })}) catch return error.UrlTooLong;
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

/// What a watched request received so far, in bytes: `run` reads its body through a
/// `Counted`, which counts it here.
pub const Received = std.atomic.Value(u64);

/// A reader of `in` that counts what it reads in `received`, for `watched`.
pub const Counted = struct {
    in: *std.Io.Reader,
    received: *Received,
    interface: std.Io.Reader,

    pub fn init(in: *std.Io.Reader, received: *Received) Counted {
        return .{ .in = in, .received = received, .interface = .{
            .vtable = &.{ .stream = stream, .discard = discard },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Counted = @fieldParentPtr("interface", r);
        const n = try self.in.stream(w, limit);
        _ = self.received.fetchAdd(n, .monotonic);
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *Counted = @fieldParentPtr("interface", r);
        const n = try self.in.discard(limit);
        _ = self.received.fetchAdd(n, .monotonic);
        return n;
    }
};

/// What `watched(…, run, …)` returns: `run`'s result, error.DownloadStalled or
/// error.DownloadTimedOut.
pub fn Watched(comptime run: anytype) type {
    const result = @typeInfo(@typeInfo(@TypeOf(run)).@"fn".return_type.?).error_union;
    return (error{ DownloadStalled, DownloadTimedOut } || std.Io.ConcurrentError || result.error_set)!result.payload;
}

/// `run(args…, received)` on a thread of its own, abandoned once `received` hasn't grown for
/// `stall` (noticed within twice that): error.DownloadStalled; or once `total` has passed
/// since it started, however steadily it received: error.DownloadTimedOut. A request that
/// ended as it was abandoned keeps what it got. Canceling the caller cancels the request too.
pub fn watched(io: std.Io, stall: std.Io.Duration, total: std.Io.Duration, comptime run: anytype, args: anytype) Watched(run) {
    const Task = struct {
        fn call(task_io: std.Io, done: *std.Io.Event, task_args: @TypeOf(args), received: *Received) @typeInfo(@TypeOf(run)).@"fn".return_type.? {
            defer done.set(task_io);
            return @call(.auto, run, task_args ++ .{received});
        }
    };
    var received: Received = .init(0);
    var done: std.Io.Event = .unset;
    var task = try io.concurrent(Task.call, .{ io, &done, args, &received });
    const ended = untilStalled(io, &done, &received, stall, total) catch |err| switch (err) {
        // What the request got meanwhile is the caller's still, who sees the cancelation at
        // its next point
        error.Canceled => {
            const result = task.cancel(io);
            io.recancel();
            return result;
        },
    };
    switch (ended) {
        .done => return task.await(io),
        .stalled => return task.cancel(io) catch error.DownloadStalled,
        .timed_out => return task.cancel(io) catch error.DownloadTimedOut,
    }
}

/// How a watched request ended: of itself, receiving nothing for the stall, or past the total.
pub const Ended = enum { done, stalled, timed_out };

/// The watch over a request's progress, given the times it is looked at (`now`, the awake
/// clock's nanoseconds), so a test can step them: a test that slept saw a busy machine hold
/// a request past its stall, and fail.
pub const Progress = struct {
    stall: i96,
    /// When it is past its total time.
    last: i96,
    /// When it stalls unless more is received first.
    deadline: i96,
    seen: u64,

    pub fn init(started: i96, stall: std.Io.Duration, total: std.Io.Duration, received: u64) Progress {
        return .{ .stall = stall.nanoseconds, .last = started + total.nanoseconds, .deadline = started + stall.nanoseconds, .seen = received };
    }

    /// When to look next: at the stall's deadline, or the end of the total if sooner.
    pub fn next(self: *const Progress) i96 {
        return @min(self.deadline, self.last);
    }

    /// Looked at `now`, `received` in all so far: how it ended, or null while it goes on.
    /// It stalled only once nothing came all the while (a look may come early).
    pub fn look(self: *Progress, now: i96, received: u64) ?Ended {
        if (now >= self.last) return .timed_out;
        if (received != self.seen) {
            self.seen = received;
            self.deadline = now + self.stall;
        } else if (now >= self.deadline) return .stalled;
        return null;
    }
};

/// Waits until `done`, until `received` hasn't grown for `stall`, or until `total` has
/// passed.
fn untilStalled(io: std.Io, done: *std.Io.Event, received: *const Received, stall: std.Io.Duration, total: std.Io.Duration) std.Io.Cancelable!Ended {
    var progress: Progress = .init(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, stall, total, received.load(.monotonic));
    while (true) {
        const next: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = progress.next() }, .clock = .awake };
        done.waitTimeout(io, .{ .deadline = next }) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.Timeout => {
                const now = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
                if (progress.look(now, received.load(.monotonic))) |ended| return ended;
                continue;
            },
        };
        return .done;
    }
}
