//! `kupcad watch`: builds a script, then rebuilds it through a pinned `ScriptSession`
//! whenever the `Watcher` sees it or a module it imports change.

const std = @import("std");
const watcher_mod = @import("../session/watcher.zig");
const Watcher = watcher_mod.Watcher;
const ScriptSession = @import("../session/session.zig").ScriptSession;
const Reporter = @import("reporter.zig").Reporter;
const build_cmd = @import("build_cmd.zig");
const fs = @import("fs.zig");
const ProjectConfig = @import("config.zig").ProjectConfig;
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const limits = @import("../core/limits.zig");
const SessionManager = @import("../session/session_manager.zig").SessionManager;
const debugger = @import("debugger.zig");
const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const api = @import("../api.zig");
const param_flags = @import("param_flags.zig");
const NativeVfs = @import("../vfs/native.zig").NativeVfs;

pub const USAGE =
    \\Usage: kupcad watch <file.kup> [options]
    \\
    \\Builds a script, then rebuilds it whenever it, a module it imports or a file it
    \\reads as data changes.
    \\
    \\Options:
    \\
++ param_flags.USAGE ++
    \\  -h, --help                Show this help
    \\
;

/// What `kupcad watch` was asked to do.
pub const Options = struct {
    file_path: []const u8,
    /// `-p` and `-P`, as `kupcad build` takes them: every build of the session uses them.
    params: api.ParamValues = .{},

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
    }
};

/// The options in `args` (`next() ?[]const u8`), or null, the refusal reported.
pub fn parseOptions(allocator: std.mem.Allocator, args: anytype, reporter: Reporter) !?Options {
    var options: Options = .{ .file_path = "" };
    var given = false;
    errdefer options.deinit(allocator);
    while (args.next()) |arg| {
        switch (try param_flags.take(allocator, arg, args, &options.params, reporter)) {
            .taken => continue,
            .refused => return refuse(allocator, &options),
            .other => {},
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            reporter.err("Error: Unknown option '{s}'\n\n" ++ USAGE, .{arg});
            return refuse(allocator, &options);
        }
        if (given) {
            reporter.err("Error: Expected one input file, got '{s}' and '{s}'\n", .{ options.file_path, arg });
            return refuse(allocator, &options);
        }
        options.file_path = arg;
        given = true;
    }
    if (!given) {
        reporter.err("Error: Missing input file path.\n\n" ++ USAGE, .{});
        return refuse(allocator, &options);
    }
    return options;
}

fn refuse(allocator: std.mem.Allocator, options: *Options) ?Options {
    options.deinit(allocator);
    return null;
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const reporter: Reporter = .forProcess(init);
    var options = try parseOptions(allocator, args_iter, reporter) orelse return .failure;
    defer options.deinit(allocator);
    const file_path = options.file_path;

    // Spin up the cache controller; the script reads and writes the disk
    var disk = NativeVfs.init(init.io, std.Io.Dir.cwd());
    var manager = SessionManager.init(allocator, init.io, 1, disk.vfs());
    defer manager.deinit();

    // Pin the session: the watcher holds this pointer for the life of the process.
    const lease = try manager.acquireSession(file_path);
    defer manager.release(lease);
    const session = lease.session;
    session.setParams(&options.params);
    session.vm.debugger_handler = debugger.terminalDebugger(init.io);
    // A long-lived session caps the script heap: the project's `vm_memory_limit`, else the
    // interactive default, so a runaway loop ends with an error instead of the machine.
    var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
    const config = ProjectConfig.forScript(init.io, allocator, file_path, &where) catch |err| {
        reporter.err("Error: {s} near {s}:{d}:{d}: {s}\n", .{ CONFIG_FILE_NAME, file_path, where.line, where.column, ProjectConfig.describeError(err) });
        return .failure;
    };
    session.vm.setMemoryLimit(config.vm_memory_limit orelse limits.INTERACTIVE_MEMORY_LIMIT);

    const source = fs.readFile(init.io, allocator, file_path) catch |err| {
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
pub const EventPrinter = struct {
    allocator: std.mem.Allocator,
    session: *ScriptSession,
    root_path: []const u8,
    reporter: Reporter,

    pub fn listener(self: *EventPrinter) watcher_mod.Listener {
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
