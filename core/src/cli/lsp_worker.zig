//! The preview worker. The language server runs its scripts (the preview, and the run hovers
//! read) in a child process, `kupcad lsp --preview-worker`, so a run that crashes (an abort
//! in the C++ kernel, a stack overflow) ends the worker and not the server: `WorkerPreview`
//! says so, and the next use starts another worker with the open documents.
//!
//! The two talk in frames on the worker's stdin and stdout: a kind byte, the payload's length
//! (u32, little-endian), the payload. Every request but `cancel` gets one `reply`; a cancel
//! comes while an evaluation runs and stops it. The worker logs to stderr, as the server does.

const std = @import("std");
const ast = @import("../core/ast.zig");
const owned_keys = @import("../core/owned_keys.zig");
const ParamValues = @import("../core/param_values.zig").ParamValues;
const lsp_preview = @import("lsp_preview.zig");
const Preview = lsp_preview.Preview;
const freeFiles = lsp_preview.freeFiles;
const SessionPreview = lsp_preview.SessionPreview;
const Outcome = lsp_preview.Outcome;
const Target = lsp_preview.Target;
const OutcomeTag = std.meta.Tag(Outcome);

const logger = std.log.scoped(.lsp);

/// The flag `kupcad lsp` takes to be the worker.
pub const WORKER_FLAG = "--preview-worker";
const HEADER_BYTES = 5;
/// The largest frame either side accepts: a preview frame's GLB can be large, a length
/// longer than this is a corrupt stream.
const MAX_FRAME_BYTES: u32 = 1 << 30;
const IO_BUFFER_BYTES = 64 * 1024;
/// How often a waiting evaluation looks for a cancel to pass on.
const CANCEL_POLL_MS = 5;
/// Between the paths of a `files_read` reply: no path holds it.
const PATH_SEPARATOR = 0;

pub const Kind = enum(u8) {
    /// root: the workspace folder, which imports read files from.
    set_root,
    /// u32 path length, path, source.
    update,
    /// path.
    remove,
    /// u8 want_frame, u32 path length, path, the document's URI.
    evaluate,
    /// u32 node index, path.
    hover,
    /// (empty) Stops the running evaluation; no reply.
    cancel,
    /// To set_root, update, remove and set_params: u8 0 (done) or 1 (failed). To evaluate:
    /// u8 the outcome's tag, then the preview frame's bytes for a frame. To hover: u8 0
    /// (doesn't compile) or 1, then the facts. To file_changed: u8 1 when a module read the
    /// file, else 0 (failed too). To files_read: the paths, PATH_SEPARATOR between them.
    reply,
    // Added after the first kinds, whose values stay as they were.
    /// path: a file changed on disk.
    file_changed,
    /// (empty) The files the runs read as data.
    files_read,
    /// u32 path length, path, the values as a JSON object (ParamValues.jsonStringify).
    set_params,
    _,
};

pub const Frame = struct {
    kind: Kind,
    payload: []u8,
};

pub fn writeFrame(w: *std.Io.Writer, kind: Kind, parts: []const []const u8) !void {
    var len: usize = 0;
    for (parts) |p| len += p.len;
    if (len > MAX_FRAME_BYTES) return error.FrameTooLarge;
    var header: [HEADER_BYTES]u8 = undefined;
    header[0] = @backingInt(kind);
    std.mem.writeInt(u32, header[1..5], @intCast(len), .little);
    try w.writeAll(&header);
    for (parts) |p| try w.writeAll(p);
    try w.flush();
}

/// The next frame (its payload owned by `allocator`); error.EndOfStream when the other side
/// closed its end.
pub fn readFrame(r: *std.Io.Reader, allocator: std.mem.Allocator) !Frame {
    var header: [HEADER_BYTES]u8 = undefined;
    try r.readSliceAll(&header);
    const len = std.mem.readInt(u32, header[1..5], .little);
    if (len > MAX_FRAME_BYTES) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, len);
    errdefer allocator.free(payload);
    try r.readSliceAll(payload);
    return .{ .kind = @fromBackingInt(@intCast(header[0])), .payload = payload };
}

/// `payload` as a u32-prefixed first part and the rest.
fn splitPrefixed(payload: []const u8) ![2][]const u8 {
    if (payload.len < 4) return error.BadFrame;
    const len = std.mem.readInt(u32, payload[0..4], .little);
    if (len > payload.len - 4) return error.BadFrame;
    return .{ payload[4..][0..len], payload[4 + len ..] };
}

/// `files` as a files_read reply: PATH_SEPARATOR between them. Caller owns the result.
pub fn joinPaths(allocator: std.mem.Allocator, files: []const []const u8) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (files, 0..) |path, i| {
        if (i > 0) try joined.append(allocator, PATH_SEPARATOR);
        try joined.appendSlice(allocator, path);
    }
    return joined.toOwnedSlice(allocator);
}

/// The paths of a files_read reply (owned by `allocator`; freeFiles frees them).
pub fn splitPaths(allocator: std.mem.Allocator, payload: []const u8) ![][]u8 {
    if (payload.len == 0) return allocator.alloc([]u8, 0);
    const files = try allocator.alloc([]u8, std.mem.countScalar(u8, payload, PATH_SEPARATOR) + 1);
    var copied: usize = 0;
    errdefer freeFiles(allocator, files[0..copied]);
    var paths = std.mem.splitScalar(u8, payload, PATH_SEPARATOR);
    while (paths.next()) |path| {
        files[copied] = try allocator.dupe(u8, path);
        copied += 1;
    }
    return files;
}

fn u32Bytes(n: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .little);
    return b;
}

// --- The worker ---

/// `kupcad lsp --preview-worker`: serves the server on stdin and stdout until it closes them.
pub fn runWorker(io: std.Io, allocator: std.mem.Allocator) !void {
    var preview: SessionPreview = undefined;
    try preview.init(allocator, io, true);
    defer preview.deinit();
    var in_buf: [IO_BUFFER_BYTES]u8 = undefined;
    var out_buf: [IO_BUFFER_BYTES]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try serve(io, allocator, &preview, &stdin.interface, &stdout.interface);
}

/// Answers the requests on `input` with `preview`'s work, on `output`, until `input` ends.
/// A reader task takes the frames off `input` as they come, so a cancel reaches a running
/// evaluation.
pub fn serve(io: std.Io, allocator: std.mem.Allocator, preview: *SessionPreview, input: *std.Io.Reader, output: *std.Io.Writer) !void {
    var inbox: WorkerInbox = .{ .allocator = allocator, .input = input, .cancel = preview.preview().cancelToken() };
    defer inbox.deinit();
    var reader = try io.concurrent(WorkerInbox.readLoop, .{ &inbox, io });
    defer reader.cancel(io);
    while (try inbox.next(io)) |frame| {
        defer allocator.free(frame.payload);
        try answer(allocator, preview, frame, output);
    }
}

fn answer(allocator: std.mem.Allocator, preview: *SessionPreview, frame: Frame, output: *std.Io.Writer) !void {
    switch (frame.kind) {
        .set_root => try replyStatus(output, preview.setRoot(frame.payload)),
        .update => {
            const parts = try splitPrefixed(frame.payload);
            try replyStatus(output, preview.update(parts[0], parts[1]));
        },
        .remove => try replyStatus(output, preview.remove(frame.payload)),
        .set_params => {
            const parts = try splitPrefixed(frame.payload);
            try replyStatus(output, setParams(allocator, preview, parts[0], parts[1]));
        },
        .file_changed => {
            const affected = preview.fileChanged(frame.payload) catch |err| blk: {
                logger.warn("Preview worker: {s} changed: {}", .{ frame.payload, err });
                break :blk false;
            };
            try writeFrame(output, .reply, &.{&.{@intFromBool(affected)}});
        },
        .files_read => {
            const files = try preview.filesRead(allocator);
            defer freeFiles(allocator, files);
            const joined = try joinPaths(allocator, files);
            defer allocator.free(joined);
            try writeFrame(output, .reply, &.{joined});
        },
        .evaluate => {
            if (frame.payload.len < 1) return error.BadFrame;
            const parts = try splitPrefixed(frame.payload[1..]);
            const outcome = preview.evaluate(allocator, .{ .module_path = parts[0], .uri = parts[1] }, frame.payload[0] != 0);
            switch (outcome) {
                .frame => |bytes| {
                    defer allocator.free(bytes);
                    try writeFrame(output, .reply, &.{ &.{@backingInt(OutcomeTag.frame)}, bytes });
                },
                else => try writeFrame(output, .reply, &.{&.{@backingInt(std.meta.activeTag(outcome))}}),
            }
        },
        .hover => {
            const parts = try splitPrefixed(frame.payload);
            if (parts[0].len != 4) return error.BadFrame;
            const node: ast.NodeIndex = @fromBackingInt(std.mem.readInt(u32, parts[0][0..4], .little));
            const facts = preview.hoverFacts(allocator, parts[1], node) catch |err| blk: {
                logger.warn("Hover: could not run {s}: {}", .{ parts[1], err });
                break :blk null;
            };
            defer if (facts) |f| allocator.free(f);
            if (facts) |f| try writeFrame(output, .reply, &.{ &.{1}, f }) else try writeFrame(output, .reply, &.{&.{0}});
        },
        .cancel, .reply, _ => return error.BadFrame,
    }
}

/// The document at `module_path` runs with the values `json` holds, as a WorkerPreview
/// wrote them.
fn setParams(allocator: std.mem.Allocator, preview: *SessionPreview, module_path: []const u8, json: []const u8) !void {
    var values: ParamValues = .{};
    defer values.deinit(allocator);
    var why: ?[]u8 = null;
    defer if (why) |w| allocator.free(w);
    try values.putJson(allocator, json, &why);
    try preview.setParams(module_path, &values);
}

fn replyStatus(output: *std.Io.Writer, result: anyerror!void) !void {
    result catch |err| {
        logger.warn("Preview worker: {}", .{err});
        return writeFrame(output, .reply, &.{&.{1}});
    };
    try writeFrame(output, .reply, &.{&.{0}});
}

/// The worker's frames as they arrive: a cancel acts at once, the rest wait their turn.
const WorkerInbox = struct {
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    cancel: *std.atomic.Value(bool),
    // Guarded by `mutex`.
    mutex: std.Io.Mutex = .init,
    arrived: std.Io.Condition = .init,
    queue: std.ArrayList(Frame) = .empty,
    ended: bool = false,

    fn deinit(self: *WorkerInbox) void {
        for (self.queue.items) |f| self.allocator.free(f.payload);
        self.queue.deinit(self.allocator);
    }

    fn readLoop(self: *WorkerInbox, io: std.Io) void {
        while (true) {
            const frame = readFrame(self.input, self.allocator) catch |err| {
                if (err != error.EndOfStream) logger.warn("Preview worker: reading the server failed: {}", .{err});
                return self.end(io);
            };
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            switch (frame.kind) {
                .cancel => {
                    self.allocator.free(frame.payload);
                    self.cancel.store(true, .release);
                    continue;
                },
                // Cleared here, in arrival order: a cancel read after it is for it.
                .evaluate => self.cancel.store(false, .release),
                else => {},
            }
            self.queue.append(self.allocator, frame) catch {
                self.allocator.free(frame.payload);
                self.ended = true;
                self.arrived.signal(io);
                return;
            };
            self.arrived.signal(io);
        }
    }

    fn end(self: *WorkerInbox, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.ended = true;
        self.arrived.signal(io);
    }

    /// The next request, in order; null once the server closed the stream.
    fn next(self: *WorkerInbox, io: std.Io) !?Frame {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.queue.items.len == 0) {
            if (self.ended) return null;
            try self.arrived.wait(io, &self.mutex);
        }
        return self.queue.orderedRemove(0);
    }
};

// --- The server's side ---

/// A `Preview` whose work a worker process does. The worker starts on first use, in the
/// server's working directory, and is given the workspace root, every open document and the
/// values they run with; one that ended (it crashed, or was killed) is replaced the same way
/// on the next use.
pub const WorkerPreview = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The worker's command line: kupcad's own executable and WORKER_FLAG (owned by the caller).
    argv: []const []const u8,
    root: ?[]u8 = null,
    /// The open documents by module path, to give a new worker (keys and values owned).
    documents: std.array_hash_map.String([]u8) = .empty,
    /// The values documents run with, by module path, as the JSON a new worker is given
    /// (keys and values owned).
    params: std.StringHashMapUnmanaged([]u8) = .empty,
    worker: ?*Worker = null,
    cancel: std.atomic.Value(bool) = .init(false),
    /// What the last worker was running when it ended, until `takeCrash` hands it out.
    crash: std.ArrayList(u8) = .empty,
    crashed: bool = false,

    const Worker = struct {
        child: std.process.Child,
        in_buf: [IO_BUFFER_BYTES]u8,
        out_buf: [IO_BUFFER_BYTES]u8,
        reader: std.Io.File.Reader,
        writer: std.Io.File.Writer,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) WorkerPreview {
        return .{ .allocator = allocator, .io = io, .argv = argv };
    }

    pub fn deinit(self: *WorkerPreview) void {
        if (self.worker) |w| {
            // Killed, not asked: it may be in the middle of a long run.
            w.child.kill(self.io);
            self.allocator.destroy(w);
            self.worker = null;
        }
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit(self.allocator);
        var params = self.params.iterator();
        while (params.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit(self.allocator);
        if (self.root) |r| self.allocator.free(r);
        self.crash.deinit(self.allocator);
    }

    pub fn preview(self: *WorkerPreview) Preview {
        return .{ .ptr = self, .vtable = &.{
            .setRoot = setRootImpl,
            .update = updateImpl,
            .remove = removeImpl,
            .setParams = setParamsImpl,
            .fileChanged = fileChangedImpl,
            .filesRead = filesReadImpl,
            .evaluate = evaluateImpl,
            .hoverFacts = hoverFactsImpl,
            .cancelToken = cancelTokenImpl,
            .takeCrash = takeCrashImpl,
        } };
    }

    pub fn takeCrash(self: *WorkerPreview) ?[]const u8 {
        if (!self.crashed) return null;
        self.crashed = false;
        return self.crash.items;
    }

    /// The worker's process id, while one runs.
    pub fn pid(self: *const WorkerPreview) ?std.process.Child.Id {
        return if (self.worker) |w| w.child.id else null;
    }

    pub fn setRoot(self: *WorkerPreview, root: []const u8) !void {
        const owned = try self.allocator.dupe(u8, root);
        if (self.root) |old| self.allocator.free(old);
        self.root = owned;
        if (self.worker) |w| self.tell(w, root, .set_root, &.{root}) catch {};
    }

    pub fn update(self: *WorkerPreview, module_path: []const u8, source: []const u8) !void {
        const copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(copy);
        const gop = try self.documents.getOrPut(self.allocator, module_path);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, module_path) catch |err| {
                _ = self.documents.pop();
                return err;
            };
        }
        gop.value_ptr.* = copy;
        // A worker that ended is told everything when it is replaced.
        if (self.worker) |w| self.tellUpdate(w, module_path, source) catch {};
    }

    pub fn remove(self: *WorkerPreview, module_path: []const u8) !void {
        if (self.documents.fetchSwapRemove(module_path)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        if (self.params.fetchRemove(module_path)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
        if (self.worker) |w| self.tell(w, module_path, .remove, &.{module_path}) catch {};
    }

    pub fn setParams(self: *WorkerPreview, module_path: []const u8, values: *const ParamValues) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, values.*, .{});
        errdefer self.allocator.free(json);
        const gop = try owned_keys.getOrPutOwned(&self.params, self.allocator, module_path);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = json;
        // A worker that ended is told them when it is replaced.
        if (self.worker) |w| self.tellParams(w, module_path, json) catch {};
    }

    /// A worker that isn't running has run nothing that read it: the next one reads it anew.
    pub fn fileChanged(self: *WorkerPreview, path: []const u8) !bool {
        const w = self.worker orelse return false;
        const reply = self.request(w, .file_changed, &.{path}) catch |err| {
            _ = self.ended(w, err, path);
            return false;
        };
        defer self.allocator.free(reply.payload);
        return reply.payload.len == 1 and reply.payload[0] == 1;
    }

    /// None while no worker runs: a new one has read nothing yet.
    pub fn filesRead(self: *WorkerPreview, allocator: std.mem.Allocator) ![][]u8 {
        const w = self.worker orelse return allocator.alloc([]u8, 0);
        const reply = self.request(w, .files_read, &.{}) catch |err| {
            _ = self.ended(w, err, "the files a run read");
            return allocator.alloc([]u8, 0);
        };
        defer self.allocator.free(reply.payload);
        return splitPaths(allocator, reply.payload);
    }

    pub fn evaluate(self: *WorkerPreview, allocator: std.mem.Allocator, target: Target, want_frame: bool) Outcome {
        const module_path = target.module_path;
        const w = self.running() catch return .crashed;
        writeFrame(&w.writer.interface, .evaluate, &.{ &.{@intFromBool(want_frame)}, &u32Bytes(@intCast(module_path.len)), module_path, target.uri }) catch |err| return self.ended(w, err, module_path);
        // The inbox sets `cancel` while this waits; it is passed on as it is set.
        var forwarder = self.io.concurrent(forwardCancel, .{ self, w }) catch null;
        const reply = readFrame(&w.reader.interface, self.allocator);
        if (forwarder) |*f| f.cancel(self.io);
        const frame = reply catch |err| return self.ended(w, err, module_path);
        defer self.allocator.free(frame.payload);
        if (frame.kind != .reply or frame.payload.len < 1) return self.ended(w, error.BadFrame, module_path);
        const tag = std.enums.fromInt(OutcomeTag, frame.payload[0]) orelse return self.ended(w, error.BadFrame, module_path);
        return switch (tag) {
            .frame => .{ .frame = allocator.dupe(u8, frame.payload[1..]) catch return .nothing },
            .nothing => .nothing,
            .cancelled => .cancelled,
            .crashed => .crashed,
        };
    }

    pub fn hoverFacts(self: *WorkerPreview, allocator: std.mem.Allocator, module_path: []const u8, node: ast.NodeIndex) !?[]u8 {
        const w = self.running() catch return null;
        const node_bytes = u32Bytes(@backingInt(node));
        const reply = self.request(w, .hover, &.{ &u32Bytes(4), &node_bytes, module_path }) catch |err| {
            _ = self.ended(w, err, module_path);
            return null;
        };
        defer self.allocator.free(reply.payload);
        if (reply.payload.len < 1 or reply.payload[0] == 0) return null;
        return try allocator.dupe(u8, reply.payload[1..]);
    }

    /// The worker, started (and told the root and the documents) if none runs.
    fn running(self: *WorkerPreview) !*Worker {
        if (self.worker) |w| return w;
        const w = try self.allocator.create(Worker);
        w.child = std.process.spawn(self.io, .{ .argv = self.argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) catch |err| {
            self.allocator.destroy(w);
            logger.warn("The preview worker didn't start: {}", .{err});
            return err;
        };
        w.reader = w.child.stdout.?.readerStreaming(self.io, &w.in_buf);
        w.writer = w.child.stdin.?.writerStreaming(self.io, &w.out_buf);
        // The worker's from here: a request it fails stops it (`tell`), one it refuses too.
        self.worker = w;
        errdefer if (self.worker) |refused| {
            _ = self.stop(refused);
        };
        if (self.root) |root| try self.tell(w, root, .set_root, &.{root});
        var it = self.documents.iterator();
        while (it.next()) |entry| try self.tellUpdate(w, entry.key_ptr.*, entry.value_ptr.*);
        var params = self.params.iterator();
        while (params.next()) |entry| try self.tellParams(w, entry.key_ptr.*, entry.value_ptr.*);
        return w;
    }

    fn tellUpdate(self: *WorkerPreview, w: *Worker, module_path: []const u8, source: []const u8) !void {
        try self.tell(w, module_path, .update, &.{ &u32Bytes(@intCast(module_path.len)), module_path, source });
    }

    fn tellParams(self: *WorkerPreview, w: *Worker, module_path: []const u8, json: []const u8) !void {
        try self.tell(w, module_path, .set_params, &.{ &u32Bytes(@intCast(module_path.len)), module_path, json });
    }

    /// Sends a request about `subject` whose reply is only whether it worked; a worker that
    /// doesn't answer is stopped.
    fn tell(self: *WorkerPreview, w: *Worker, subject: []const u8, kind: Kind, parts: []const []const u8) !void {
        const reply = self.request(w, kind, parts) catch |err| {
            _ = self.ended(w, err, subject);
            return err;
        };
        defer self.allocator.free(reply.payload);
        if (reply.payload.len < 1 or reply.payload[0] != 0) return error.WorkerRefused;
    }

    fn request(self: *WorkerPreview, w: *Worker, kind: Kind, parts: []const []const u8) !Frame {
        try writeFrame(&w.writer.interface, kind, parts);
        const frame = try readFrame(&w.reader.interface, self.allocator);
        if (frame.kind != .reply) {
            self.allocator.free(frame.payload);
            return error.BadFrame;
        }
        return frame;
    }

    fn forwardCancel(self: *WorkerPreview, w: *Worker) void {
        while (!self.cancel.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(CANCEL_POLL_MS), .awake) catch return;
        }
        writeFrame(&w.writer.interface, .cancel, &.{}) catch {};
    }

    /// The worker stopped answering while it ran `module_path`: why, then a new one next time.
    fn ended(self: *WorkerPreview, w: *Worker, err: anyerror, module_path: []const u8) Outcome {
        const term = self.stop(w);
        self.crash.clearRetainingCapacity();
        self.crash.appendSlice(self.allocator, module_path) catch {};
        self.crashed = true;
        if (term) |t| switch (t) {
            .exited => |code| logger.warn("The preview worker exited ({d}) while running {s}: {}; the next edit starts another", .{ code, module_path, err }),
            .signal => |sig| logger.warn("The preview worker crashed (signal {t}) while running {s}; the next edit starts another", .{ sig, module_path }),
            else => logger.warn("The preview worker stopped while running {s}: {}; the next edit starts another", .{ module_path, err }),
        } else logger.warn("The preview worker stopped while running {s}: {}; the next edit starts another", .{ module_path, err });
        return .crashed;
    }

    /// Waits for a worker that ended, or stopped answering (closing its stdin ends one that
    /// is still well), and says how it ended.
    fn stop(self: *WorkerPreview, w: *Worker) ?std.process.Child.Term {
        self.worker = null;
        defer self.allocator.destroy(w);
        if (w.child.stdin) |f| f.close(self.io);
        w.child.stdin = null;
        return w.child.wait(self.io) catch null;
    }

    fn setRootImpl(ptr: *anyopaque, root: []const u8) anyerror!void {
        return cast(ptr).setRoot(root);
    }
    fn updateImpl(ptr: *anyopaque, module_path: []const u8, source: []const u8) anyerror!void {
        return cast(ptr).update(module_path, source);
    }
    fn removeImpl(ptr: *anyopaque, module_path: []const u8) anyerror!void {
        return cast(ptr).remove(module_path);
    }
    fn setParamsImpl(ptr: *anyopaque, module_path: []const u8, values: *const ParamValues) anyerror!void {
        return cast(ptr).setParams(module_path, values);
    }
    fn fileChangedImpl(ptr: *anyopaque, path: []const u8) anyerror!bool {
        return cast(ptr).fileChanged(path);
    }
    fn filesReadImpl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]u8 {
        return cast(ptr).filesRead(allocator);
    }
    fn evaluateImpl(ptr: *anyopaque, allocator: std.mem.Allocator, target: Target, want_frame: bool) Outcome {
        return cast(ptr).evaluate(allocator, target, want_frame);
    }
    fn hoverFactsImpl(ptr: *anyopaque, allocator: std.mem.Allocator, module_path: []const u8, node: ast.NodeIndex) anyerror!?[]u8 {
        return cast(ptr).hoverFacts(allocator, module_path, node);
    }
    fn cancelTokenImpl(ptr: *anyopaque) *std.atomic.Value(bool) {
        return &cast(ptr).cancel;
    }
    fn takeCrashImpl(ptr: *anyopaque) ?[]const u8 {
        return cast(ptr).takeCrash();
    }
    fn cast(ptr: *anyopaque) *WorkerPreview {
        return @ptrCast(@alignCast(ptr));
    }
};
