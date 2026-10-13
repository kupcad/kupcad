const std = @import("std");
const ScriptSession = @import("session.zig").ScriptSession;

const log = std.log.scoped(.watcher);

/// Poll interval for mtime checks.
pub const POLL_INTERVAL_MS: i64 = 500;
/// Upper bound on a watched source file; mirrors cli/config.zig MAX_FILE_SIZE.
pub const MAX_WATCHED_FILE_SIZE: usize = 10 * 1024 * 1024;

pub const Watcher = struct {
    session: *ScriptSession,
    file_path: []const u8,
    last_mtime: i128,
    io: std.Io,
    is_one_shot: bool = false,

    pub fn init(session: *ScriptSession, file_path: []const u8, io: std.Io) !Watcher {
        const cwd = std.Io.Dir.cwd();
        var last_mtime: i128 = 0;
        if (cwd.statFile(io, file_path, .{})) |stat| {
            last_mtime = stat.mtime.nanoseconds;
        } else |_| {}

        return .{
            .session = session,
            .file_path = file_path,
            .last_mtime = last_mtime,
            .io = io,
            .is_one_shot = false,
        };
    }

    pub fn deinit(self: *Watcher) void {
        _ = self;
    }

    /// Reads the watched file from disk and pushes the new source into the session workspace.
    pub fn reloadSource(self: *Watcher) !void {
        const allocator = self.session.allocator;
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, self.file_path, allocator, .limited(MAX_WATCHED_FILE_SIZE));
        defer allocator.free(source);

        _ = try self.session.workspace.upsertModule(self.file_path, source);
        try self.session.workspace.linkDependencies();
        try self.session.buildReverseGraph();
    }

    pub fn start(self: *Watcher) !void {
        log.info("Watching '{s}' for changes via native std.Io...", .{self.file_path});

        while (true) {
            // Sleep for 500ms using the native async IO engine, bound to the awake clock
            const duration = std.Io.Duration.fromMilliseconds(POLL_INTERVAL_MS);
            self.io.sleep(duration, .awake) catch |err| {
                log.warn("Watcher sleep interrupted: {}", .{err});
            };

            const cwd = std.Io.Dir.cwd();
            if (cwd.statFile(self.io, self.file_path, .{})) |stat| {
                if (stat.mtime.nanoseconds > self.last_mtime) {
                    self.last_mtime = stat.mtime.nanoseconds;
                    log.info("File changed: {s}", .{self.file_path});

                    // Re-read the file: without this the workspace keeps the source from the
                    // initial load and every "re-evaluation" ran stale code.
                    self.reloadSource() catch |err| {
                        log.err("Failed to reload '{s}': {}", .{ self.file_path, err });
                        if (self.is_one_shot) break;
                        continue;
                    };

                    self.session.markFileEdited(self.file_path) catch |err| {
                        log.err("Error marking file: {}", .{err});
                    };

                    if (self.session.workspace.path_to_id.get(self.file_path)) |root_id| {
                        self.session.evaluateModule(root_id) catch |err| {
                            log.err("Evaluation failed: {}", .{err});
                        };
                    }
                }
            } else |_| {}

            if (self.is_one_shot) break;
        }
    }
};
