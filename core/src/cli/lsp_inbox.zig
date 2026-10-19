//! The language server's message pump. A reader task takes the client's messages off the
//! wire as they arrive, so the server knows what is waiting while it works:
//!
//! * the slow work (evaluating the preview) runs once the client has been quiet for
//!   `quiet_period`, not on every keystroke;
//! * an edit or a request that arrives while that work runs cancels it: the edit makes its
//!   result stale, and the request shouldn't wait for it. The work is still pending, so it
//!   runs again once the client is quiet;
//! * `$/cancelRequest` drops a request that is still waiting, answering it RequestCancelled.
//!
//! The server reads through `transport` as from the client's own (lsp_kit's basic_server
//! dispatches as before); everything except the reader task runs on the server's thread.

const std = @import("std");
const lsp = @import("lsp");

const Id = lsp.JsonRPCMessage.ID;

/// How long the client must be quiet before the slow work runs: a pause in typing.
pub const QUIET_PERIOD_MS: i64 = 200;

/// The notifications whose arrival makes running work stale (any request also cancels it).
const EDIT_METHODS = [_][]const u8{ "textDocument/didChange", "textDocument/didClose" };
const CANCEL_METHOD = "$/cancelRequest";

/// The server's slow work, run on its thread between messages.
pub const Work = struct {
    context: *anyopaque,
    /// Whether there is work waiting for the client to be quiet.
    pending: *const fn (context: *anyopaque) bool,
    run: *const fn (context: *anyopaque) void,
    /// What `run` checks to stop early. Cleared before each run, set when an edit or a
    /// request arrives; work stopped this way must report itself `pending` again.
    cancel: *std.atomic.Value(bool),
};

/// What the reader needs from a message: whether it is a request (and which), an edit, or a
/// cancellation. Every other field is skipped unread.
const Envelope = struct {
    id: ?Id = null,
    method: ?[]const u8 = null,
    params: ?struct { id: ?Id = null } = null,
};

const Queued = struct {
    json: []u8,
    /// The request's id (owned), so `$/cancelRequest` can find it; null for a notification.
    id: ?Id,
};

pub const Inbox = struct {
    transport: lsp.Transport = .{ .vtable = &.{ .readJsonMessage = next, .writeJsonMessage = forward } },
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The client's transport: the reader task reads it, the server writes it.
    source: *lsp.Transport,
    work: Work,
    quiet_period: std.Io.Duration = .fromMilliseconds(QUIET_PERIOD_MS),
    reader: ?std.Io.Future(void) = null,

    // --- Guarded by `mutex` ---
    mutex: std.Io.Mutex = .init,
    arrived: std.Io.Condition = .init,
    queue: std.ArrayList(Queued) = .empty,
    /// Requests cancelled while waiting, still to be answered (ids owned).
    refused: std.ArrayList(Id) = .empty,
    /// Why the client's stream ended, once it has.
    end: ?lsp.Transport.ReadError = null,
    /// Whether `work.run` is running, so an edit knows to cancel it.
    working: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, source: *lsp.Transport, work: Work) Inbox {
        return .{ .allocator = allocator, .io = io, .source = source, .work = work };
    }

    /// Starts reading the client. `self` must not move afterwards.
    pub fn start(self: *Inbox) !void {
        self.reader = try self.io.concurrent(readLoop, .{self});
    }

    /// Stops the reader (interrupting a read that is waiting on the client) and drops what
    /// it queued.
    pub fn deinit(self: *Inbox) void {
        if (self.reader) |*reader| reader.cancel(self.io);
        for (self.queue.items) |q| self.freeQueued(q);
        self.queue.deinit(self.allocator);
        for (self.refused.items) |id| self.freeId(id);
        self.refused.deinit(self.allocator);
    }

    fn readLoop(self: *Inbox) void {
        while (true) {
            const json = self.source.readJsonMessage(self.io, self.allocator) catch |err| return self.finish(err);
            self.receive(json) catch |err| return self.finish(err);
        }
    }

    fn finish(self: *Inbox, err: lsp.Transport.ReadError) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.end = err;
        self.arrived.broadcast(self.io);
    }

    /// Queues `json`, or acts on it now if it's a cancellation. Takes `json` either way.
    fn receive(self: *Inbox, json: []u8) !void {
        var queued = false;
        defer if (!queued) self.allocator.free(json); // a parsed id may point into it
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        // A message the envelope can't describe goes through as it is; the server reports it.
        const envelope = std.json.parseFromSliceLeaky(Envelope, arena.allocator(), json, .{ .ignore_unknown_fields = true }) catch Envelope{};
        const method = envelope.method orelse "";

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (std.mem.eql(u8, method, CANCEL_METHOD)) {
            if (envelope.params) |params| if (params.id) |id| try self.refuseQueued(id);
            self.arrived.signal(self.io);
            return;
        }
        // A response from the client has an id but no method: only requests can be cancelled.
        const id = if (envelope.method != null) envelope.id else null;
        if (self.working and (id != null or isEdit(method))) self.work.cancel.store(true, .release);
        const owned = if (id) |i| try self.dupeId(i) else null;
        errdefer if (owned) |i| self.freeId(i);
        try self.queue.append(self.allocator, .{ .json = json, .id = owned });
        queued = true;
        self.arrived.signal(self.io);
    }

    fn isEdit(method: []const u8) bool {
        for (EDIT_METHODS) |edit| {
            if (std.mem.eql(u8, method, edit)) return true;
        }
        return false;
    }

    /// Takes the request `id` out of the queue, to be answered RequestCancelled. One that
    /// isn't waiting has been answered or is being answered, which the protocol allows.
    fn refuseQueued(self: *Inbox, id: Id) !void {
        for (self.queue.items, 0..) |q, i| {
            const queued_id = q.id orelse continue;
            if (!queued_id.eql(id)) continue;
            try self.refused.ensureUnusedCapacity(self.allocator, 1);
            const removed = self.queue.orderedRemove(i);
            self.allocator.free(removed.json);
            self.refused.appendAssumeCapacity(removed.id.?);
            return;
        }
    }

    /// The next message for the server, in order. While none is waiting it answers cancelled
    /// requests and, once the client has been quiet for `quiet_period`, runs the work.
    fn next(transport: *lsp.Transport, io: std.Io, allocator: std.mem.Allocator) lsp.Transport.ReadError![]u8 {
        _ = allocator; // messages are read with the inbox's allocator, which the server frees them with
        const self: *Inbox = @alignCast(@fieldParentPtr("transport", transport));
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.refused.pop()) |id| {
                self.mutex.unlock(io);
                defer self.mutex.lockUncancelable(io);
                self.answerCancelled(id);
                continue;
            }
            if (self.queue.items.len > 0) {
                const q = self.queue.orderedRemove(0);
                if (q.id) |id| self.freeId(id);
                return q.json;
            }
            if (self.end) |err| return err;
            if (!self.work.pending(self.work.context)) {
                try self.arrived.wait(io, &self.mutex);
                continue;
            }
            const quiet: std.Io.Timeout = .{ .duration = .{ .raw = self.quiet_period, .clock = .awake } };
            self.arrived.waitTimeout(io, &self.mutex, quiet) catch |err| switch (err) {
                error.Timeout => if (self.queue.items.len == 0 and self.refused.items.len == 0) self.runWork(),
                error.Canceled => |e| return e,
            };
        }
    }

    /// Runs the work without the lock, so the reader keeps queueing (and can cancel it).
    /// The cancel flag is cleared under the lock an edit sets it under, so none is lost.
    fn runWork(self: *Inbox) void {
        self.work.cancel.store(false, .release);
        self.working = true;
        self.mutex.unlock(self.io);
        self.work.run(self.work.context);
        self.mutex.lockUncancelable(self.io);
        self.working = false;
    }

    fn answerCancelled(self: *Inbox, id: Id) void {
        defer self.freeId(id);
        const code: lsp.JsonRPCMessage.Response.Error.Code = @fromBackingInt(@intCast(@backingInt(lsp.types.LSPErrorCodes.RequestCancelled)));
        self.source.writeErrorResponse(self.io, self.allocator, id, .{ .code = code, .message = "RequestCancelled" }, .{ .emit_null_optional_fields = false }) catch |err| {
            std.log.scoped(.lsp).warn("Could not answer a cancelled request: {}", .{err});
        };
    }

    fn forward(transport: *lsp.Transport, io: std.Io, json: []const u8) lsp.Transport.WriteError!void {
        const self: *Inbox = @alignCast(@fieldParentPtr("transport", transport));
        return self.source.writeJsonMessage(io, json);
    }

    fn dupeId(self: *Inbox, id: Id) !Id {
        return switch (id) {
            .number => id,
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
        };
    }

    fn freeId(self: *Inbox, id: Id) void {
        switch (id) {
            .number => {},
            .string => |s| self.allocator.free(s),
        }
    }

    fn freeQueued(self: *Inbox, q: Queued) void {
        self.allocator.free(q.json);
        if (q.id) |id| self.freeId(id);
    }
};
