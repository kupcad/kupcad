//! `kupcad watch`: polls the files of a session's workspace (the script and every module it
//! imports) and the data files their runs read (`import_json`, `import_stl`), and rebuilds
//! when one changes, telling its host what happened through a Listener.

const std = @import("std");
const session_mod = @import("session.zig");
const ScriptSession = session_mod.ScriptSession;
const import_path = @import("../core/import_path.zig");
const import_kind = @import("../core/import_kind.zig");
const owned_keys = @import("../core/owned_keys.zig");

/// Poll interval for mtime checks.
pub const POLL_INTERVAL_MS: i64 = 500;
/// Upper bound on a watched source file: the largest source a document takes.
pub const MAX_WATCHED_FILE_SIZE = @import("../core/limits.zig").MAX_SOURCE_BYTES;

/// What a watcher tells its host. (It logged at info level, which release builds hide,
/// and a failed build after a change printed no diagnostics at all.)
pub const Event = union(enum) {
    /// A watched file changed on disk.
    changed: []const u8,
    /// Every module built.
    built,
    /// A module didn't parse or compile; `failure.module` names it.
    failed: *const session_mod.Failure,
    /// The run itself failed (a runtime error, which the VM has reported).
    run_failed: anyerror,
    /// A changed file couldn't be read again.
    reload_failed: struct { path: []const u8, err: anyerror },
};

pub const Listener = struct {
    ptr: *anyopaque,
    onEvent: *const fn (ptr: *anyopaque, event: Event) void,

    pub fn notify(self: Listener, event: Event) void {
        self.onEvent(self.ptr, event);
    }
};

pub const Watcher = struct {
    session: *ScriptSession,
    io: std.Io,
    listener: Listener,
    /// The mtime last seen for each watched file, keyed by the workspace's path slices.
    mtimes: std.StringHashMapUnmanaged(i128) = .empty,
    /// The same for the data files the runs read, keyed by owned copies of their paths (a
    /// run's list of them is replaced by the next). A missing file is 0, so creating one
    /// a run couldn't read is a change.
    data_mtimes: std.StringHashMapUnmanaged(i128) = .empty,
    is_one_shot: bool = false,

    pub fn init(session: *ScriptSession, io: std.Io, listener: Listener) !Watcher {
        var self: Watcher = .{ .session = session, .io = io, .listener = listener };
        errdefer self.deinit();
        try self.rememberMtimes();
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        const allocator = self.session.allocator;
        self.mtimes.deinit(allocator);
        var paths = self.data_mtimes.keyIterator();
        while (paths.next()) |path| allocator.free(path.*);
        self.data_mtimes.deinit(allocator);
    }

    /// Adds to the workspace every module the loaded modules import, read from disk,
    /// until none is missing, then links the dependencies. Only the root used to be
    /// watched, and its imports came from the VM's cache, so an edit to a module never
    /// showed. A file that can't be read (a package, a missing one) is left to the VM's
    /// import to report.
    pub fn loadImports(session: *ScriptSession, io: std.Io) !void {
        const ws = &session.workspace;
        const allocator = session.allocator;
        var i: usize = 0;
        while (i < ws.modules.items.len) : (i += 1) {
            var wanted: std.ArrayList([]u8) = .empty;
            defer {
                for (wanted.items) |path| allocator.free(path);
                wanted.deinit(allocator);
            }
            {
                // The module slice may move when a module is added, so its imports are
                // gathered first.
                const mod = &ws.modules.items[i];
                for (mod.doc.tree.nodes.items) |*node| {
                    if (node.tag != .import_stmt) continue;
                    const stmt = mod.doc.tree.importStmt(node);
                    // A file it reads as data is watched once a run has read it
                    if (import_kind.ofImport(&mod.doc.tree, stmt) != .module) continue;
                    const path = try import_path.resolve(allocator, mod.path, mod.doc.tree.getString(stmt.path));
                    if (ws.path_to_id.contains(path)) {
                        allocator.free(path);
                        continue;
                    }
                    try wanted.append(allocator, path);
                }
            }
            for (wanted.items) |path| {
                if (ws.path_to_id.contains(path)) continue;
                const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_WATCHED_FILE_SIZE)) catch continue;
                defer allocator.free(source);
                _ = try ws.addModule(path, source);
            }
        }
        try ws.linkDependencies();
        try session.buildReverseGraph();
    }

    /// Builds (or rebuilds) the workspace and reports how it went; false when it failed.
    /// Either way, the data files the runs read are watched from here on.
    pub fn evaluate(self: *Watcher) bool {
        const ok = if (self.session.evaluateWorkspace()) true else |err| blk: {
            if (self.session.failure) |*failure| self.listener.notify(.{ .failed = failure }) else self.listener.notify(.{ .run_failed = err });
            break :blk false;
        };
        self.rememberDataMtimes() catch |err| self.listener.notify(.{ .run_failed = err });
        if (ok) self.listener.notify(.built);
        return ok;
    }

    /// One look at the watched files: the ones whose mtime differs from the last seen
    /// (older too: `>` missed a `git checkout` restoring an older file) are read again,
    /// and the workspace rebuilt. Returns whether anything had changed.
    pub fn poll(self: *Watcher) !bool {
        var changed = false;
        var i: usize = 0;
        // A reload may add modules (new imports), which later iterations then see.
        while (i < self.session.workspace.modules.items.len) : (i += 1) {
            const path = self.session.workspace.modules.items[i].path;
            const mtime = self.mtimeOf(path) orelse continue;
            if (self.mtimes.get(path)) |seen| if (seen == mtime) continue;
            try self.mtimes.put(self.session.allocator, path, mtime);
            self.listener.notify(.{ .changed = path });
            self.reload(path) catch |err| {
                self.listener.notify(.{ .reload_failed = .{ .path = path, .err = err } });
                continue;
            };
            changed = true;
        }
        if (try self.pollDataFiles()) changed = true;
        if (changed) _ = self.evaluate();
        return changed;
    }

    /// The data files the last runs read whose mtime differs from the last seen: the
    /// modules that read them are marked stale. Returns whether one had changed.
    fn pollDataFiles(self: *Watcher) !bool {
        var changed = false;
        for (self.session.nodes.items) |node| {
            for (node.files_read.items) |path| {
                const seen = self.data_mtimes.getPtr(path) orelse continue;
                const mtime = self.mtimeOf(path) orelse 0;
                if (seen.* == mtime) continue;
                seen.* = mtime;
                self.listener.notify(.{ .changed = path });
                _ = try self.session.markDataFileEdited(path);
                changed = true;
            }
        }
        return changed;
    }

    /// Records the mtime of every data file the runs read that isn't watched yet.
    fn rememberDataMtimes(self: *Watcher) !void {
        for (self.session.nodes.items) |node| {
            for (node.files_read.items) |path| {
                const entry = try owned_keys.getOrPutOwned(&self.data_mtimes, self.session.allocator, path);
                if (!entry.found_existing) entry.value_ptr.* = self.mtimeOf(path) orelse 0;
            }
        }
    }

    pub fn start(self: *Watcher) !void {
        while (true) {
            // Sleep using the native async IO engine, bound to the awake clock
            self.io.sleep(std.Io.Duration.fromMilliseconds(POLL_INTERVAL_MS), .awake) catch |err| {
                std.log.scoped(.watcher).warn("Watcher sleep interrupted: {}", .{err});
            };
            _ = try self.poll();
            if (self.is_one_shot) break;
        }
    }

    /// Reads a changed file into the workspace, picks up imports it gained, and marks it
    /// and its importers stale.
    fn reload(self: *Watcher, path: []const u8) !void {
        const allocator = self.session.allocator;
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(MAX_WATCHED_FILE_SIZE));
        defer allocator.free(source);
        _ = try self.session.workspace.upsertModule(path, source);
        try loadImports(self.session, self.io);
        try self.rememberMtimes();
        try self.session.markFileEdited(path);
    }

    /// Records the mtime of every module not yet watched.
    fn rememberMtimes(self: *Watcher) !void {
        for (self.session.workspace.modules.items) |mod| {
            const entry = try self.mtimes.getOrPut(self.session.allocator, mod.path);
            if (!entry.found_existing) entry.value_ptr.* = self.mtimeOf(mod.path) orelse 0;
        }
    }

    fn mtimeOf(self: *const Watcher, path: []const u8) ?i128 {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
        return stat.mtime.nanoseconds;
    }
};
