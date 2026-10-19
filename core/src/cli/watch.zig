//! `kupcad watch`: builds a script, then rebuilds it through a pinned `ScriptSession`
//! whenever the `Watcher` sees it or a module it imports change.

const std = @import("std");
const watcher_mod = @import("../daemon/watcher.zig");
const Watcher = watcher_mod.Watcher;
const ScriptSession = @import("../daemon/session.zig").ScriptSession;
const Reporter = @import("reporter.zig").Reporter;
const build_cmd = @import("build_cmd.zig");
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const ProjectConfig = @import("config.zig").ProjectConfig;
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const limits = @import("../core/limits.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const debug = @import("../stdlib/debug.zig");
const Outcome = @import("outcome.zig").Outcome;
const log_helpers = @import("../log.zig");
const Args = @import("args.zig").Args;

pub const USAGE =
    \\Usage: kupcad watch <file.kup>
    \\
    \\Builds a script, then rebuilds it whenever it or a module it imports changes.
    \\
;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Error: Missing input file path.\n\n" ++ USAGE, .{});
        return .failure;
    };
    const reporter: Reporter = .forProcess(init);

    // Spin up the cache controller
    var manager = SessionManager.init(allocator, init.io, 1);
    defer manager.deinit();

    // Pin the session: the watcher holds this pointer for the life of the process.
    const lease = try manager.acquireSession(file_path);
    defer manager.release(lease);
    const session = lease.session;
    session.vm.debugger_handler = debug.terminalDebugger(init.io);
    // A long-lived session caps the script heap: the project's `vm_memory_limit`, else the
    // interactive default, so a runaway loop ends with an error instead of the machine.
    var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
    const config = ProjectConfig.forScript(init.io, allocator, file_path, &where) catch |err| {
        reporter.err("Error: {s} near {s}:{d}:{d}: {s}\n", .{ CONFIG_FILE_NAME, file_path, where.line, where.column, ProjectConfig.describeError(err) });
        return .failure;
    };
    session.vm.setMemoryLimit(config.vm_memory_limit orelse limits.INTERACTIVE_MEMORY_LIMIT);

    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ file_path, @errorName(err) });
        return .failure;
    };
    defer allocator.free(source);

    _ = try session.workspace.addModule(file_path, source);
    try session.loadImports();

    var printer = EventPrinter{ .allocator = allocator, .session = session, .root_path = file_path, .reporter = reporter };
    var watcher = try Watcher.init(session, init.io, printer.listener());
    defer watcher.deinit();

    // The first build is reported like any other, and a failed one is watched for a fix
    // (the command used to exit on it).
    _ = watcher.evaluate();
    reporter.err("Watching {s} and the modules it imports; Ctrl+C stops.\n", .{file_path});
    try watcher.start();
    return .success;
}

/// Prints the watcher's events the way `kupcad build` reports: diagnostics with their
/// file, line and column, then a one-line summary.
const EventPrinter = struct {
    allocator: std.mem.Allocator,
    session: *ScriptSession,
    root_path: []const u8,
    reporter: Reporter,

    fn listener(self: *EventPrinter) watcher_mod.Listener {
        return .{ .ptr = self, .onEvent = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: watcher_mod.Event) void {
        const self: *EventPrinter = @ptrCast(@alignCast(ptr));
        switch (event) {
            .changed => |path| self.reporter.err("Changed: {s}\n", .{path}),
            .built => self.reporter.err("Built {s}\n", .{self.root_path}),
            .failed => |failure| build_cmd.reportErrors(self.allocator, self.session, failure, self.reporter) catch |err| {
                self.reporter.err("Build failed ({s}); the errors couldn't be printed: {s}\n", .{ self.root_path, @errorName(err) });
            },
            .run_failed => |err| self.reporter.err("Build failed: {s}\n", .{@errorName(err)}),
            .reload_failed => |r| self.reporter.err("Could not reload '{s}': {s}\n", .{ r.path, @errorName(r.err) }),
        }
    }
};
