const std = @import("std");
const testing = std.testing;
const lsp = @import("lsp");
const inbox_mod = @import("lsp_inbox.zig");
const Inbox = inbox_mod.Inbox;

/// Upper bound for any wait in these tests, so a bug fails them instead of hanging the run.
const WAIT_TIMEOUT_MS: i64 = 5000;
const POLL_MS: i64 = 1;

const HOVER_7 = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/hover\",\"params\":{}}";
const HOVER_ABC = "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"textDocument/hover\",\"params\":{}}";
const CANCEL_7 = "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":7}}";
const CANCEL_ABC = "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":\"abc\"}}";
const CANCEL_UNKNOWN = "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":99}}";
const EDIT = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{}}";
const SAVED = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didSave\",\"params\":{}}";

fn sleepMs(ms: i64) void {
    testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

/// The client: hands out `messages` one per `allow`, then ends the stream on the next one.
/// Keeps what the server writes back.
const Client = struct {
    transport: lsp.Transport = .{ .vtable = &.{ .readJsonMessage = read, .writeJsonMessage = write } },
    messages: []const []const u8,
    permits: std.Io.Semaphore = .{},
    read_count: usize = 0,
    written: std.ArrayList([]u8) = .empty,

    fn allow(self: *Client, n: usize) void {
        for (0..n) |_| self.permits.post(testing.io);
    }

    fn read(transport: *lsp.Transport, io: std.Io, allocator: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        const self: *Client = @alignCast(@fieldParentPtr("transport", transport));
        try self.permits.wait(io);
        if (self.read_count == self.messages.len) return error.EndOfStream;
        defer self.read_count += 1;
        return allocator.dupe(u8, self.messages[self.read_count]);
    }

    fn write(transport: *lsp.Transport, _: std.Io, json: []const u8) lsp.Transport.WriteError!void {
        const self: *Client = @alignCast(@fieldParentPtr("transport", transport));
        self.written.append(testing.allocator, testing.allocator.dupe(u8, json) catch @panic("OOM")) catch @panic("OOM");
    }

    fn deinit(self: *Client) void {
        for (self.written.items) |w| testing.allocator.free(w);
        self.written.deinit(testing.allocator);
    }
};

/// The server's slow work. `run` lets the client send `allow_on_run` more messages, then
/// waits up to `wait_for_cancel_ms` to see whether it gets cancelled.
const Preview = struct {
    pending: bool = false,
    runs: usize = 0,
    cancel: std.atomic.Value(bool) = .init(false),
    cancelled: bool = false,
    client: ?*Client = null,
    allow_on_run: usize = 0,
    wait_for_cancel_ms: i64 = 0,

    fn work(self: *Preview) inbox_mod.Work {
        return .{ .context = self, .pending = isPending, .run = run, .cancel = &self.cancel };
    }

    fn isPending(context: *anyopaque) bool {
        const self: *Preview = @ptrCast(@alignCast(context));
        return self.pending;
    }

    fn run(context: *anyopaque) void {
        const self: *Preview = @ptrCast(@alignCast(context));
        self.pending = false;
        self.runs += 1;
        if (self.client) |c| c.allow(self.allow_on_run);
        var waited: i64 = 0;
        while (waited < self.wait_for_cancel_ms and !self.cancel.load(.acquire)) : (waited += POLL_MS) sleepMs(POLL_MS);
        self.cancelled = self.cancel.load(.acquire);
    }
};

fn nextMessage(inbox: *Inbox) ![]u8 {
    return inbox.transport.readJsonMessage(testing.io, testing.allocator);
}

fn expectNext(inbox: *Inbox, expected: []const u8) !void {
    const json = try nextMessage(inbox);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(expected, json);
}

/// Waits until the reader has queued `queued` messages and set aside `refused` requests.
fn waitFor(inbox: *Inbox, queued: usize, refused: usize) !void {
    var waited: i64 = 0;
    while (true) : (waited += POLL_MS) {
        inbox.mutex.lockUncancelable(testing.io);
        const done = inbox.queue.items.len == queued and inbox.refused.items.len == refused;
        inbox.mutex.unlock(testing.io);
        if (done) return;
        if (waited > WAIT_TIMEOUT_MS) return error.Timeout;
        sleepMs(POLL_MS);
    }
}

test "LSP inbox: messages come through in order, then the end of the stream" {
    var client: Client = .{ .messages = &.{ SAVED, HOVER_7 } };
    defer client.deinit();
    var preview: Preview = .{};
    var inbox = Inbox.init(testing.allocator, testing.io, &client.transport, preview.work());
    defer inbox.deinit();
    try inbox.start();

    client.allow(3);
    try expectNext(&inbox, SAVED);
    try expectNext(&inbox, HOVER_7);
    try testing.expectError(error.EndOfStream, nextMessage(&inbox));
    try testing.expectEqual(@as(usize, 0), preview.runs);
}

test "LSP inbox: the work waits until the client has been quiet" {
    var client: Client = .{ .messages = &.{ SAVED, SAVED, SAVED } };
    defer client.deinit();
    // Running ends the stream, so the last read below returns once the work has run.
    var preview: Preview = .{ .pending = true, .client = &client, .allow_on_run = 1 };
    var inbox = Inbox.init(testing.allocator, testing.io, &client.transport, preview.work());
    inbox.quiet_period = .fromMilliseconds(30);
    defer inbox.deinit();
    try inbox.start();

    // Messages that are waiting go first.
    client.allow(2);
    try waitFor(&inbox, 2, 0);
    try expectNext(&inbox, SAVED);
    try expectNext(&inbox, SAVED);
    try testing.expectEqual(@as(usize, 0), preview.runs);

    // One that arrives during the quiet period goes first too.
    const Late = struct {
        fn send(c: *Client) void {
            sleepMs(10);
            c.allow(1);
        }
    };
    const late = try std.Thread.spawn(.{}, Late.send, .{&client});
    inbox.quiet_period = .fromMilliseconds(1000);
    try expectNext(&inbox, SAVED);
    late.join();
    try testing.expectEqual(@as(usize, 0), preview.runs);

    inbox.quiet_period = .fromMilliseconds(30);
    const start = std.Io.Clock.now(.awake, testing.io);
    try testing.expectError(error.EndOfStream, nextMessage(&inbox));
    try testing.expectEqual(@as(usize, 1), preview.runs);
    try testing.expect(start.durationTo(std.Io.Clock.now(.awake, testing.io)).toMilliseconds() >= 30);
}

test "LSP inbox: $/cancelRequest drops a waiting request and answers it RequestCancelled" {
    var client: Client = .{ .messages = &.{ HOVER_7, HOVER_ABC, CANCEL_7, CANCEL_ABC, CANCEL_UNKNOWN, SAVED } };
    defer client.deinit();
    var preview: Preview = .{};
    var inbox = Inbox.init(testing.allocator, testing.io, &client.transport, preview.work());
    defer inbox.deinit();
    try inbox.start();

    client.allow(6);
    try waitFor(&inbox, 1, 2);
    // The cancellations themselves never reach the server (it has nothing to do for them).
    try expectNext(&inbox, SAVED);
    try testing.expectEqual(@as(usize, 2), client.written.items.len);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"error\":{\"code\":-32800,\"message\":\"RequestCancelled\"}}", client.written.items[0]);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32800,\"message\":\"RequestCancelled\"}}", client.written.items[1]);
}

test "LSP inbox: an edit or a request cancels the running work; other notifications don't" {
    var client: Client = .{ .messages = &.{ SAVED, EDIT, HOVER_7 } };
    defer client.deinit();
    var preview: Preview = .{ .pending = true, .client = &client, .allow_on_run = 1, .wait_for_cancel_ms = 50 };
    var inbox = Inbox.init(testing.allocator, testing.io, &client.transport, preview.work());
    inbox.quiet_period = .fromMilliseconds(1);
    defer inbox.deinit();
    try inbox.start();

    // The work runs, lets the client save meanwhile, and runs to the end.
    try expectNext(&inbox, SAVED);
    try testing.expectEqual(@as(usize, 1), preview.runs);
    try testing.expect(!preview.cancelled);

    // Now it lets the client edit, which stops it.
    preview.pending = true;
    preview.wait_for_cancel_ms = WAIT_TIMEOUT_MS;
    try expectNext(&inbox, EDIT);
    try testing.expectEqual(@as(usize, 2), preview.runs);
    try testing.expect(preview.cancelled);

    // A request doesn't wait for it either (it used to, up to the instruction limit).
    preview.pending = true;
    try expectNext(&inbox, HOVER_7);
    try testing.expectEqual(@as(usize, 3), preview.runs);
    try testing.expect(preview.cancelled);
}

test "LSP inbox: deinit stops a reader that is waiting on the client" {
    var client: Client = .{ .messages = &.{} };
    defer client.deinit();
    var preview: Preview = .{};
    var inbox = Inbox.init(testing.allocator, testing.io, &client.transport, preview.work());
    try inbox.start();
    sleepMs(5); // let the reader block on the client
    inbox.deinit();
}
