const std = @import("std");
const xev = @import("xev");
const ScriptSession = @import("session.zig").ScriptSession;

const log = std.log.scoped(.watcher);

const WATCHER_TIMEOUT_MS = 500;

pub const Watcher = struct {
    session: *ScriptSession,
    file_path: []const u8,
    last_mtime: i128,
    loop: xev.Loop,
    timer: xev.Timer,
    completion: xev.Completion,
    init_io: std.Io,
    is_one_shot: bool = false, // Flag to prevent infinite rescheduling during unit tests

    pub fn init(session: *ScriptSession, file_path: []const u8, init_io: std.Io) !Watcher {
        const loop = try xev.Loop.init(.{});
        const timer = try xev.Timer.init();

        const cwd = std.Io.Dir.cwd();
        var last_mtime: i128 = 0;
        if (cwd.statFile(init_io, file_path, .{})) |stat| {
            last_mtime = stat.mtime.nanoseconds;
        } else |_| {}

        return .{
            .session = session,
            .file_path = file_path,
            .last_mtime = last_mtime,
            .loop = loop,
            .timer = timer,
            .completion = undefined,
            .init_io = init_io,
            .is_one_shot = false,
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.timer.deinit();
        self.loop.deinit();
    }

    pub fn start(self: *Watcher) !void {
        log.info("Watching '{s}' for changes via libxev...", .{self.file_path});

        // Start 500ms repeating timer
        self.timer.run(&self.loop, &self.completion, WATCHER_TIMEOUT_MS, Watcher, self, &pollCallback);
        // Block the current thread, yielding execution entirely to the OS event loop
        try self.loop.run(.until_done);
    }

    pub fn pollCallback(
        userdata: ?*Watcher,
        loop: *xev.Loop,
        c: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch unreachable;

        const self = userdata orelse return .disarm;
        const cwd = std.Io.Dir.cwd();

        // Perform our stat check
        if (cwd.statFile(self.init_io, self.file_path, .{})) |stat| {
            if (stat.mtime.nanoseconds > self.last_mtime) {
                self.last_mtime = stat.mtime.nanoseconds;
                log.info("File changed: {s}", .{self.file_path});

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

        // Reschedule the timer unless running in one-shot test mode
        if (!self.is_one_shot) {
            self.timer.run(loop, c, WATCHER_TIMEOUT_MS, Watcher, self, &pollCallback);
        }

        // Disarm the current completion event
        return .disarm;
    }
};
