//! Work-done progress (LSP 3.15) for the language server's long work, a preview's build:
//! `window/workDoneProgress/create`, then `$/progress` begin ("Building part.kup") and end,
//! which an editor shows in its status bar (VS Code's language client does by itself). Only
//! for a client that says it takes them (`window.workDoneProgress`), and only once the
//! build has run `delay`: most builds end sooner as the person types, and a status bar
//! flickering at each pause would only distract.

const std = @import("std");
const lsp = @import("lsp");
const work_done = lsp.types.window.work_done_progress;

/// How long a build runs before the editor is told of it.
pub const DELAY: std.Io.Duration = .fromMilliseconds(400);
const CREATE_METHOD = "window/workDoneProgress/create";
const PROGRESS_METHOD = "$/progress";
/// Room for a request's id, a token and a title.
const MAX_TEXT_BYTES = 160;

const logger = std.log.scoped(.lsp);

/// One build's progress, told to the editor from a task of its own once `delay` has passed
/// (`start`), and ended by `finish`. The handler's thread is in the build meanwhile and
/// writes nothing, so the two never write the transport at once.
pub const Report = struct {
    io: std.Io,
    transport: *lsp.Transport,
    allocator: std.mem.Allocator,
    id: Text = .{},
    token: Text = .{},
    title: Text = .{},
    finished: std.Io.Event = .unset,
    /// Set by the task once begin was sent; read by `finish` after the task ended.
    begun: bool = false,
    task: ?std.Io.Future(void) = null,

    /// Tells the editor of the build `title` names once it has run `delay`, through the
    /// request `id` (the handler's numbering) and the token `token`. `self` must not move
    /// until `finish`. Without a task to wait in, nothing is told.
    pub fn start(self: *Report, delay: std.Io.Duration, id: []const u8, token: []const u8, title: []const u8) void {
        self.id.set(id);
        self.token.set(token);
        self.title.set(title);
        self.task = self.io.concurrent(announce, .{ self, delay }) catch |err| {
            logger.debug("No work-done progress for this build: {}", .{err});
            return;
        };
    }

    /// The build ended (done, failed or cancelled by an edit): the editor is told, if it was
    /// told it began.
    pub fn finish(self: *Report) void {
        var task = self.task orelse return;
        self.finished.set(self.io);
        task.await(self.io);
        if (self.begun) self.send(PROGRESS_METHOD, Progress(work_done.End), .{ .token = self.token.slice(), .value = .{} });
    }

    fn announce(self: *Report, delay: std.Io.Duration) void {
        self.finished.waitTimeout(self.io, .{ .duration = .{ .raw = delay, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {
                // The begin may follow the create at once: the editor reads them in order
                self.sendRequest();
                self.send(PROGRESS_METHOD, Progress(work_done.Begin), .{ .token = self.token.slice(), .value = .{ .title = self.title.slice(), .cancellable = false } });
                self.begun = true;
            },
            error.Canceled => {},
        };
    }

    fn sendRequest(self: *Report) void {
        self.transport.writeRequest(self.io, self.allocator, .{ .string = self.id.slice() }, CREATE_METHOD, work_done.CreateParams, .{ .token = .{ .string = self.token.slice() } }, .{}) catch |err| {
            logger.warn("Could not ask the editor for a progress token: {}", .{err});
        };
    }

    fn send(self: *Report, method: []const u8, comptime Params: type, params: Params) void {
        self.transport.writeNotification(self.io, self.allocator, method, Params, params, .{ .emit_null_optional_fields = false }) catch |err| {
            logger.warn("Could not tell the editor of the build's progress: {}", .{err});
        };
    }
};

/// `$/progress`'s params for a value of type `Value`.
fn Progress(comptime Value: type) type {
    return struct { token: []const u8, value: Value };
}

/// A string kept in place, cut to its room between characters.
const Text = struct {
    bytes: [MAX_TEXT_BYTES]u8 = undefined,
    len: usize = 0,

    fn set(self: *Text, text: []const u8) void {
        var n = @min(text.len, self.bytes.len);
        if (n < text.len) {
            while (n > 0 and text[n] & 0xC0 == 0x80) n -= 1;
        }
        @memcpy(self.bytes[0..n], text[0..n]);
        self.len = n;
    }

    fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};
